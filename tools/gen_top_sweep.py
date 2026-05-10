#!/usr/bin/env python3
"""Generate sweep test vectors cho accelerator_top_tb Case 3 (50 random tile).

Usage:
  python3 tools/gen_top_sweep.py --N 50 --seed 42 \\
      --out hw/accelerator_2_0/tb/data
"""
import argparse
import sys
from pathlib import Path

import numpy as np

# Import từ gen_top_tile.py
sys.path.insert(0, str(Path(__file__).parent))
from gen_top_tile import (
    generate_tile, load_sigmoid_rom, SA_N
)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--N", type=int, default=50, help="Number of tiles")
    ap.add_argument("--seed", type=int, default=42, help="Master seed")
    ap.add_argument("--out", required=True, help="Output dir")
    ap.add_argument("--name_prefix", default="sweep", help="Output name prefix")
    ap.add_argument("--act", type=int, default=0, help="0=bypass, 1=ReLU, 2=sigmoid")
    ap.add_argument("--sigmoid_rom", default="hw/accelerator_2_0/hdl/sigmoid_rom.mem")
    args = ap.parse_args()

    sig_rom = load_sigmoid_rom(args.sigmoid_rom)
    rng = np.random.default_rng(args.seed)

    print(f"Generating {args.N} sweep tiles → {args.out}/{args.name_prefix}_*")
    print(f"  ACT_MODE = {args.act} ({['bypass','ReLU','sigmoid'][args.act]})")
    print()

    # Sinh dimension table trước (deterministic)
    Ms = rng.integers(1, SA_N + 1, args.N)
    Ks = rng.integers(1, SA_N + 1, args.N)
    Ns = rng.integers(1, SA_N + 1, args.N)
    seeds = rng.integers(0, 2**30, args.N)

    # Manifest: lưu (idx, M, K, N) cho TB load
    manifest_path = Path(args.out) / f"{args.name_prefix}_manifest.txt"
    with open(manifest_path, "w") as mf:
        mf.write(f"# {args.N} tile sweep, master seed={args.seed}, act={args.act}\n")
        mf.write("# format: idx M K N\n")
        for i in range(args.N):
            mf.write(f"{i:02d} {Ms[i]} {Ks[i]} {Ns[i]}\n")
            generate_tile(int(Ms[i]), int(Ks[i]), int(Ns[i]),
                          seed=int(seeds[i]),
                          act_mode=args.act,
                          out_dir=args.out,
                          name=f"{args.name_prefix}_{i:02d}",
                          sig_rom=sig_rom,
                          verbose=True)

    print(f"\nDone. Manifest: {manifest_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
