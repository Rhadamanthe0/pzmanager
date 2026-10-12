#!/usr/bin/env python3
"""Exercise the public coordinate command, including grid edges and invalid input."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MapCoordinates(unittest.TestCase):
    def command(self, *args):
        return subprocess.run(["bash", str(ROOT / "pzm"), "map", "coords", *map(str, args)],
                              capture_output=True, text=True)

    def test_game_position(self):
        result = self.command(4112, 6344)
        self.assertEqual(result.returncode, 0, result.stderr)
        for text in ["Tuile (4112, 6344)", "x1=4112 y1=6344 x2=4112 y2=6344",
                     "Chunk (514, 793)", "x1=4112 y1=6344 x2=4119 y2=6351",
                     "Cellule (16, 24)", "x1=4096 y1=6144 x2=4351 y2=6399"]:
            self.assertIn(text, result.stdout)

    def test_inclusive_edges(self):
        for coordinate, chunk, cell in [(0, 0, 0), (7, 0, 0), (8, 1, 0),
                                        (255, 31, 0), (256, 32, 1),
                                        (2**31 - 1, 268435455, 8388607)]:
            with self.subTest(coordinate=coordinate):
                result = self.command(coordinate, coordinate)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"Chunk ({chunk}, {chunk})", result.stdout)
                self.assertIn(f"Cellule ({cell}, {cell})", result.stdout)

    def test_explicit_indices(self):
        for unit, x, y, expected in [("chunk", 514, 793, "x1=4112 y1=6344 x2=4119 y2=6351"),
                                     ("cell", 16, 24, "x1=4096 y1=6144 x2=4351 y2=6399")]:
            result = self.command(x, y, "--unit", unit)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(expected, result.stdout)

    def test_reject_invalid_or_overflowing_coordinates(self):
        for args in [(1,), (-1, 0), ("1.5", 0), ("abc", 0), (2**31, 0),
                     ("9" * 5000, 0), (2**31 - 1, 0, "--unit", "chunk"),
                     (1, 1, "--unit", "unknown"), (1, 2, 3)]:
            with self.subTest(args=str(args)[:80]):
                self.assertEqual(self.command(*args).returncode, 2)


if __name__ == "__main__":
    unittest.main()
