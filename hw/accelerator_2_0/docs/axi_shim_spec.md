# AXI Shim — Design Spec

3 file shim adapter giữa AXI infrastructure (PicoRV32, AXI DMA, SmartConnect) và `control_unit`.

---

## 1. Tổng quan port của control_unit

control_unit (đã verify) expose các interface sau:

| Group | Direction | Signals |
|---|---|---|
| AXI-Lite config (5 reg) | `input` | `pi_tile_m_size [9:0]`, `pi_tile_k_size [9:0]`, `pi_tile_n_size [9:0]`, `pi_act_mode [1:0]`, `pi_start` |
| AXI-Lite status | `output` | `po_busy`, `po_done` |
| AXIS slave (data in) | `input` | `pi_stream_data [31:0]`, `pi_stream_valid` |
| AXIS slave (handshake) | `output` | `po_stream_ready`, `po_loading` |
| AXIS master (data out) | `output` | `po_num_out_transfers [9:0]`, `po_out_data [31:0]`, `po_out_write_req` |
| AXIS master (handshake) | `input` | `pi_out_write_done` |

Mỗi shim làm bridge giữa 1 trong 3 nhóm AXI và FSM control_unit.

---

## 2. Shim #1: `accelerator_slave_lite_v2_0_S00_AXI.v`

### 2.1 Mục đích
Register file 5 thanh ghi 32-bit, AXI4-Lite slave interface.

### 2.2 Address map

| Offset | Tên | R/W | Bit field | Mô tả |
|---|---|---|---|---|
| `0x00` | `TILE_M_SIZE` | R/W | `[9:0]` valid, rest reserved | M dimension (1..8) |
| `0x04` | `TILE_K_SIZE` | R/W | `[9:0]` | K dimension |
| `0x08` | `TILE_N_SIZE` | R/W | `[9:0]` | N dimension |
| `0x0C` | `CONTROL` | R/W | `[0]=START`, `[2:1]=ACT_MODE` | Start one-shot + activation mode |
| `0x10` | `STATUS` | R | `[0]=BUSY`, `[1]=DONE` | HW-written status |
| `0x14`+ | reserved | — | — | đọc trả 0 |

**Address bus width**: 5 bit để cover `0x00..0x14` (≥ 5 word). AXI spec yêu cầu rõ `C_S_AXI_ADDR_WIDTH ≥ 5` (= log2(5 word × 4 byte) làm tròn lên).

### 2.3 START bit — one-shot pulse
- Firmware ghi `CONTROL[0] = 1` để trigger.
- Hardware tự clear sau 1 cycle: `START_pulse → po_start → control_unit IDLE→LOAD_W_RECV`.
- Lý do: tránh re-trigger khi FSM về IDLE giữa 2 tile.

```verilog
// Implementation hint:
assign po_start = slv_reg_control[0] & ~start_clear_seen;
// hoặc dùng register pulse logic.
```

### 2.4 STATUS — read-only, HW-written
- `STATUS[0] = po_busy` (control_unit signal)
- `STATUS[1] = po_done` (set khi DONE state, clear khi IDLE next)
- Slave shim KHÔNG cho phép firmware ghi STATUS (write-protected).

### 2.5 Reset behavior
- Tất cả 4 register R/W reset về 0.
- Firmware phải set TILE_*_SIZE trước khi START.

---

## 3. Shim #2: `accelerator_slave_stream_v2_0_S00_AXIS.v`

### 3.1 Mục đích
AXI4-Stream slave để nhận data từ DMA (weight, bias, input) đẩy vào FSM.

### 3.2 Port

| Phía AXI (DMA) | Phía control_unit |
|---|---|
| `S_AXIS_TDATA [31:0]` | → `pi_stream_data` |
| `S_AXIS_TVALID` | → `pi_stream_valid` (gated, xem 3.3) |
| `S_AXIS_TREADY` ← | `po_stream_ready` (gated) |
| `S_AXIS_TLAST` | (ignored — control_unit dùng counter từ TILE_*_SIZE) |

### 3.3 TREADY gating logic ⚠️

Trực tiếp nối `po_stream_ready → S_AXIS_TREADY` **KHÔNG đủ**. Bug có thể xảy ra: stray TVALID giữa 2 tile, control_unit về IDLE nhưng DMA vẫn pulse TVALID → data ghi nhầm vào trạng thái không expect.

**Gate đúng**:
```verilog
assign S_AXIS_TREADY = po_loading;  // chỉ accept khi đang ở LOAD_W_RECV / LOAD_BIAS / LOAD_IN
assign pi_stream_valid_gated = S_AXIS_TVALID & po_loading;
```

