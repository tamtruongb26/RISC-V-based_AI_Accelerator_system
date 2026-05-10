#!/usr/bin/env python3
"""bin_to_c.py — convert raw binary → C array header

Usage:
    python3 tools/bin_to_c.py <input.bin> <output.h> <symbol_name>

Output format:
    static const uint8_t <symbol>[<N>] = { 0xXX, 0xXX, ... };
    static const uint32_t <symbol>_len = <N>;

Plan ref: §8.4 (Step 14.4.1) — required by sw/picorv32/Makefile to embed
PicoRV32 firmware vào PS app.
"""
import sys
from pathlib import Path


def main(argv):
    if len(argv) != 4:
        print(f"Usage: {argv[0]} <input.bin> <output.h> <symbol_name>",
              file=sys.stderr)
        return 1

    in_path = Path(argv[1])
    out_path = Path(argv[2])
    symbol = argv[3]

    if not in_path.is_file():
        print(f"ERROR: input not found: {in_path}", file=sys.stderr)
        return 1

    data = in_path.read_bytes()
    n = len(data)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as f:
        f.write(f"/* AUTO-GENERATED from {in_path.name} - do not edit manually */\n")
        f.write(f"#ifndef RAAS_{symbol.upper()}_H\n")
        f.write(f"#define RAAS_{symbol.upper()}_H\n\n")
        f.write("#include <stdint.h>\n\n")
        f.write(f"static const uint8_t {symbol}[{n}] = {{\n")
        # 12 bytes/dòng cho dễ đọc
        for i in range(0, n, 12):
            row = data[i:i+12]
            hex_bytes = ", ".join(f"0x{b:02x}" for b in row)
            f.write(f"    {hex_bytes},\n")
        f.write("};\n\n")
        f.write(f"static const uint32_t {symbol}_len = {n}u;\n\n")
        f.write(f"#endif /* RAAS_{symbol.upper()}_H */\n")

    print(f"Generated {out_path} ({n} bytes → {out_path.stat().st_size} bytes header)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
