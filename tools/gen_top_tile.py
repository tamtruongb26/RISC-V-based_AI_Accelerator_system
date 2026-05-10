#!/usr/bin/env python3
"""Generate top-level (post_proc-aware) golden vectors for accelerator_top_tb.

Khác với gen_gemm_golden.py:
- Sinh thêm bias.hex (Q1.4.11)
- C.hex là Q1.4.11 sau **đầy đủ pipeline post_proc** (truncate + sat + activation),
  không phải psum thô Q*.8.22.

Pipeline được model bit-exact với hw/accelerator_2_0/hdl/post_proc.v:
  S1: psum_q40 = A @ W (int64)
      bias_q40 = bias_q1411 << 11
      sum_q40 = psum_q40 + bias_q40
      truncate Q*.8.22 → Q1.17.7 = sum_q40 >> 15
      saturate → Q1.8.7 (16-bit signed)
  S2: activation
      bypass: pass
      ReLU:   max(s1, 0)
      sigmoid: sat Q1.8.7 → Q1.3.6 → LUT lookup → Q1.0.9 → Q1.8.7 (>> 2)
  S3: saturate Q1.8.7 → Q1.4.11 via <<<4

Usage:
  python3 tools/gen_top_tile.py --M 4 --K 4 --N 4 --seed 42 --act 0 \\
      --out hw/accelerator_2_0/tb/data --name case2_bypass
"""
import argparse
import os
import sys
from pathlib import Path

import numpy as np


SA_N = 8


def load_sigmoid_rom(path: str):
    rom = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            rom.append(int(line.split()[0], 16))
    assert len(rom) == 1024, f"sigmoid_rom.mem expected 1024 lines, got {len(rom)}"
    return rom


def to_q1_4_11(x: float) -> int:
    """Float → Q1.4.11 16-bit signed (raw)."""
    v = int(round(x * 2048))
    return max(-32768, min(32767, v))


def post_proc_one(psum_q40: int, bias_q1411: int, act_mode: int, sig_rom) -> int:
    """Bit-exact replica of post_proc.v for 1 cell.

    psum_q40: int (signed, ±2^39 range, Q*.8.22)
    bias_q1411: int (signed, Q1.4.11, 16-bit)
    act_mode: 0=bypass, 1=ReLU, 2=sigmoid
    Returns: int (signed, Q1.4.11, 16-bit) = -32768..32767
    """
    # ── S1: Add bias + truncate + sat to Q1.8.7 ──
    bias_q40 = bias_q1411 << 11   # Q1.4.11 → Q*.8.22 (sign-preserving)
    sum_q40 = psum_q40 + bias_q40

    # Truncate Q*.8.22 → Q1.17.7 (arithmetic >> 15)
    sum_q187_wide = sum_q40 >> 15  # Python int arithmetic shift is signed

    # Saturate Q1.17.7 → Q1.8.7 (clamp to 16-bit signed range)
    if sum_q187_wide > 32767:
        s1 = 32767
    elif sum_q187_wide < -32768:
        s1 = -32768
    else:
        s1 = sum_q187_wide

    # ── S2: activation ──
    if act_mode == 0:        # bypass
        act_q187 = s1
    elif act_mode == 1:      # ReLU
        act_q187 = max(s1, 0)
    elif act_mode == 2:      # sigmoid
        # Sat Q1.8.7 → Q1.3.6 (|s1| ≥ 1024 → sat)
        if s1 >= 1024:
            sig_addr = 0x1FF
        elif s1 < -1024:
            sig_addr = 0x200
        else:
            # bit slice [10:1] = arithmetic shift right by 1 (preserve sign in 10-bit)
            # In 16-bit 2's comp, slicing [10:1] = (val >> 1) & 0x3FF after 16-bit unsigned cast
            u16 = s1 & 0xFFFF
            sig_addr = (u16 >> 1) & 0x3FF
        sig_data = sig_rom[sig_addr]   # Q1.0.9
        act_q187 = sig_data >> 2        # Q1.0.9 → Q1.8.7 (always positive)
    else:
        act_q187 = 0

    # ── S3: Saturate Q1.8.7 → Q1.4.11 (act_q187 << 4 nếu không tràn) ──
    if act_q187 >= 2048:
        return 32767      # 0x7FFF
    elif act_q187 < -2048:
        return -32768     # 0x8000
    else:
        return act_q187 << 4


