# Phase 1a Design Note — Scratchpad + Accumulator

> Thiết kế chi tiết cho Phase 1a (memory hierarchy foundation).
> Mục tiêu, lý do thông số, kiến trúc, FSM, register map, kế hoạch sim.
> Board: **Avnet Ultra96-v2 (Zynq UltraScale+ ZU3EG)**.
> Tham chiếu: [implementation_plan.md](implementation_plan.md), [limitations_solutions.md](limitations_solutions.md) §2,§3a.

## 1. Mục tiêu & scope

Giải **Vấn đề 2 (memory wall)** + **Vấn đề 3a (SW K-accumulation)** bằng cách thêm 2 khối SRAM on-chip vào accelerator:

- **Scratchpad** — giữ block weight + input on-chip → array đọc từ SRAM gần thay vì DDR xa → biến data reuse 1× → ≥10×.
- **Accumulator** — cộng dồn K bằng phần cứng (in-place add) → bỏ vòng K-accumulation SW của PicoRV32.

**Ngoài scope Phase 1a** (để các phase sau): double-buffer chạy song song (1b), HW im2col (2a), HW pool (2b).
Phase 1a **xây hạ tầng 2-bank**, nhưng việc kích hoạt overlap Load‖Exec là của 1b.

## 2. Tài nguyên board (ràng buộc thiết kế)

ZU3EG (từ [baseline_metrics.md](baseline_metrics.md)):

| Tài nguyên | Có | Baseline dùng |
|---|---|---|
| LUT | 71,280 | 34.5% |
| FF | 141,760 | 24% |
| DSP48 | 360 | 19.7% |
| BRAM 36Kb tile | 216 | 9.0% (~19 tile) |
| **URAM** | **0** | — |

→ **Ràng buộc cứng: không có URAM** → mọi SRAM phải làm bằng BRAM. Phải chừa BRAM cho Phase 5 (ECC nới scratchpad +12.5%, TMR) + 64KB boot BRAM sẵn có.

## 3. Thông số + lý do (defense)

| Thông số | Giá trị | Lý do (neo vào board/workload/array) |
|---|---|---|
| SP width | **128-bit** | **Ép** bởi array 8-wide × 16-bit (Q1.4.11): 1 hàng feed = 8×16 = 128 bit |
| SP size | **16KB** (4 BRAM tile) | Đủ working set + double-buffer; khớp granularity (128-bit×1024 = 4 tile); chỉ ~2% của 216 tile |
| SP banks | **2** (ping-pong) | Tối thiểu để overlap Load‖Exec (Vấn đề 4). 3+ = prefetch sâu, lợi cận biên ít |
| ACC size | **4KB** (2 tile) | Giữ ~12–16 output tile đồng thời → đặt block size M → điểm cân weight-reuse vs BRAM |
| psum width | **40-bit** | Overflow: Q2.8.22 (~32-bit tích) + log₂(K_max=256)=8 bit headroom = 40 |
| ACC mode | overwrite / accumulate | K-tile 0 ghi đè; K-tile sau HW tự cộng (bit `ACC_OVERWRITE`) |

**Nguyên tắc trade:** dừng ở "đầu gối" đường cong lợi-ích-giảm-dần + chừa headroom cho trụ Reliability. Ví dụ block size:

| Block M | Reuse | DDR weight traffic | ACC cần |
|---|---|---|---|
| 1 (current) | 1× | 72 đv | 1 tile |
| **12** | 12× | 6 đv (↓92%) | ~12 tile ✓ |
| 72 (max) | 72× | 1 đv (↓99%) | ~72 tile (23KB ✗) |

→ 12 lấy 92% lợi ích với 1/6 chi phí accumulator. Con số chính xác **xác nhận bằng ablation sweep**, không phán tiên nghiệm.

## 4. Kiến trúc (data flow)

```
DDR (w, b, i)
   │ DMA
   ▼
┌─ SCRATCHPAD (2 bank ping-pong, 16KB) ─┐
│  vùng SP_BASE_W: block Weight          │
│  vùng SP_BASE_A: block Input (A)       │
└────────────┬───────────────────────────┘
             │ array đọc: W (stationary) + A (skew)
             ▼
        8×8 PE array
             │ psum (40-bit × 8 cột)
             ▼
┌─ ACCUMULATOR (4KB, 1 bank + adder) ────┐
│  overwrite (K=0) / accumulate (K>0)    │
└────────────┬───────────────────────────┘
             │ (sau hết K-tile)
             ▼
        post_proc (+ bias + activation)
             │
             ▼
            DDR (output, làm input layer sau)
```

Bias: buffer nhỏ, chỉ cộng ở post_proc cuối (không tham gia phép nhân).

## 5. Loop order + blocking (weight-stationary)

