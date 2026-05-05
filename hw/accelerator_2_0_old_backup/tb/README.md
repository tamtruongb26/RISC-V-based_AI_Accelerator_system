# Accelerator 2.0 — Testbenches (TPU-like Systolic Rewrite)

Unit and integration TBs for the rewritten `accelerator_2_0` (true weight-
stationary systolic 8×8: activations propagate horizontally, psum vertically).

## Files

| File | Purpose |
|---|---|
| `pe_tb.sv` | PE unit test: weight load, MAC, horizontal pass-through, sign handling, psum pass-through when `valid=0`. |
| `data_path_tb.sv` | 2×2 systolic GEMM test (A·W with handcoded golden). |
| `run_pe_tb.tcl` | Vivado batch runner for `pe_tb`. |
| `run_data_path_tb.tcl` | Vivado batch runner for `data_path_tb`. |

## Run in Vivado (batch)

```bash
cd hw/accelerator_2_0/tb
vivado -mode batch -source run_pe_tb.tcl
vivado -mode batch -source run_data_path_tb.tcl
```

## Run in Vivado GUI

1. Create RTL Project.
2. Add `hdl/pe.v` (and `hdl/data_path.v` for the 2×2 test).
3. Add the corresponding `*_tb.sv`.
4. Set the testbench as simulation top.
5. Run Behavioral Simulation.

## Expected Output

All checks print `[ OK ]` and a final `=== ALL ... TESTS PASSED ===`.

## TODO

- `control_unit_tb.sv` — drive AXI-Lite/Stream stimuli through the full FSM.
- `accelerator_top_tb.sv` — 8×8 GEMM with Python-generated golden vectors.
- Tile sweep (M, K, N ∈ 1..8) to verify boundary cases.
