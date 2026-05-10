#!/usr/bin/env python3
"""gen_smoketest.py — sinh test data header cho PS app embed.

Output: sw/vitis/RAS_application/src/smoketest_data.h chứa 4 C arrays:
  - smoketest_weights[32]   : uint32_t, 8x8 padded weights packed Q1.4.11 even/odd
  - smoketest_bias[4]       : uint32_t, 8 bias packed
  - smoketest_input[32]     : uint32_t, M=8 × ceil(K/2)=4 = 32 word
  - smoketest_golden[64]    : uint16_t, expected output Q1.4.11 (M*N cells)

Reuses bit-exact pipeline simulation từ tools/gen_top_tile.py
(đã verified với data_path_tb 256/256 cell + accelerator_top_tb 1248/1248 cell).

Plan ref: §8.4 (Step 14.4.2).

Usage:
    python3 tools/gen_smoketest.py [--seed SEED] [--act 0|1|2] [--out PATH]

Use a Python environment with numpy installed. The Vitis 2025.2.1 bundled
Python works when its lib directory is added to LD_LIBRARY_PATH.

Stage A default: M=K=N=8, bypass (act=0), seed=42.
"""
import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from gen_top_tile import generate_tile, load_sigmoid_rom, SA_N


def pack_word(elem_lo: int, elem_hi: int) -> int:
    """Pack 2 × 16-bit signed Q1.4.11 → 1 × 32-bit AXIS word.
    word[15:0]  = even index
    word[31:16] = odd index"""
    return ((elem_hi & 0xFFFF) << 16) | (elem_lo & 0xFFFF)


def pack_matrix(mat_2d, M: int, K: int):
    """Pack mat[M][K] → list of M × ceil(K/2) uint32 words.
    Pad odd K bằng 0."""
    K_pairs = (K + 1) // 2
    words = []
    for m in range(M):
        for p in range(K_pairs):
            lo = int(mat_2d[m, 2*p])
            hi = int(mat_2d[m, 2*p+1]) if 2*p+1 < K else 0
            words.append(pack_word(lo, hi))
    return words


def pack_vector(vec, length: int):
    """Pack 1D vector → ceil(length/2) words."""
    pairs = (length + 1) // 2
    words = []
    for p in range(pairs):
        lo = int(vec[2*p])
        hi = int(vec[2*p+1]) if 2*p+1 < length else 0
        words.append(pack_word(lo, hi))
    return words


