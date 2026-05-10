# Accelerator Testbenches

This folder hosts simple SystemVerilog testbenches for the accelerator IP. The tests are intentionally small: each one has a clock/reset, stimulus, basic self-checks with `$fatal`, waveform dump, timeout, and a clean `$finish`.

## Files

- `accelerator_smoke_tb.sv` - full demo-vector smoke test using generated RAAS memory files.
- `accelerator_simple_tb.sv` - small top-level accelerator smoke test with a 2-node network.
- `accelerator_slave_lite_tb.sv` - AXI-Lite register/readback test for `accelerator_slave_lite_v1_0_S00_AXI.v`.
- `accelerator_slave_stream_tb.sv` - AXI-Stream input-buffer test for `accelerator_slave_stream_v1_0_S00_AXIS.v`.
- `accelerator_master_stream_tb.sv` - AXI-Stream output handshake/TLAST test for `accelerator_master_stream_v1_0_M00_AXIS.v`.
- `bram_tb.sv` - dual-port BRAM write/read test.
- `neuron_tb.sv` - neuron MAC/address-generation smoke test.
- `sigmoid_lookup_tb.sv` - sigmoid LUT read test.
- `raas_demo_vectors.svh` - demo metadata and `$readmemh` file paths for `accelerator_smoke_tb.sv`.

## Existing Demo Run

From the repository root:

```bash
/home/tam/Documents/app/2025.2.1/Vivado/bin/vivado -mode batch -source script/02_run_smoke_sim.tcl
```

## Example Icarus Commands

Run from the repository root if `iverilog` is available:

```bash
iverilog -g2012 -o /tmp/accelerator_slave_stream_tb.vvp \
  hw/accelerator_1_0/src/accelerator_slave_stream_v1_0_S00_AXIS.v \
  hw/accelerator_1_0/tb/accelerator_slave_stream_tb.sv
vvp /tmp/accelerator_slave_stream_tb.vvp

iverilog -g2012 -o /tmp/accelerator_master_stream_tb.vvp \
  hw/accelerator_1_0/src/accelerator_master_stream_v1_0_M00_AXIS.v \
  hw/accelerator_1_0/tb/accelerator_master_stream_tb.sv
vvp /tmp/accelerator_master_stream_tb.vvp

iverilog -g2012 -o /tmp/accelerator_slave_lite_tb.vvp \
  hw/accelerator_1_0/src/accelerator_slave_lite_v1_0_S00_AXI.v \
  hw/accelerator_1_0/tb/accelerator_slave_lite_tb.sv
vvp /tmp/accelerator_slave_lite_tb.vvp
```
