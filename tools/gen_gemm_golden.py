#!/usr/bin/env python3
"""Generate GEMM golden test vectors for accelerator_2_0 data_path_tb.

Outputs 3 hex files per case:
  - <name>_A.hex: SA_N*SA_N dòng hex 16-bit (Q1.4.11 raw signed integer), row-major.
  - <name>_W.hex: SA_N*SA_N dòng hex 16-bit, row-major.
  - <name>_C.hex: SA_N*SA_N dòng hex 40-bit (Q2.8.22 raw signed integer), row-major.

Tile có shape M×K×N (1 ≤ M, K, N ≤ SA_N). Vùng dùng: A[0..M-1][0..K-1], W[0..K-1][0..N-1].
Phần còn lại padded với 0 để khớp grid SA_N×SA_N của data_path.

Computed C[m][n] = sum_k(A_q[m][k] × W_q[k][n]) — exact integer multiply,
KHÔNG saturate / KHÔNG truncate (vì hardware giữ 40-bit cho 8 phép sum K=8).

Usage:
  # Case random:
  python3 gen_gemm_golden.py --M 8 --K 8 --N 8 --seed 42 \
      --out hw/accelerator_2_0/tb/data --name case2

  # Case hardcoded (small ints, sanity):
  python3 gen_gemm_golden.py --M 2 --K 2 --N 2 --hardcoded \
      --hard_A "1,2;3,4" --hard_W "5,6;7,8" \
      --out hw/accelerator_2_0/tb/data --name case1
"""
import argparse
import os
import sys

import numpy as np


def to_q1_4_11(x: float) -> int:
    """Float → Q1.4.11 16-bit signed integer."""
    v = int(round(x * 2048))
    return max(-32768, min(32767, v))


def write_hex(path: str, values, width_bits: int) -> None:
    """Write list of integers as hex strings, two's complement of given width."""
    mask = (1 << width_bits) - 1
    nibbles = (width_bits + 3) // 4
    with open(path, "w") as f:
        for v in values:
            f.write(f"{(int(v) & mask):0{nibbles}x}\n")


def parse_csv_matrix(s: str, rows: int, cols: int):
    """Parse '1,2;3,4' → 2D list."""
    mat = []
    row_strs = s.split(";")
    if len(row_strs) != rows:
        raise ValueError(f"Expected {rows} rows in '{s}', got {len(row_strs)}")
    for r, row in enumerate(row_strs):
        cells = row.split(",")
        if len(cells) != cols:
            raise ValueError(f"Row {r}: expected {cols} cols, got {len(cells)}")
        mat.append([int(x.strip()) for x in cells])
    return mat


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--M", type=int, required=True, help="A rows used (1..SA_N)")
    ap.add_argument("--K", type=int, required=True, help="A cols / W rows used")
    ap.add_argument("--N", type=int, required=True, help="W cols used")
    ap.add_argument("--SA_N", type=int, default=8, help="Systolic array size (padded matrix)")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--range", type=float, default=1.5,
                    help="abs value cap for random (avoid Q1.4.11 saturation)")
    ap.add_argument("--out", required=True, help="Output dir")
    ap.add_argument("--name", required=True, help="Case name prefix (e.g. case1)")
    ap.add_argument("--hardcoded", action="store_true",
                    help="Use --hard_A / --hard_W instead of random")
    ap.add_argument("--hard_A", default=None,
                    help="Hardcoded A matrix as CSV: 'r0c0,r0c1;r1c0,r1c1'")
    ap.add_argument("--hard_W", default=None)
    args = ap.parse_args()

    SA_N = args.SA_N
    M, K, N = args.M, args.K, args.N
    if not (1 <= M <= SA_N and 1 <= K <= SA_N and 1 <= N <= SA_N):
        print(f"ERROR: M, K, N must be in [1, SA_N={SA_N}]", file=sys.stderr)
        return 1

    # Sinh A và W (M×K, K×N)
    if args.hardcoded:
        if args.hard_A is None or args.hard_W is None:
            print("ERROR: --hardcoded requires --hard_A and --hard_W", file=sys.stderr)
            return 1
        A_used = np.array(parse_csv_matrix(args.hard_A, M, K), dtype=np.int64)
        W_used = np.array(parse_csv_matrix(args.hard_W, K, N), dtype=np.int64)
    else:
        rng = np.random.default_rng(args.seed)
        A_float = rng.uniform(-args.range, args.range, (M, K))
        W_float = rng.uniform(-args.range, args.range, (K, N))
        A_used = np.array([[to_q1_4_11(x) for x in row] for row in A_float], dtype=np.int64)
        W_used = np.array([[to_q1_4_11(x) for x in row] for row in W_float], dtype=np.int64)

    # Pad lên SA_N × SA_N
    A_pad = np.zeros((SA_N, SA_N), dtype=np.int64)
    W_pad = np.zeros((SA_N, SA_N), dtype=np.int64)
    A_pad[:M, :K] = A_used
    W_pad[:K, :N] = W_used

    # Tính C bằng integer arithmetic chính xác (NumPy mặc định dùng int64)
    C_pad = np.zeros((SA_N, SA_N), dtype=np.int64)
    for m in range(M):
        for n in range(N):
            s = 0
            for k in range(K):
                s += int(A_used[m, k]) * int(W_used[k, n])
            C_pad[m, n] = s

    # Sanity check: C có lọt 40-bit signed không?
    INT40_MIN = -(1 << 39)
    INT40_MAX = (1 << 39) - 1
    if (C_pad < INT40_MIN).any() or (C_pad > INT40_MAX).any():
        print(f"ERROR: C overflow 40-bit signed. Range [{C_pad.min()}, {C_pad.max()}]",
              file=sys.stderr)
        return 1

    os.makedirs(args.out, exist_ok=True)
    a_path = os.path.join(args.out, f"{args.name}_A.hex")
    w_path = os.path.join(args.out, f"{args.name}_W.hex")
    c_path = os.path.join(args.out, f"{args.name}_C.hex")

    write_hex(a_path, A_pad.flatten().tolist(), 16)
    write_hex(w_path, W_pad.flatten().tolist(), 16)
    write_hex(c_path, C_pad.flatten().tolist(), 40)

    # Báo cáo
    print(f"Generated {args.name}_*.hex in {args.out}")
    print(f"  Tile: M={M} K={K} N={N}, padded to {SA_N}×{SA_N}")
    print(f"  Hardcoded: {args.hardcoded}")
    if not args.hardcoded:
        print(f"  Seed={args.seed}, range=±{args.range}")
    print(f"  A range: [{A_pad.min()}, {A_pad.max()}]")
    print(f"  W range: [{W_pad.min()}, {W_pad.max()}]")
    print(f"  C range: [{C_pad.min()}, {C_pad.max()}]")
    print(f"  Used C[0..M-1][0..N-1]:")
    for m in range(M):
        print("    " + " ".join(f"{C_pad[m, n]:>15d}" for n in range(N)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