```
for m_block (mỗi ~12 M-tile vừa accumulator):
    for k in 0..K_tiles-1:
        LOAD weight W[k]  ──── 1 lần/block ────  (vào array, đứng yên)
        for m in m_block:                        (12 tile)
            LOAD input A[m][k]   ← mỗi tile
            EXEC (W đứng yên × A skew) → psum
            ACC[m] += psum        (overwrite nếu k==0)
    post_proc + STORE 12 output → DDR
```

- Weight LOAD **thưa** (1 lần/block), input LOAD **dày** (mỗi tile) → đúng weight-stationary.
- Ping-pong áp cho **vùng input**; weight refresh ở biên block/K.

## 6. FSM states mới (control_unit.v)

Thêm vào FSM hiện có:

| State | Việc |
|---|---|
| `LOAD_SP_W` | DMA weight DDR → scratchpad vùng W |
| `LOAD_SP_IN` | DMA input DDR → scratchpad vùng A |
| `EXEC_FROM_SP` | đọc SP → array → psum |
| `WRITE_ACC` | psum → accumulator (overwrite/accumulate theo `ACC_OVERWRITE_EN`) |
| `READ_ACC_TO_DMA` | accumulator → post_proc → DMA ra DDR |

## 7. Register map additions

Hiện tại (5 register, addr 3-bit, 0x00–0x10): CFG / CNT_CLEAR / CNT_SEL / STATUS / CNT_VAL.

Cần thêm cho Phase 1a:

| Offset | Tên | Mô tả |
|---|---|---|
| `0x14` | `SP_BASE_W` | base scratchpad cho weight |
| `0x18` | `SP_BASE_A` | base scratchpad cho input |
| `0x1C` | `ACC_BASE` | base accumulator |
| — | `ACC_OVERWRITE_EN` | **gói vào CFG bit spare** (CFG dùng [14:0], còn [31:15] trống) |

⚠️ **Quyết định cần chốt:** addr_width hiện = 5 (32 byte = 8 slot, 0x00–0x1C). Thêm 3 register (0x14/0x18/0x1C) **vừa khít 8 slot**, không cần nới addr (tránh phá BD wiring — xem [vivado_block_design_changes.md](vivado_block_design_changes.md) §1). `ACC_OVERWRITE_EN` để 1 bit trong CFG để khỏi tràn slot.

## 8. Kế hoạch incremental + sim (board-independent)

Mỗi bước: RTL → testbench → `make sim-<mod>` PASS → tiếp.

```
1. scratchpad.v      + scratchpad_tb      → verify ghi/đọc 2 bank, bank select
2. accumulator.v     + accumulator_tb     → verify overwrite vs accumulate, overflow 40-bit
3. control_unit.v    + states mới         → sim FSM transitions
4. accelerator.v     wire SP/ACC + slave_lite regs
5. accelerator_top_tb mở rộng case dùng SP/ACC → regression toàn hệ
6. firmware          bỏ K-acc SW (gemm_tile.c), set ACC_OVERWRITE_EN
7. git tag v-phase1a
```

Harness sim: thêm target vào [hw/accelerator_2_0/sim/Makefile](../hw/accelerator_2_0/sim/Makefile).

## 9. Success criteria (Phase 1, đo bằng sim + APM)

- FC1 latency ↓ ≥ 30% (giảm DDR reload).
- **Data reuse factor 1× → ≥ 10×** (APM: MAC / DDR bytes read) — con số đắt giá nhất.
- HW/SW breakdown: SW < 30% (từ >50%).
- Accuracy không đổi (≥ 98%).
- Timing close 100MHz (nếu fail: pipeline +1 stage trong SP path, chấp nhận 80MHz).

## 10. Rủi ro

| Rủi ro | Mitigation |
|---|---|
| SP path trượt timing 100MHz | Pipeline +1 stage; chấp nhận f_clk 80MHz |
| BRAM mapping không khớp 256-bit ACC | Tính lại width/tile thật, để synthesis xác nhận |
| Block size sai → ACC tràn | Sweep block size; bắt đầu nhỏ (8 tile) rồi tăng |

## 11. Integration plan (sau khi đọc control_unit.v + accelerator.v)

### 11.1 Kiến trúc hiện tại (tóm tắt từ RTL)

