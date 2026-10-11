"""Le budget affiché utilise le cgroup et son plafond réellement en vigueur."""
import subprocess
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

from test_sec_markdown import bot, _serveur


class MemoryMonitoring(unittest.TestCase):
    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="pz-monitor-shared-")
        self.addCleanup(self.fixture.cleanup)
        self.group = Path(self.fixture.name)
        (self.group / "memory.current").write_text(str(18 * 2**30))
        (self.group / "memory.peak").write_text("20000000000")
        mock = patch.object(bot, "validate_slice", return_value=self.group)
        mock.start()
        self.addCleanup(mock.stop)

    def test_service_accounting_and_actual_limit(self):
        result = subprocess.CompletedProcess([], 0, stdout=(
            "MemoryCurrent=19327352832\nMemoryPeak=20000000000\nMemoryMax=21474836480\nControlGroup=/user.slice/user-1005.slice/user@1005.service/pz.slice\n"))
        with patch.object(bot.subprocess, "run", return_value=result) as run, \
                patch.object(bot, "service_rss_bytes", return_value=8 * 2**30):
            metrics = bot._service_memory()
        self.assertEqual(metrics["memory_bytes"], 18 * 2**30)
        self.assertEqual(metrics["memory_limit_bytes"], 20 * 2**30)
        self.assertEqual(run.call_args.kwargs["timeout"], 2)
        s = _serveur("player")
        s.update(metrics, rss_kb=3 * 1048576, hwm_kb=11 * 1048576)
        field = next(f for f in bot._monitoring_embed(s).fields if f["name"] == "🧠 RAM de PZ")
        self.assertIn("18.0 / 20 Go", field["value"])
        self.assertIn("90%", field["value"])
        self.assertIn("RAM résidente PZ **8.0 Go**", field["value"])
        self.assertIn("11.0 Go", field["value"])
        self.assertNotIn("Service avec caches", field["value"])
        self.assertNotIn("Restart préventif", field["value"])
        self.assertFalse(any("RAM totale" in a for a in bot._status(s)[1]))

    def test_native_shared_cap_wins_over_stale_bus_and_accepts_transient_overage(self):
        (self.group / "memory.current").write_text(str(21 * 2**30))
        result = subprocess.CompletedProcess([], 0, stdout=(
            "ControlGroup=/user.slice/user-1005.slice/user@1005.service/pz.slice\n"
            "MemoryMax=25769803776\nMemoryCurrent=1\n"))
        with patch.object(bot.subprocess, "run", return_value=result), \
                patch.object(bot, "service_rss_bytes", return_value=7 * 2**30):
            metrics = bot._service_memory()
        self.assertEqual(metrics["memory_limit_bytes"], 20 * 2**30)
        self.assertEqual(metrics["memory_bytes"], 21 * 2**30)

    def test_invalid_metrics_and_infinite_cap(self):
        result = subprocess.CompletedProcess([], 0, stdout=(
            "MemoryCurrent=[not set]\nMemoryPeak=18446744073709551615\nMemoryMax=infinity\n"))
        with patch.object(bot.subprocess, "run", return_value=result):
            self.assertEqual(bot._service_memory(), {})

    def test_bus_timeout_does_not_break_monitoring(self):
        for error in (subprocess.TimeoutExpired("systemctl", 2),
                      subprocess.CalledProcessError(1, "systemctl"), FileNotFoundError()):
            with self.subTest(error=error), patch.object(bot.subprocess, "run", side_effect=error):
                self.assertEqual(bot._service_memory(), {})

    def test_ram_alert_independent_of_heap(self):
        s = _serveur("player")
        s.update(service_rss_bytes=18 * 2**30, gc=(3500, 17, 17, 3500, .1, 1.0))
        color, alerts = bot._status(s)
        self.assertEqual(color, 0xE74C3C)
        self.assertTrue(any("RAM totale" in a for a in alerts))

    def test_supplied_monitoring_snapshot(self):
        s = _serveur("player")
        s.update(service_rss_bytes=6 * 2**30, memory_bytes=int(17.2 * 2**30),
                 memory_limit_bytes=20 * 2**30, hwm_kb=int(11.1 * 1048576),
                 gc=(int(3.7 * 1024), 19, 19, int(3.7 * 1024), .1, 1.0))
        with patch.object(bot, "_xmx_gb", return_value=20):
            field = next(f for f in bot._monitoring_embed(s).fields if f["name"] == "🧠 RAM de PZ")
        self.assertIn("17.2 / 20 Go", field["value"])
        self.assertIn("86%", field["value"])
        self.assertIn("RAM résidente PZ **6.0 Go**", field["value"])
        self.assertIn("11.1 Go", field["value"])
        self.assertIn("3.7 / 20 Go", field["value"])
        self.assertIn("19%", field["value"])
        self.assertEqual(len(field["value"].splitlines()), 3)
        self.assertFalse(any("RAM totale" in a for a in bot._status(s)[1]))

    def test_unverified_cap_not_displayed(self):
        s = _serveur("player")
        s.update(service_rss_bytes=8 * 2**30)
        field = next(f for f in bot._monitoring_embed(s).fields if f["name"] == "🧠 RAM de PZ")
        self.assertNotIn("/ 20 Go", field["value"])
        self.assertIn("plafond non confirmé", field["value"])

    def test_missing_current_is_not_replaced_by_rss_budget_percentage(self):
        s = _serveur("player")
        s.update(service_rss_bytes=8 * 2**30, memory_limit_bytes=20 * 2**30)
        field = next(f for f in bot._monitoring_embed(s).fields if f["name"] == "🧠 RAM de PZ")
        self.assertIn("Budget PZ partagé — / 20 Go", field["value"])
        self.assertIn("consommation indisponible", field["value"])
        self.assertIn("RAM résidente PZ **8.0 Go**", field["value"])
        self.assertNotIn("40%", field["value"])

    def test_resident_reader_scoped_to_service_and_descendants(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            group = root / "cgroup/server"
            (group / "child").mkdir(parents=True)
            (group / "cgroup.procs").write_text("100\n200\n")
            (group / "child/cgroup.procs").write_text("200\n300\n999\n")
            for pid, rss in [(100, 3000), (200, 8000000), (300, 1000), (400, 20000000)]:
                path = root / "proc" / str(pid)
                path.mkdir(parents=True)
                (path / "status").write_text(f"Name: PZ\nVmRSS: {rss} kB\n")
            self.assertEqual(bot.service_rss_bytes("/server", root / "cgroup", root / "proc"),
                             (3000 + 8000000 + 1000) * 1024)
            self.assertIsNone(bot.service_rss_bytes("/missing", root / "cgroup", root / "proc"))
            for invalid in ("/", "", "relative", "/server/../other"):
                self.assertIsNone(bot.service_rss_bytes(invalid, root / "cgroup", root / "proc"))


if __name__ == "__main__":
    unittest.main()