def write_hex(path: str, values, width_bits: int):
    """Write list of ints as hex strings, 2's complement of given width."""
    mask = (1 << width_bits) - 1
    nibbles = (width_bits + 3) // 4
    with open(path, "w") as f:
        for v in values:
            f.write(f"{(int(v) & mask):0{nibbles}x}\n")


def parse_csv_matrix(s: str, rows: int, cols: int):
    mat = []
    for r, row in enumerate(s.split(";")):
        cells = row.split(",")
        if len(cells) != cols:
            raise ValueError(f"Row {r}: expected {cols} cols, got {len(cells)}")
        mat.append([int(x.strip()) for x in cells])
    if len(mat) != rows:
        raise ValueError(f"Expected {rows} rows, got {len(mat)}")
    return mat


def generate_tile(M: int, K: int, N: int, seed: int, act_mode: int,
                  out_dir: str, name: str,
                  sig_rom,
                  range_=1.0, bias_range=0.5, verbose=False):
    """Generate one tile's hex files. Returns dict with stats."""
    rng = np.random.default_rng(seed)
    A_f = rng.uniform(-range_, range_, (M, K))
    W_f = rng.uniform(-range_, range_, (K, N))
    bias_f = rng.uniform(-bias_range, bias_range, SA_N)
    A = np.array([[to_q1_4_11(x) for x in row] for row in A_f], dtype=np.int64)
    W = np.array([[to_q1_4_11(x) for x in row] for row in W_f], dtype=np.int64)
    bias = np.array([to_q1_4_11(x) for x in bias_f], dtype=np.int64)

    W_pad = np.zeros((SA_N, SA_N), dtype=np.int64)
    W_pad[:K, :N] = W

    psum = np.zeros((M, N), dtype=np.int64)
    for m in range(M):
        for n in range(N):
            s = 0
            for k in range(K):
                s += int(A[m, k]) * int(W[k, n])
            psum[m, n] = s

    C = np.zeros((M, N), dtype=np.int64)
    for m in range(M):
        for n in range(N):
            C[m, n] = post_proc_one(int(psum[m, n]), int(bias[n]), act_mode, sig_rom)

    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    write_hex(out / f"{name}_A.hex",     A.flatten().tolist(),     16)
    write_hex(out / f"{name}_W.hex",     W_pad.flatten().tolist(), 16)
    write_hex(out / f"{name}_bias.hex",  bias.tolist(),            16)
    write_hex(out / f"{name}_C.hex",     C.flatten().tolist(),     16)

    if verbose:
        print(f"  {name}: M={M} K={K} N={N} act={act_mode}  C∈[{C.min()},{C.max()}]")

    return {"A": A, "W": W_pad, "bias": bias, "C": C}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--M", type=int, required=True)
    ap.add_argument("--K", type=int, required=True)
    ap.add_argument("--N", type=int, required=True)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--act", type=int, default=0,
                    help="0=bypass, 1=ReLU, 2=sigmoid")
    ap.add_argument("--range", type=float, default=1.0,
                    help="abs cap for random A/W (avoid Q1.4.11 sat)")
    ap.add_argument("--bias_range", type=float, default=0.5,
                    help="abs cap for random bias")
    ap.add_argument("--out", required=True, help="Output dir")
    ap.add_argument("--name", required=True, help="Case name prefix")
    ap.add_argument("--sigmoid_rom", default="hw/accelerator_2_0/hdl/sigmoid_rom.mem")
    ap.add_argument("--hardcoded", action="store_true")
    ap.add_argument("--hard_A", default=None, help="CSV: 'r0c0,r0c1;r1c0,r1c1' (raw int)")
    ap.add_argument("--hard_W", default=None)
    ap.add_argument("--hard_bias", default=None, help="CSV: 'b0,b1,...,b7' (8 raw ints)")
    args = ap.parse_args()

    M, K, N = args.M, args.K, args.N
    if not (1 <= M <= SA_N and 1 <= K <= SA_N and 1 <= N <= SA_N):
        print(f"ERROR: M, K, N ∈ [1, {SA_N}]", file=sys.stderr)
        return 1
    if args.act not in (0, 1, 2):
        print("ERROR: act ∈ {0, 1, 2}", file=sys.stderr)
        return 1

    sig_rom = load_sigmoid_rom(args.sigmoid_rom)

    # ── Sinh A (M×K), W (K×N), bias (SA_N) ──
    if args.hardcoded:
        if not (args.hard_A and args.hard_W):
            print("ERROR: --hardcoded cần --hard_A và --hard_W", file=sys.stderr)
            return 1
        A = np.array(parse_csv_matrix(args.hard_A, M, K), dtype=np.int64)
        W = np.array(parse_csv_matrix(args.hard_W, K, N), dtype=np.int64)
        if args.hard_bias:
            biases = [int(x.strip()) for x in args.hard_bias.split(",")]
            if len(biases) != SA_N:
                raise ValueError(f"hard_bias cần {SA_N} giá trị, got {len(biases)}")
            bias = np.array(biases, dtype=np.int64)
        else:
            bias = np.zeros(SA_N, dtype=np.int64)
    else:
        rng = np.random.default_rng(args.seed)
        A_f = rng.uniform(-args.range, args.range, (M, K))
        W_f = rng.uniform(-args.range, args.range, (K, N))
        bias_f = rng.uniform(-args.bias_range, args.bias_range, SA_N)
        A = np.array([[to_q1_4_11(x) for x in row] for row in A_f], dtype=np.int64)
        W = np.array([[to_q1_4_11(x) for x in row] for row in W_f], dtype=np.int64)
        bias = np.array([to_q1_4_11(x) for x in bias_f], dtype=np.int64)

    # ── Pad W to SA_N × SA_N (zero-pad) ──
    W_pad = np.zeros((SA_N, SA_N), dtype=np.int64)
    W_pad[:K, :N] = W

    # ── Compute psum (int64) ──
    psum = np.zeros((M, N), dtype=np.int64)
    for m in range(M):
        for n in range(N):
            s = 0
            for k in range(K):
                s += int(A[m, k]) * int(W[k, n])
            psum[m, n] = s

    # ── Apply post_proc pipeline for each cell ──
    C = np.zeros((M, N), dtype=np.int64)
    for m in range(M):
        for n in range(N):
            C[m, n] = post_proc_one(int(psum[m, n]), int(bias[n]), args.act, sig_rom)

    # ── Write hex files ──
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    write_hex(out / f"{args.name}_A.hex",     A.flatten().tolist(),     16)
    write_hex(out / f"{args.name}_W.hex",     W_pad.flatten().tolist(), 16)
    write_hex(out / f"{args.name}_bias.hex",  bias.tolist(),            16)
    write_hex(out / f"{args.name}_C.hex",     C.flatten().tolist(),     16)

    print(f"Generated {args.name}_*.hex in {args.out}")
    print(f"  Tile: M={M} K={K} N={N}, act={args.act}")
    print(f"  A range: [{A.min()}, {A.max()}]")
    print(f"  W range: [{W.min()}, {W.max()}]")
    print(f"  bias range: [{bias.min()}, {bias.max()}]")
    print(f"  C range: [{C.min()}, {C.max()}]")
    if M <= 4 and N <= 4:
        print("  C cells (Q1.4.11 raw):")
        for m in range(M):
            print("    " + " ".join(f"{C[m, n]:>7d}" for n in range(N)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
