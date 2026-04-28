# MLP Accelerator — Register Map

## MLP AXI-Lite Registers (Base: 0x4000_0000)

| Offset | Name | R/W | Bits | Description |
|--------|------|-----|------|-------------|
| 0x00 | slv_reg0 | R/W | [31:0] | Input layer nodes count (e.g., 784) |
| 0x04 | slv_reg1 | R/W | [31:0] | Hidden layer nodes, packed `[H2\|H1]` as two 16-bit fields. Current demo value: `0x0010_0010` |
| 0x08 | slv_reg2 | R/W | [31:0] | Output layer nodes count (e.g., 10) |
| 0x0C | slv_reg3 | R/W | [1:0] | Control: bit[0]=NN_EN, bit[1]=DATA_RDY |
| 0x10 | slv_reg4 | R | [0] | Status: bit[0]=BSY (1 = computation in progress) |

## AXI DMA Registers (Base: 0x4001_0000)

### MM2S Channel (Memory-Mapped to Stream)

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| 0x00 | MM2S_DMACR | R/W | Control: bit[0]=RS, bit[2]=Reset, bit[12]=IOC_IRQ_EN |
| 0x04 | MM2S_DMASR | R/W1C | Status: bit[0]=Halted, bit[1]=Idle, bit[12]=IOC_IRQ |
| 0x18 | MM2S_SA | R/W | Source address (lower 32-bit) |
| 0x1C | MM2S_SA_MSB | R/W | Source address (upper 32-bit) |
| 0x28 | MM2S_LENGTH | R/W | Transfer length in bytes (writing starts transfer) |

### S2MM Channel (Stream to Memory-Mapped)

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| 0x30 | S2MM_DMACR | R/W | Control: bit[0]=RS, bit[2]=Reset, bit[12]=IOC_IRQ_EN |
| 0x34 | S2MM_DMASR | R/W1C | Status: bit[0]=Halted, bit[1]=Idle, bit[12]=IOC_IRQ |
| 0x48 | S2MM_DA | R/W | Destination address (lower 32-bit) |
| 0x4C | S2MM_DA_MSB | R/W | Destination address (upper 32-bit) |
| 0x58 | S2MM_LENGTH | R/W | Transfer length in bytes (writing starts transfer) |

> **Note**: Highest used register offset is 0x58. Block assigned 64KB (0x4001_0000–0x4001_FFFF).

## SW Reset IP Registers (PS-visible Base: 0xA003_0000)

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| 0x00 | SW_RESET | R/W | Software reset control |

The reset output is active-low for PicoRV32: write `0` to hold Pico in reset,
write `1` to release it. This IP is controlled by the Zynq PS; it is excluded
from the PicoRV32 address map.

## PicoRV32 Boot BRAM

| Master | Base | Size | Description |
|--------|------|------|-------------|
| PicoRV32 | 0x0000_0000 | 64 KB | Reset vector and firmware execution memory |
| Zynq PS | 0xA000_0000 | 64 KB | Loader view used to copy the Pico firmware before reset release |

## DDR Demo Layout

| Address | Contents |
|---------|----------|
| 0x1000_0000 | Packed MNIST image input, two Q1.4.11 pixels per 32-bit word |
| 0x1000_1000 | Packed biases, one `[neuronB\|neuronA]` word per neuron pair |
| 0x1000_2000 | Packed weights as `[neuronB_i\|neuronA_i]` for each input `i` |
| 0x1010_0000 | Hidden layer 1 output words |
| 0x1010_0100 | Hidden layer 2 output words |
| 0x1010_0200 | Final output words |
| 0x1010_1000 | Pico-to-PS mailbox: magic, state, error, predicted digit, expected label, image index, final score words |

## UART Registers (Base: 0x4004_0000) — Extension

Reserved for future UART extension.
