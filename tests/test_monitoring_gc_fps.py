"""Contrats réels de B42 : période du tick et pauses ZGC, sans importer le bot."""
import ast
from datetime import datetime
from pathlib import Path
import re
from types import SimpleNamespace
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "data/scripts/discord/bot.py"


def load_monitoring():
    names = {"_GC_HEAP_RE", "_GC_MAJOR_RE", "_GC_PAUSE_RE", "_CSV_HEADER",
             "_gc_heap", "_prom_val", "_prom_snapshot", "_status", "_csv_row"}
    tree = ast.parse(SOURCE.read_text())
    nodes = [node for node in tree.body if
             isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in names or
             isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id in names for t in node.targets)]
    ns = {"re": re, "datetime": datetime, "HEAP_RESTART_PERCENT": 95,
          "GC_LOG_PATH": "scratch", "PROMETHEUS_URL": "scratch"}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(SOURCE), "exec"), ns)
    return ns


class MonitoringContracts(unittest.TestCase):
    def setUp(self):
        self.ns = load_monitoring()

    def gc(self, text):
        self.ns["_tail_text"] = lambda _: text
        return self.ns["_gc_heap"]()

    def status(self, gc, fps=None):
        return self.ns["_status"]({"mem": {"MemTotal": 1000000, "MemAvailable": 900000},
          "gc": gc, "srv_fps": fps, "pid": 1, "pswap_kb": 0, "temps": {}, "disk": None, "heapdump": None})[1]

    def test_long_concurrent_cycle_is_not_a_long_pause(self):
        gc = self.gc("""[gc,phases] GC(327) Y: Pause Mark Start (Major) 3,541ms
[gc,phases] GC(327) O: Pause Mark End 6,581ms
[gc,phases] GC(328) y: Pause Mark End 12000ms
[gc] GC(327) Major Collection (Timer) 13958M(68%)->10834M(53%) 11,075s
[gc] GC(328) Minor Collection (Allocation Rate) 13604M(66%)->5190M(25%) 0,131s
""")
        self.assertEqual(gc[:4], (5190, 25, 53, 10834))
        self.assertAlmostEqual(gc[4], 0.006581)
        self.assertAlmostEqual(gc[5], 11.075)
        self.assertEqual(self.status(gc), [])

    def test_real_long_major_pause_alerts(self):
        gc = self.gc("[gc,phases] GC(1) O: Pause Mark End 12000.0ms\n"
          "[gc] GC(1) Major Collection (Timer) 100M(1%)->90M(1%) 15.0s\n")
        self.assertIn("Pause GC majeure longue (12.0s)", "\n".join(self.status(gc)))

    def test_missing_phases_remain_unknown(self):
        gc = self.gc("[gc] GC(2) Major Collection (Timer) 100M(1%)->90M(1%) 30.0s\n")
        self.assertIsNone(gc[4])
        self.assertEqual(gc[5], 30.0)
        self.assertEqual(self.status(gc), [])

    def test_previous_major_pause_is_not_reused(self):
        gc = self.gc("[gc,phases] GC(1) O: Pause Mark End 12000ms\n"
          "[gc] GC(1) Major Collection (Timer) 100M(1%)->90M(1%) 15.0s\n"
          "[gc,phases] GC(2) O: Pause Mark End 0.5ms\n"
          "[gc] GC(2) Major Collection (Timer) 100M(1%)->90M(1%) 30.0s\n")
        self.assertEqual(gc[4], 0.0005)
        self.assertEqual(self.status(gc), [])

    def test_csv_keeps_existing_columns_and_writes_true_pause(self):
        gc = self.gc("[gc,phases] GC(1) O: Pause Mark End 6.581ms\n"
          "[gc] GC(1) Major Collection (Timer) 100M(1%)->90M(1%) 11.075s\n")
        row = self.ns["_csv_row"]({"gc": gc})
        header = self.ns["_CSV_HEADER"]
        self.assertEqual(len(header), 34)
        self.assertEqual(len(row), len(header))
        self.assertEqual(row[header.index("gc_pause_s")], "0.007")
        missing = self.ns["_csv_row"]({"gc": (*gc[:4], None, gc[5])})
        self.assertEqual(missing[header.index("gc_pause_s")], "")

    def snapshot(self, value):
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self): return ('performance{parameter="fps"} ' + value + '\n').encode()
        self.ns["urllib"] = SimpleNamespace(request=SimpleNamespace(urlopen=lambda *a, **k: Response()))
        return self.ns["_prom_snapshot"]()

    def test_tick_period_is_converted_to_frequency(self):
        self.assertAlmostEqual(self.snapshot("103")["fps"], 1000 / 103)
        self.assertAlmostEqual(self.snapshot("617")["fps"], 1000 / 617)

    def test_normal_capped_tick_and_slow_tick_keep_monitoring_semantics(self):
        normal = self.snapshot("100")["fps"]
        slow = self.snapshot("617")["fps"]
        self.assertEqual(normal, 10.0)
        self.assertAlmostEqual(slow, 1000 / 617)
        # Le statut n'avait aucun seuil FPS : la conversion n'en invente pas.
        self.assertEqual(self.status(None, normal), [])
        self.assertEqual(self.status(None, slow), [])
        header = self.ns["_CSV_HEADER"]
        self.assertEqual(self.ns["_csv_row"]({"srv_fps": normal})[header.index("srv_fps")], "10.0")
        self.assertEqual(self.ns["_csv_row"]({"srv_fps": slow})[header.index("srv_fps")], "1.6")

    def test_invalid_tick_period_is_not_an_infinite_or_negative_rate(self):
        for value in ("0", "-1", "NaN", "+Inf", "-Inf", "invalid"):
            with self.subTest(value=value): self.assertIsNone(self.snapshot(value)["fps"])

    def test_absent_gc_log(self):
        self.assertIsNone(self.gc(""))


if __name__ == "__main__":
    unittest.main()