def write_c_header(out_path: Path, weights_words, bias_words, input_words,
                   golden_cells, M: int, K: int, N: int, act_mode: int,
                   seed: int):
    """Sinh smoketest_data.h chứa 4 C arrays."""
    act_name = ["bypass", "ReLU", "sigmoid"][act_mode]

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as f:
        f.write("/* AUTO-GENERATED bởi tools/gen_smoketest.py - do NOT edit */\n")
        f.write(f"/* Tile: M={M} K={K} N={N}, act={act_name}, seed={seed} */\n\n")
        f.write("#ifndef RAAS_SMOKETEST_DATA_H\n")
        f.write("#define RAAS_SMOKETEST_DATA_H\n\n")
        f.write("#include <stdint.h>\n\n")

        # Weights: 8 row × 4 word = 32 word
        f.write(f"/* Weights: {len(weights_words)} word, 8x8 padded */\n")
        f.write(f"static const uint32_t smoketest_weights[{len(weights_words)}] = {{\n")
        for i in range(0, len(weights_words), 4):
            row = ", ".join(f"0x{w:08x}u" for w in weights_words[i:i+4])
            f.write(f"    {row},\n")
        f.write("};\n\n")

        # Bias: 4 word
        f.write(f"/* Bias: {len(bias_words)} word */\n")
        f.write(f"static const uint32_t smoketest_bias[{len(bias_words)}] = {{\n")
        f.write("    " + ", ".join(f"0x{w:08x}u" for w in bias_words) + ",\n")
        f.write("};\n\n")

        # Input: M × ceil(K/2)
        f.write(f"/* Input: {len(input_words)} word (M={M} × ceil(K/2)={(K+1)//2}) */\n")
        f.write(f"static const uint32_t smoketest_input[{len(input_words)}] = {{\n")
        for i in range(0, len(input_words), 4):
            row = ", ".join(f"0x{w:08x}u" for w in input_words[i:i+4])
            f.write(f"    {row},\n")
        f.write("};\n\n")

        # Golden: 64 × uint16 cells (raw Q1.4.11)
        f.write(f"/* Golden output: {len(golden_cells)} cells Q1.4.11 raw */\n")
        f.write(f"static const uint16_t smoketest_golden[{len(golden_cells)}] = {{\n")
        for i in range(0, len(golden_cells), 8):
            row = ", ".join(f"0x{c & 0xFFFF:04x}u" for c in golden_cells[i:i+8])
            f.write(f"    {row},\n")
        f.write("};\n\n")

        f.write("#endif /* RAAS_SMOKETEST_DATA_H */\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--M", type=int, default=8)
    ap.add_argument("--K", type=int, default=8)
    ap.add_argument("--N", type=int, default=8)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--act", type=int, default=0,
                    choices=[0, 1, 2],
                    help="0=bypass, 1=ReLU, 2=sigmoid")
    ap.add_argument("--out", default="sw/vitis/RAS_application/src/smoketest_data.h")
    ap.add_argument("--sigmoid_rom", default="hw/accelerator_2_0/hdl/sigmoid_rom.mem")
    args = ap.parse_args()

    M, K, N = args.M, args.K, args.N
    if not (1 <= M <= SA_N and 1 <= K <= SA_N and 1 <= N <= SA_N):
        print(f"ERROR: M, K, N ∈ [1, {SA_N}]", file=sys.stderr)
        return 1

    # Reuse generate_tile() — đã verified bit-exact pipeline.
    # Output là dict {A, W, bias, C} với A/W là (M, K), W zero-padded → (8, 8).
    sig_rom = load_sigmoid_rom(args.sigmoid_rom)
    out_dir = Path("/tmp/raas_smoketest_tmp")
    out_dir.mkdir(exist_ok=True)
    res = generate_tile(M, K, N, seed=args.seed, act_mode=args.act,
                       out_dir=str(out_dir), name="smoketest_tmp",
                       sig_rom=sig_rom, verbose=False)

    A = res["A"]            # (M, K)
    W_pad = res["W"]        # (8, 8) zero-padded
    bias = res["bias"]      # (8,) zero-padded to SA_N
    C = res["C"]            # (M, N)

    # Pack thành AXIS word stream
    # Weights: full 8×8 (zero-padded), 8 row × 4 word/row = 32 word
    weights_words = pack_matrix(W_pad, SA_N, SA_N)

    # Bias: SA_N=8 elements → 4 word
    bias_words = pack_vector(bias, SA_N)

    # Input: M × ceil(K/2) word, only used cells
    input_words = pack_matrix(A, M, K)

    # Golden: M*N cells flat row-major (uint16, raw Q1.4.11 two's comp)
    golden_cells = C.flatten().tolist()

    # Sanity check counts
    assert len(weights_words) == 32, f"weights count = {len(weights_words)}"
    assert len(bias_words) == 4
    assert len(input_words) == M * ((K + 1) // 2)
    assert len(golden_cells) == M * N

    out_path = Path(args.out)
    write_c_header(out_path, weights_words, bias_words, input_words,
                   golden_cells, M, K, N, args.act, args.seed)

    print(f"Generated {out_path}")
    print(f"  Tile: M={M} K={K} N={N}, act={args.act}, seed={args.seed}")
    print(f"  weights={len(weights_words)} word, bias={len(bias_words)} word, "
          f"input={len(input_words)} word, golden={len(golden_cells)} cells")
    print(f"  C range: [{C.min()}, {C.max()}]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
