# PicoRV32 Testbench

Simple SystemVerilog smoke test for `picorv32.v`.

## Files

- `picorv32_tb.sv` - releases reset, returns NOP instructions from a tiny memory model, and checks that the core fetches without trapping.

## Example Icarus Command

Run from the repository root if `iverilog` is available:

```bash
iverilog -g2012 -o /tmp/picorv32_tb.vvp \
  hw/picorv32-vivado-ip/src/picorv32.v \
  hw/picorv32-vivado-ip/tb/picorv32_tb.sv
vvp /tmp/picorv32_tb.vvp
```
