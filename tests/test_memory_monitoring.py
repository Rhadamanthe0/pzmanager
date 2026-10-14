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
        # file inclut shmem : ici seuls 3 Gio sont du cache file-backed.
        (self.group / "memory.stat").write_text(
            f"anon {2 * 2**30}\nfile {10 * 2**30}\nshmem {7 * 2**30}\n"
            f"slab_reclaimable {5 * 2**30}\n")
        mock = patch.object(bot, "validate_slice", return_value=self.group)
        mock.start()
        self.addCleanup(mock.stop)

    def test_unknown_service_is_not_reported_inactive(self):
        s = _serveur('player')
        s.update(pid=None, service_state='unknown')
        color, alerts = bot._status(s)
        self.assertFalse(any('INACTIF' in alert for alert in alerts))
        self.assertTrue(any('indéterminé' in alert for alert in alerts))
        field = next(field for field in bot._monitoring_embed(s).fields if field['name'] == 'Serveur')
        self.assertIn('état indéterminé', field['value'])

    def test_service_accounting_and_actual_limit(self):
        result = subprocess.CompletedProcess([], 0, stdout=(
            "MemoryCurrent=19327352832\nMemoryPeak=20000000000\nMemoryMax=21474836480\nControlGroup=/user.slice/user-1005.slice/user@1005.service/pz.slice\n"))
        with patch.object(bot.subprocess, "run", return_value=result) as run, \
                patch.object(bot, "service_rss_bytes", return_value=8 * 2**30), \
                patch.object(bot, "service_nonfile_rss_bytes", return_value=6 * 2**30):
            metrics = bot._service_memory()
        self.assertEqual(metrics["memory_bytes"], 18 * 2**30)  # Brut : plafond Linux
        self.assertEqual(metrics["memory_noncache_bytes"], 10 * 2**30)
        self.assertEqual(metrics["service_nonfile_rss_bytes"], 6 * 2**30)
        self.assertEqual(metrics["memory_limit_bytes"], 20 * 2**30)
        self.assertEqual(run.call_args.kwargs["timeout"], 2)
        s = _serveur("player")
        s.update(metrics, rss_kb=3 * 1048576, hwm_kb=11 * 1048576)
        field = next(f for f in bot._monitoring_embed(s).fields if f["name"] == "🧠 RAM de PZ")
        self.assertIn("10.0 / 20 Go", field["value"])
        self.assertIn("50%", field["value"])
        self.assertIn("RAM résidente PZ hors cache **6.0 Go**", field["value"])
        self.assertNotIn("18.0 / 20 Go", field["value"])
        self.assertNotIn("11.0 Go", field["value"])
        self.assertNotIn("pic compté", field["value"])
        self.assertNotIn("pic processus", field["value"])
        self.assertNotIn("Restart préventif", field["value"])
        self.assertFalse(any("RAM totale" in a for a in bot._status(s)[1]))

    def test_native_shared_cap_wins_over_stale_bus_and_accepts_transient_overage(self):
        (self.group / "memory.current").write_text(str(21 * 2**30))
        result = subprocess.CompletedProcess([], 0, stdout=(
            "ControlGroup=/user.slice/user-1005.slice/user@1005.service/pz.slice\n"
            "MemoryMax=25769803776\nMemoryCurrent=1\n"))
        with patch.object(bot.subprocess, "run", return_value=result), \
                patch.object(bot, "service_rss_bytes", return_value=7 * 2**30), \
                patch.object(bot, "service_nonfile_rss_bytes", return_value=6 * 2**30):
            metrics = bot._service_memory()
        self.assertEqual(metrics["memory_limit_bytes"], 20 * 2**30)
        self.assertEqual(metrics["memory_bytes"], 21 * 2**30)
        self.assertEqual(metrics["memory_noncache_bytes"], 13 * 2**30)

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
        s.update(service_rss_bytes=6 * 2**30, service_nonfile_rss_bytes=5 * 2**30,
                 memory_bytes=int(17.2 * 2**30), memory_noncache_bytes=int(9.2 * 2**30),
                 memory_limit_bytes=20 * 2**30, hwm_kb=int(11.1 * 1048576),
                 gc=(int(3.7 * 1024), 19, 19, int(3.7 * 1024), .1, 1.0))
        with patch.object(bot, "_xmx_gb", return_value=20):
            field = next(f for f in bot._monitoring_embed(s).fields if f["name"] == "🧠 RAM de PZ")
        self.assertIn("9.2 / 20 Go", field["value"])
        self.assertIn("46%", field["value"])
        self.assertIn("RAM résidente PZ hors cache **5.0 Go**", field["value"])
        self.assertNotIn("17.2 / 20 Go", field["value"])
        self.assertNotIn("11.1 Go", field["value"])
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
        self.assertNotIn("8.0 Go", field["value"])  # Aucun repli sur RSS avec cache

    def test_missing_current_is_not_replaced_by_rss_budget_percentage(self):
        s = _serveur("player")
        s.update(service_rss_bytes=8 * 2**30, memory_limit_bytes=20 * 2**30)
        field = next(f for f in bot._monitoring_embed(s).fields if f["name"] == "🧠 RAM de PZ")
        self.assertIn("RAM PZ hors cache — / 20 Go", field["value"])
        self.assertIn("mesure indisponible", field["value"])
        self.assertIn("RAM résidente PZ hors cache —", field["value"])
        self.assertNotIn("40%", field["value"])

    def test_cgroup_noncache_calculation_keeps_shmem_once(self):
        gib = 2**30
        stats = (f"anon {1 * gib}\nfile {10 * gib}\nshmem {7 * gib}\n"
                 f"slab_reclaimable {7 * gib}\n")
        self.assertEqual(bot._noncache_cgroup_bytes(19 * gib, stats), 9 * gib)
        for invalid in (
            "file 10\nshmem 7\n",
            "file 3\nshmem 7\nslab_reclaimable 1\n",
            "file 3\nshmem -1\nslab_reclaimable 1\n",
            "file 10\nshmem 2\nslab_reclaimable 10\n",
        ):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                bot._noncache_cgroup_bytes(9, invalid)

    def test_memory_stat_missing_keeps_raw_safety_without_fake_noncache(self):
        (self.group / "memory.stat").unlink()
        result = subprocess.CompletedProcess([], 0, stdout=(
            "ControlGroup=/user.slice/user-1005.slice/user@1005.service/pz.slice\n"))
        with patch.object(bot.subprocess, "run", return_value=result), \
                patch.object(bot, "service_rss_bytes", return_value=8 * 2**30), \
                patch.object(bot, "service_nonfile_rss_bytes", return_value=None):
            metrics = bot._service_memory()
        self.assertEqual(metrics["memory_bytes"], 18 * 2**30)
        self.assertEqual(metrics["memory_limit_bytes"], 20 * 2**30)
        self.assertNotIn("memory_noncache_bytes", metrics)
        s = _serveur("player")
        s.update(metrics)
        field = next(f for f in bot._monitoring_embed(s).fields if f["name"] == "🧠 RAM de PZ")
        self.assertIn("RAM PZ hors cache — / 20 Go", field["value"])
        self.assertNotIn("18.0 / 20 Go", field["value"])

    def test_incomplete_rss_cannot_fallback_to_cached_vmrss(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cg = root / "cgroup" / "pz.slice"
            cg.mkdir(parents=True)
            (cg / "cgroup.procs").write_text("123\n")
            proc = root / "proc" / "123"
            proc.mkdir(parents=True)
            (proc / "status").write_text("VmRSS: 9900000 kB\n")
            self.assertIsNone(bot.service_nonfile_rss_bytes(
                "/pz.slice", root / "cgroup", root / "proc"))

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
                anon, shmem = {100: (1000, 500), 200: (2000000, 1000000),
                               300: (200, 300), 400: (10000000, 10000000)}[pid]
                (path / "status").write_text(
                    f"Name: PZ\nVmRSS: {rss} kB\n"
                    f"RssAnon: {anon} kB\nRssShmem: {shmem} kB\n"
                    f"RssFile: {rss - anon - shmem} kB\n")
            self.assertEqual(bot.service_rss_bytes("/server", root / "cgroup", root / "proc"),
                             (3000 + 8000000 + 1000) * 1024)
            self.assertEqual(bot.service_nonfile_rss_bytes("/server", root / "cgroup", root / "proc"),
                             (1000 + 500 + 2000000 + 1000000 + 200 + 300) * 1024)
            self.assertIsNone(bot.service_rss_bytes("/missing", root / "cgroup", root / "proc"))
            self.assertIsNone(bot.service_nonfile_rss_bytes("/missing", root / "cgroup", root / "proc"))
            for invalid in ("/", "", "relative", "/server/../other"):
                self.assertIsNone(bot.service_rss_bytes(invalid, root / "cgroup", root / "proc"))
                self.assertIsNone(bot.service_nonfile_rss_bytes(invalid, root / "cgroup", root / "proc"))


if __name__ == "__main__":
    unittest.main()
