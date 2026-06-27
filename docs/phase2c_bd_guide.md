# Phase 2c — Hướng dẫn Vivado (re-package IP + BD wiring autonomy)

> HDL đã xong (auto_seq.v, dma_ctrl.v, accelerator.v, slave_lite). Tài liệu này
> là **phần bạn làm trên Vivado**: re-package IP accelerator (lộ register mới +
> AXI-Lite master `m_axi_dma`) rồi nối nó tới DMA `S_AXI_LITE` trong block design.

## Tổng quan thay đổi HW
- `slave_lite`: +reg7 (0x1C = `out_base`), CFG[24] = `auto_go`. Descriptor reuse
  reg5 (`im2col_cfg0` = {n,m,k tiles}) + reg6 (`im2col_cfg1` = `in_base`).
- `accelerator`: +AXI-Lite **master** `m_axi_dma_*` → tự lập trình DMA.
- Manual mode (Pico) **giữ nguyên** — autonomy chỉ bật khi Pico ghi CFG[24]=1.

---

## Bước 1 — Re-package IP accelerator

1. **Tools → Create and Package New IP → Package existing project** *(hoặc mở
   IP đã có: `hw/accelerator_2_0` trong IP Packager)*. Nếu đang dùng IP repo
   local: mở `hw/accelerator_2_0/component.xml` bằng **Window → IP Catalog →
   right-click accelerator → Edit in IP Packager**.
2. Trong IP Packager:
   - **File Groups → Merge changes from … Wizard** (nạp HDL mới `accelerator.v`,
     `auto_seq.v`, `dma_ctrl.v`, `slave_lite.v`).
   - **Ports and Interfaces**: Vivado tự nhận `m_axi_dma_*` (đặt tên chuẩn AXI).
     Nếu **chưa** auto-infer thành interface AXI4-Lite:
     - Right-click vùng trống → **Add Bus Interface** → chọn `aximm` (AXI4-Lite),
       mode = **Master**, đặt tên **M_AXI_DMA**.
     - Map signals: AWADDR→`m_axi_dma_awaddr`, AWVALID→`m_axi_dma_awvalid`,
       AWREADY, AWPROT, WDATA, WSTRB, WVALID, WREADY, BRESP, BVALID, BREADY,
       ARADDR, ARPROT, ARVALID, ARREADY, RDATA, RRESP, RVALID, RREADY.
     - **Associate clock**: gán M_AXI_DMA với clock `s00_axi_aclk` và reset
       `s00_axi_aresetn` (Clock and Reset Association).
   - **Addressing**: M_AXI_DMA cần 1 address space (Master). Đặt range ≥ 4K.
3. **Review and Package → Re-Package IP**. Tăng version (vd 1.0 → 1.1) hoặc giữ
   version + bump revision — miễn BD nhận "IP upgrade available".

## Bước 2 — Cập nhật IP trong block design

1. Mở BD (`fpga/RAS.srcs/sources_1/bd/RAS/RAS.bd`).
2. **Reports → IP Status → Upgrade Selected** (nâng accelerator lên bản mới).
   Block `RAS_accelerator_0` giờ có thêm cổng **M_AXI_DMA**.

## Bước 3 — Nối M_AXI_DMA tới DMA S_AXI_LITE (2 master → 1 slave)

DMA `S_AXI_LITE` giờ có 2 master: **PicoRV32** (như cũ) + **accelerator M_AXI_DMA**.

**Cách A — AXI SmartConnect riêng (khuyến nghị, rõ ràng):**
1. Add IP → **AXI SmartConnect**. Cấu hình: **2 Slave Interfaces (SI), 1 Master
   Interface (MI)**, 1 clock.
2. Tháo dây hiện tại đang vào `axi_dma_0/S_AXI_LITE`.
3. Nối:
   - `SmartConnect/M00_AXI` → `axi_dma_0/S_AXI_LITE`.
   - `SmartConnect/S00_AXI` ← master cũ của Pico (cái trước đây nối thẳng DMA).
   - `SmartConnect/S01_AXI` ← `RAS_accelerator_0/M_AXI_DMA`.
   - `aclk`/`aresetn` của SmartConnect → cùng clock/reset 100MHz domain.

**Cách B — thêm SI vào AXI Interconnect sẵn có** (nếu Pico→DMA đang qua một
`axi_interconnect`): tăng **Number of Slave Interfaces** +1, nối M_AXI_DMA vào
SI mới. Đơn giản hơn nếu interconnect đã tồn tại.

## Bước 4 — Address Editor

1. Mở **Address Editor**.
2. Master mới **RAS_accelerator_0/M_AXI_DMA** → gán segment cho
   `axi_dma_0/S_AXI_LITE` tại **base = 0x4001_0000**, range ≥ 4K.
   *(Khớp `DMA_BASE` mặc định trong `dma_ctrl.v` — nếu BD bắt buộc base khác,
   sửa parameter `DMA_BASE` của IP cho khớp.)*
3. Pico → DMA giữ nguyên 0x4001_0000 (không đổi).

> **Vì sao base phải khớp**: `dma_ctrl` drive địa chỉ = `DMA_BASE | offset`
> (offset 0x00–0x58 = thanh ghi DMA). SmartConnect định tuyến theo địa chỉ này.

## Bước 5 — Validate + synth + XSA

```tcl
validate_bd_design
save_bd_design
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
write_hw_platform -fixed -include_bit -force /home/tam/Documents/RAAS/fpga/RAS_wrapper.xsa
```

## Kiểm tra nhanh sau synth
- IP Status: accelerator ở bản mới, M_AXI_DMA connected.
- Address Editor: M_AXI_DMA → DMA tại 0x4001_0000, không overlap.
- Timing: WNS ≥ 0 @100MHz (auto_seq + dma_ctrl nhẹ, không nên phá timing).
- DRC: 0 critical.

---

## Sau BD: firmware (Stage 3 — tôi lo)
Pico thay vòng lặp tile bằng: ghi descriptor (reg5/6/7 + act) → set CFG[24]=1 →
poll STATUS.DONE. PS sắp weight thành block tile-major liền mạch 272B/tile.
Xem `gemm_auto()` trong firmware (Stage 3).
