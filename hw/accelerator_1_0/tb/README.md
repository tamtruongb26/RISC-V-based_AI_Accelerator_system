# Accelerator Smoke Testbench

This folder hosts the XSIM smoke testbench for the accelerator IP.

## Files

- `accelerator_smoke_tb.sv` — main testbench
- `raas_demo_vectors.svh` — demo metadata and `$readmemh` file paths

Demo memory payloads are generated into `build/sim/data/` by `script/01_prepare_demo_data.tcl`.

## Run

From the repository root:

```bash
/home/tam/Documents/app/2025.2.1/Vivado/bin/vivado -mode batch -source script/02_run_smoke_sim.tcl
```

## Outputs

- `build/sim/xsim/` — XSIM compilation/simulation artifacts
- `build/sim/data/` — generated `.mem` files for the smoke test

Both folders are safe to delete; they will be regenerated on the next run.
