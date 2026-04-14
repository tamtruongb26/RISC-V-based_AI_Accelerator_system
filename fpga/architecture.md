# RISC-V AI Accelerator — Architecture Document

## System Overview

This system implements a **hardware-accelerated Multi-Layer Perceptron (MLP)** neural network on the **Ultra96v2** FPGA board, controlled by a **PicoRV32** RISC-V soft-core processor.

### Block Diagram

```text
┌─────────────────────────────────── Programmable Logic (PL) ─────────────────────────────────────┐
│                                                                                                 │
│  ┌──────────┐                     ┌──────────────────────────────────┐                          │
│  │ Zynq PS  │─── M_HPM0_FPD ─────>│                                  │                          │
│  └──────────┘                     │                                  │── M00 ──> PS HP0 (DDR4)  │
│  ┌──────────┐                     │                                  │                          │
│  │ PicoRV32 │─── M_AXI ──────────>│       AXI SmartConnect           │── M01 ──> MLP Accel      │
│  └──────────┘                     │       (Crossbar Interconnect)    │                          │
│  ┌──────────┐                     │                                  │── M04 ──> AXI DMA        │
│  │ AXI DMA  │─── M_AXI_MM2S ─────>│  Decodes Addresses and routes    │                          │
│  │          │─── M_AXI_S2MM ─────>│  to corresponding Slave          │── M05 ──> SW Reset       │
│  └─────────┬┘                     │                                  │                          │
│            │                      │                                  │── M02 ──> Shared Boot RAM│
│            ▼                      └──────────────────────────────────┘           (PS access)    │
│      (AXI-Stream)                                                                               │
│            │                                                                         ▲          │
│            ▼                                                                         │          │
│  ┌─────────┴────────────────────┐         ┌─────────────────────────┐                │          │
│  │      MLP Accelerator         │         │   64KB True Dual Port   │                │          │
│  │  (Datapath, Control, LUTs)   │         │       Block RAM         │◄── M03 ────────┘          │
│  └──────────────────────────────┘         └─────────────────────────┘    (Pico access)          │
│                                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘
```

## Data Flow

### Address Decoding (SmartConnect)
The SmartConnect tracks exactly which Master connects to which Slave using **Address Decoding**:
- When **PicoRV32** sends an AXI request to `0x4000_0000`, SmartConnect checks its internal Memory Map and routes the request to **M01 (MLP Accelerator)**.
- When **Zynq PS** sends a request to `0xA000_0000`, SmartConnect routes it to **M02 (Boot BRAM)**.
- When **AXI DMA** sends a read request to `0x1000_0000`, SmartConnect routes it to **M00 (Zynq PS HP0 Port -> DDR4)**.

### Inference Flow
1. **Power-On**: PS boots Linux/Baremetal.
2. **Firmware Loading**: PS writes RISC-V firmware into the BRAM via address `0xA000_0000`.
3. **Pico Boot**: PS triggers the SW Reset register to wake up the PicoRV32.
4. **Initialization**: PicoRV32 boots from `0x0000_0000` (which physically maps to the same BRAM).
5. **Setup NN**: PicoRV32 configures MLP registers (layer sizes, enable via `0x4000_0000`).
6. **Data Transfer In**: PicoRV32 programs AXI DMA for MM2S transfer to stream DDR data (weights/inputs) into the MLP.
7. **Compute**: **MLP Accelerator** processes neural network layers.
8. **Data Transfer Out**: PicoRV32 programs DMA for S2MM transfer to write results back to DDR.
9. **Result**: PicoRV32 reads results from DDR, determines classification, and logs completion.

### Memory Map

| Address Range (Pico) | Address Range (Zynq PS) | Size | Component | Description |
|---|---|---|---|---|
| `0x0000_0000` - `0x0000_FFFF` | `0xA000_0000` - `0xA000_FFFF` | 64KB | Shared Boot BRAM | PicoRV32 firmware & Stack |
| `0x1000_0000` - `0x1FFF_FFFF` | `0x1000_0000` - `0x1FFF_FFFF` | 256MB | DDR4 (via PS) | Weights, inputs, results |
| `0x4000_0000` - `0x4000_FFFF` | N/A | 64KB | MLP AXI-Lite | Accelerator control/status |
| `0x4001_0000` - `0x4001_FFFF` | N/A | 64KB | AXI DMA | DMA control/status (regs to 0x58) |
| N/A | `0xA003_0000` - `0xA003_FFFF` | 64KB | SW Reset | Software reset controller (Wakes Pico) |

## Neural Network Architecture

- **Type**: Multi-Layer Perceptron (MLP)
- **Application**: MNIST digit recognition
- **Layers**: 784 → 16 → 16 → 10
- **Activation**: Sigmoid (lookup table, 1024 entries)
- **Arithmetic**: Fixed-point Q1.4.11 (16-bit)
- **Parallelism**: 2 neurons computed simultaneously (dual-port BRAMs)

## Fixed-Point Format

```
Bit:  15  14 13 12 11  10 9 8 7 6 5 4 3 2 1 0
      S   I3 I2 I1 I0  F10 . . . . . . . . . F0

S:    Sign bit (1 = negative)
I3-0: Integer part (4 bits, range: -16 to +15)
F10-0: Fractional part (11 bits, resolution: 1/2048 ≈ 0.000488)
```