Accelerator là **streaming tile engine**, firmware điều phối:
- FSM: `IDLE → LOAD_W_RECV/PULSE → LOAD_BIAS → LOAD_IN → COMPUTE → POST_PROC → SEND_OUT → DONE`.
- Data vào qua **AXIS slave** (firmware DMA push weight→bias→input mỗi tile), ra qua **AXIS master**.
- Buffer nội bộ: `weight_row_buf`, `bias_buf`, `input_buf[8][8]`, **`psum_buf[8][8]`** (1 tile), `out_buf[8][8]`.
- COMPUTE capture psum vào `psum_buf` (ghi đè), POST_PROC tiêu thụ ngay → SEND.
- Với K>8: **firmware tự K-accumulation bằng SW** (gửi bias=0, cộng dồn trong DDR — [gemm_tile.c](../sw/picorv32/src/gemm_tile.c#L184)).

### 11.2 Chia phạm vi theo rủi ro (QUYẾT ĐỊNH quan trọng)

Scratchpad-reuse đòi accelerator **tự quản data movement** (load 1 lần, reuse nhiều tile) → đụng protocol AXIS + cách firmware điều phối → thực chất gần với **Phase 2c (CISC loop)**. Nên tách:

| Sub-step | Việc | Rủi ro | Fit model hiện tại? |
|---|---|---|---|
| **1a-i** | **Accumulator — HW K-accumulation** | Thấp | ✓ Vừa streaming model |
| **1a-ii** | Scratchpad reuse (load-once, blocking) | Cao | ✗ Cần protocol rework, gộp với 2c |

→ **Khuyến nghị: làm 1a-i trước** (giải dứt điểm Vấn đề 3a, giá trị cao, rủi ro thấp). 1a-ii để sau / gộp 2c.

### 11.3 Thiết kế 1a-i — HW K-accumulation (minimal, surgical)

**Ý tưởng:** biến `psum_buf` từ ghi-đè-mỗi-tile thành **cộng-dồn-qua-K-tile**, và **tách POST_PROC** để chỉ chạy ở K-tile cuối.

**2 bit điều khiển mới — nhét vào CFG spare bit (KHÔNG cần register mới, KHÔNG nới AXI addr):**

CFG hiện dùng `[14:0]` (M/K/N/ACT/START), còn trống `[31:15]`:

| Bit | Tên | Ý nghĩa |
|---|---|---|
| `CFG[15]` | `ACC_OVERWRITE` | 1 = K-tile 0 (ghi đè psum_buf); 0 = K-tile>0 (cộng dồn) |
| `CFG[16]` | `POST_EN` | 1 = K-tile cuối (chạy POST_PROC + SEND); 0 = chỉ cộng dồn, bỏ qua output |

**Sửa RTL (surgical, 3 chỗ):**

1. `slave_lite`: thêm 2 output `po_acc_overwrite = slv_reg0[15]`, `po_post_en = slv_reg0[16]`.
2. `accelerator.v`: wire 2 tín hiệu mới slave_lite → control_unit.
3. `control_unit.v`:
   - Thêm 2 input `pi_acc_overwrite`, `pi_post_en`.
   - COMPUTE capture ([L301](../hw/accelerator_2_0/hdl/control_unit.v#L301)):
     ```
     if (pi_acc_overwrite) psum_buf[m][n] <= psum_bottom;
     else                  psum_buf[m][n] <= psum_buf[m][n] + psum_bottom;
     ```
   - COMPUTE→next transition ([L308](../hw/accelerator_2_0/hdl/control_unit.v#L308)):
     ```
     if (pi_post_en) state <= ST_POST_PROC;   // K cuối: post_proc + send
     else            state <= ST_DONE;          // K giữa: chỉ cộng dồn
     ```

→ Không reset `psum_buf` giữa tile → nó tự persist qua các K-tile.

**Firmware tương ứng (gemm_tile.c):** bỏ vòng SW accumulation (step 10), thay bằng:
```
for k in K-tiles:
    acc_overwrite = (k==0); post_en = (k==last)
    push weight[k]+bias+input[k]; start(CFG | acc_overwrite<<15 | post_en<<16)
    wait done
    if post_en: receive output    // chỉ nhận output 1 lần ở K cuối
```

**Verify (sim, không cần board):** mở rộng `accelerator_top_tb`:
- Case mới: 2 K-tile, K0 (overwrite, post_en=0) + K1 (accumulate, post_en=1) → output = post_proc(psum_K0 + psum_K1). So với golden.

### 11.4 Vai trò module đã build

- `accumulator.v` (1024 cell): primitive cho **1a-ii** (giữ nhiều output tile khi blocking). 1a-i dùng `psum_buf` sẵn có (1 tile, đủ cho K-acc single-tile) → không cần instantiate accumulator.v ngay.
- `scratchpad.v`: primitive cho **1a-ii**.
→ 2 module đã verified, sẵn sàng cho 1a-ii; 1a-i không phụ thuộc chúng.

### 11.5 Khác biệt với §7 ở trên

§7 đề xuất register offset mới (`SP_BASE_W/A`, `ACC_BASE`) — đó là cho **1a-ii** (scratchpad addressing). **1a-i chỉ cần 2 CFG spare bit**, gọn hơn, không đụng register map / BD. → cập nhật: ưu tiên CFG bit cho 1a-i.

## Cross-references
- [implementation_plan.md](implementation_plan.md) Phase 1a
- [limitations_solutions.md](limitations_solutions.md) §2, §3a, §4
- [baseline_metrics.md](baseline_metrics.md) tài nguyên ZU3EG