→ TVALID + TREADY chỉ handshake khi FSM đang load. Ngoài ra deassert TREADY → DMA stall, không mất data.

### 3.4 Lưu ý implementation
- KHÔNG buffer data trong shim (control_unit có buffer rồi).
- Pure passthrough + gating.
- Reset: TREADY=0 cho đến khi `po_loading=1`.

---

## 4. Shim #3: `accelerator_master_stream_v2_0_M00_AXIS.v`

### 4.1 Mục đích
AXI4-Stream master đẩy output (M × ⌈N/2⌉ word, 2 element/word) ra DMA.

### 4.2 Port

| Phía AXI (DMA) | Phía control_unit |
|---|---|
| `M_AXIS_TDATA [31:0]` ← | `po_out_data` |
| `M_AXIS_TVALID` ← | `po_out_write_req` |
| `M_AXIS_TREADY` | → derived `pi_out_write_done` |
| `M_AXIS_TLAST` ← | derived (xem 4.3) |

### 4.3 TLAST generation
- DMA cần TLAST để biết transfer cuối cùng → đóng descriptor.
- TLAST=1 khi gửi word cuối cùng = lần thứ `(M × ⌈N/2⌉) - 1`.
- Shim đếm word đã gửi (handshake `TVALID & TREADY`) so với `po_num_out_transfers`.

```verilog
reg [9:0] tx_count;
always @(posedge ACLK) begin
    if (!ARESETN)              tx_count <= 0;
    else if (handshake)        tx_count <= tx_count + 1;
    else if (tx_count == po_num_out_transfers) tx_count <= 0; // reset for next tile
end
assign M_AXIS_TLAST = (tx_count == po_num_out_transfers - 1) & M_AXIS_TVALID;
```

### 4.4 `pi_out_write_done` semantic
- Pulse khi 1 word handshake xong (TVALID & TREADY = 1).
- control_unit dùng để advance `send_row/send_pair` counter.
- KHÔNG nhầm với "tile transfer hoàn tất" (TLAST).

```verilog
assign pi_out_write_done = M_AXIS_TVALID & M_AXIS_TREADY;
```

### 4.5 Reset behavior
- TVALID=0 trong reset.
- tx_count=0 trong reset.

---

## 5. Tham số AXI chuẩn

Dùng các parameter Vivado template để đảm bảo tương thích SmartConnect/DMA:

| Parameter | Value | Module |
|---|---|---|
| `C_S_AXI_DATA_WIDTH` | 32 | AXI-Lite |
| `C_S_AXI_ADDR_WIDTH` | 5 | AXI-Lite (đủ cho 5 reg) |
| `C_S_AXIS_TDATA_WIDTH` | 32 | AXIS slave |
| `C_M_AXIS_TDATA_WIDTH` | 32 | AXIS master |

---

## 6. Synthesis target

Shim là Vivado boilerplate, không có DSP/BRAM. Mỗi shim ~50-100 LUT, ~50-100 FF.

Tổng 3 shim ước tính: ~300 LUT, ~250 FF, 0 DSP, 0 BRAM.

---

## 7. File deliverables Bước 9

| File | Lines (ước tính) |
|---|---|
| `hw/accelerator_2_0/hdl/accelerator_slave_lite_v2_0_S00_AXI.v` | ~280 |
| `hw/accelerator_2_0/hdl/accelerator_slave_stream_v2_0_S00_AXIS.v` | ~80 |
| `hw/accelerator_2_0/hdl/accelerator_master_stream_v2_0_M00_AXIS.v` | ~120 |
| `hw/accelerator_2_0/hdl/axi_shim_spec.md` | tài liệu này |

(TB cho 3 shim sẽ gộp vào Bước 11 — `accelerator_top_tb.sv` test toàn bộ end-to-end qua AXI BFM.)

---

## 8. Implementation strategy

- **AXI-Lite**: rút gọn từ template Vivado `axi_lite_slave_v1_0_S00_AXI.v`. Chỉ cần 5 register thay vì 4 mặc định + thêm hookup STATUS read-only + START auto-clear.
- **AXIS slave**: rút từ template `axi_stream_slave_v1_0_S00_AXIS.v`, **bỏ FIFO buffer** (control_unit có buffer), thêm gate TREADY.
- **AXIS master**: rút từ template `axi_stream_master_v1_0_M00_AXIS.v`, thêm TLAST counter.

Tham khảo file old: `hw/accelerator_2_0_old_backup/hdl/accelerator_*_S00_AXI*.v` (đã có pattern + naming, chỉ cần check lỗi `po_loading` gating đã thêm chưa).
