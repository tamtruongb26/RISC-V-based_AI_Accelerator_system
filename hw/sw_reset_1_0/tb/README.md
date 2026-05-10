# sw_reset Testbenches

Simple SystemVerilog smoke/unit tests for the `sw_reset_1_0` IP.

## Files

- `sw_reset_slave_lite_tb.sv` - checks the AXI-Lite slave register and `po_sw_rstn` output.
- `sw_reset_tb.sv` - checks the top-level wrapper through the AXI-Lite interface.

## Example Icarus Commands

Run from the repository root if `iverilog` is available:

```bash
iverilog -g2012 -o /tmp/sw_reset_slave_lite_tb.vvp \
  hw/sw_reset_1_0/hdl/sw_reset_slave_lite_v1_0_S00_AXI.v \
  hw/sw_reset_1_0/tb/sw_reset_slave_lite_tb.sv
vvp /tmp/sw_reset_slave_lite_tb.vvp

iverilog -g2012 -o /tmp/sw_reset_tb.vvp \
  hw/sw_reset_1_0/hdl/sw_reset_slave_lite_v1_0_S00_AXI.v \
  hw/sw_reset_1_0/hdl/sw_reset.v \
  hw/sw_reset_1_0/tb/sw_reset_tb.sv
vvp /tmp/sw_reset_tb.vvp
```
