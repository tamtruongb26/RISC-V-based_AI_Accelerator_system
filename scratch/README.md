# Scratch Workspace

This folder is for small helper scripts, quick experiments, and generated-data utilities that support the main accelerator flow without being part of the core build.

## Current Contents

### `gen_sigmoid.py`

Generates a SystemVerilog lookup-table module for the sigmoid activation used by the MLP accelerator.

- Output file: `hw/sigmoid_lookup.sv`
- Table depth: `1024` entries
- Output width: `10` bits
- Address interpretation:
  the script treats the 10-bit address as a signed value in the range `-512..511`
- Input domain:
  `x = addr / 32.0`, which maps approximately to `[-16.0, +15.96875]`
- Output encoding:
  `round(sigmoid(x) * 512)`, clamped to `0..512`

This makes the LUT convenient for fixed-point hardware, where sigmoid values are represented with a scale factor of `512`.

## How To Run

From the repository root:

```powershell
python .\scratch\gen_sigmoid.py
```

After it runs successfully, the script prints:

```text
Generated sigmoid_lookup.sv
```

## Notes

- The script currently writes to an absolute Windows path stored in `file_path`.
- If the repository is moved, update that path before running the script.
- The main project uses fixed-point arithmetic for hardware inference, while the training/reference flow lives under `model/`.
- Generated artifacts such as `sigmoid_lookup.sv` are intended to feed the RTL in `hw/`.
