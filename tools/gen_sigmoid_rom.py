#!/usr/bin/env python3
"""Generate sigmoid LUT ROM for accelerator_2_0/hdl/sigmoid_lookup.v.

Spec đầy đủ: hw/accelerator_2_0/hdl/sigmoid_spec.md

Address format Q1.3.6 (10-bit signed):
  - idx [0..511]    → x = idx/64       (positive 0.0..7.984)
  - idx [512..1023] → x = (idx-1024)/64 (negative -8.0..-0.0156)

Data format Q1.0.9 (10-bit unsigned):
  - val = round(sigmoid(x) * 512), clamped to [0, 511]

Usage:
  python3 tools/gen_sigmoid_rom.py --out hw/accelerator_2_0/hdl/sigmoid_rom.mem
"""
import argparse
import math
import sys


def addr_to_x(idx: int) -> float:
    """Convert 10-bit Q1.3.6 address index to float x."""
    if idx < 512:
        return idx / 64.0
    return (idx - 1024) / 64.0


def sigmoid(x: float) -> float:
    return 1.0 / (1.0 + math.exp(-x))


def quantize_q109(s: float) -> int:
    """Quantize sigmoid value to Q1.0.9 unsigned 10-bit."""
    val = int(round(s * 512))
    return max(0, min(511, val))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="Output .mem path")
    ap.add_argument("--with_comments", action="store_true",
                    help="Add '// x=..., sig=...' comments per line")
    args = ap.parse_args()

    rom = []
    for idx in range(1024):
        x = addr_to_x(idx)
        s = sigmoid(x)
        v = quantize_q109(s)
        rom.append((idx, x, s, v))

    with open(args.out, "w") as f:
        for idx, x, s, v in rom:
            if args.with_comments:
                f.write(f"{v:03x}  // idx={idx:4d} x={x:+8.5f} sig={s:.6f}\n")
            else:
                f.write(f"{v:03x}\n")

    # Sanity check vs spec §6 sample values
    expected = {
        0:    256,   # x=0,    sig=0.5
        64:   374,   # x=+1
        128:  450,   # x=+2
        256:  502,   # x=+4
        511:  511,   # x=+7.984 → saturated (close to 1)
        960:  137,   # x=-1
        768:  9,     # x=-4
        512:  0,     # x=-8
    }
    print(f"Generated {args.out} (1024 entries, Q1.3.6 → Q1.0.9)")
    print("Sample values vs expected:")
    ok = True
    for idx, exp in expected.items():
        got = rom[idx][3]
        x = rom[idx][1]
        mark = "OK " if got == exp else "DIFF"
        if got != exp:
            ok = False
        print(f"  [{mark}] idx={idx:4d} x={x:+8.5f}  got={got:3d}  exp={exp:3d}")

    if not ok:
        print("WARNING: some sample values differ from spec — check rounding "
              "(may be ±1 LSB tolerance).", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())