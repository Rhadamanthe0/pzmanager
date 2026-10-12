#!/usr/bin/env python3
"""Convert Build 42 map coordinates to inclusive tile bounds, without world I/O."""
import argparse

MAX_COORD = 2**31 - 1
SIZES = {"tile": 1, "chunk": 8, "cell": 256}


def coordinate(value):
    if not value.isascii() or not value.isdecimal() or len(value) > 10:
        raise argparse.ArgumentTypeError("coordonnée entière positive ou nulle requise")
    result = int(value)
    if result > MAX_COORD:
        raise argparse.ArgumentTypeError("coordonnée trop grande")
    return result


def bounds(x, y, size):
    return x * size, y * size, (x + 1) * size - 1, (y + 1) * size - 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("x", type=coordinate)
    parser.add_argument("y", type=coordinate)
    parser.add_argument("--unit", choices=SIZES, default="tile",
                        help="unité des coordonnées saisies (défaut : tile, position en jeu)")
    args = parser.parse_args(argv)
    size = SIZES[args.unit]
    if max(bounds(args.x, args.y, size)) > MAX_COORD:
        parser.error("les bornes dépassent la limite des coordonnées de restauration")
    print("Build 42 — bornes en tuiles, minimum et maximum inclus.")
    units = SIZES if args.unit == "tile" else {args.unit: size}
    labels = {"tile": "Tuile", "chunk": "Chunk", "cell": "Cellule"}
    for unit, width in units.items():
        x, y = (args.x // width, args.y // width) if args.unit == "tile" else (args.x, args.y)
        x1, y1, x2, y2 = bounds(x, y, width)
        print(f"{labels[unit]} ({x}, {y}) — {width}×{width} tuiles : "
              f"minimum ({x1}, {y1}), maximum ({x2}, {y2}).")
        print(f"  restore-zone : x1={x1} y1={y1} x2={x2} y2={y2}")
    print("Restauration : toutes les hauteurs, sous-sols et étages compris.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
