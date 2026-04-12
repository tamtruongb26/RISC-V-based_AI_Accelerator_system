# RISC-V-based_AI_Accelerator_system


## Overview
A RISC-V (PicoRV32) based neural network hardware accelerator targeting the **Ultra96v2** FPGA board (Zynq UltraScale+ MPSoC).

### Key Features
- **PicoRV32** soft-core RISC-V processor as host controller
- **MLP Neural Network** hardware accelerator (784→16→16→10, MNIST)
- **AXI DMA** for high-speed data transfer between DDR4 and accelerator
- **Zynq UltraScale+ PS** providing DDR4 memory access via HP port
- Fixed-point arithmetic (1.4.11 format, 16-bit)


### Architecture
```
PicoRV32 (RISC-V) ──AXI──> AXI Interconnect
                              ├──> MLP Accelerator (AXI-Lite control)
                              ├──> AXI DMA (config) ──AXI-Stream──> MLP Accelerator
                              ├──> Boot BRAM (firmware)
                              └──> SW Reset
                            
AXI DMA ──AXI──> SmartConnect ──> Zynq PS HP Port ──> DDR4
```


### Tools
- Xilinx Vivado 2024.1
- RISC-V GNU Toolchain (riscv32-unknown-elf-gcc)
- Python 3.13.12 (training & utilities)


### Project Structure
```
docs/           - Documentation
fpga/           - 
hw/             - HDL source files (Verilog/ SystemVerilog)
model/          - Training data & reference code
references/     - 
sw/             - C firmware
```

## Based on
- [Deep-Neural-Network-Hardware-Accelerator](https://github.com/StefanSredojevic/Deep-Neural-Network-Hardware-Accelerator)