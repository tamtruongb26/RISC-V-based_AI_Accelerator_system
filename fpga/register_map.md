# MLP Accelerator — Register Map

## MLP AXI-Lite Registers (Base: 0x4000_0000)

| Offset | Name | R/W | Bits | Description |
|--------|------|-----|------|-------------|
| 0x00 | slv_reg0 | R/W | [31:0] | Input layer nodes count (e.g., 784) |
| 0x04 | slv_reg1 | R/W | [31:0] | Hidden layer nodes, packed [H4\|H3\|H2\|H1] 8-bit each |
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

## SW Reset IP Registers (Base: 0x4003_0000)

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| 0x00 | SW_RESET | R/W | Software reset control |

## UART Registers (Base: 0x4004_0000) — Extension

Reserved for future UART extension.
