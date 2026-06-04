# Tổng kết Đổi mới & Công việc còn lại — RAAS

> Cập nhật: **2026-06-04**. Trạng thái: Phase 0 + Phase 1a hoàn tất (sim-verified).
> Tag git: `v-baseline` (Phase 0), `v-phase1a` (Phase 1a).
> Tham chiếu: [implementation_plan.md](implementation_plan.md), [phase1a_design.md](phase1a_design.md).

Doc này gồm 3 phần:
1. **Đổi mới đã làm** — chi tiết từng hạng mục đã triển khai + verify.
2. **Khác biệt so với kế hoạch ban đầu** — chỗ thực thi đi chệch (cải tiến) so với plan gốc, kèm lý do.
3. **Công việc còn lại** — phần chưa làm trong Phase 1a + roadmap Phase 1b→7.

---

## PHẦN 1 — ĐỔI MỚI ĐÃ LÀM

### 1.0 Hạ tầng verify độc lập-board (methodology)

User không có board → dựng flow **incremental + simulation**:
- `hw/accelerator_2_0/sim/Makefile` — chạy `make sim-all` bằng xsim CLI batch (board-independent).
- Mỗi module: RTL → testbench → sim PASS → git tag.
- **Self-checking tests** (không cần golden hex): kiểm bằng tính chất bất biến (vd `P+P == 2P`, `reuse == fresh`, `blocking == simple`).

→ Cho phép verify đúng/sai chức năng + cycle-accurate **offline 80%** công việc; board chỉ để đo số cuối.

### 1.1 Phase 0 — Instrumentation + Register pack (tag v-baseline)

| Hạng mục | Nội dung | Verify |
|---|---|---|
| 10 counter HDL | Per-state cycle counter (IDLE/LOAD_W/.../SEND/DONE/TOTAL) + PE_active trong `control_unit.v`/`data_path.v`, đọc gián tiếp qua CNT_SEL/CNT_VAL | sim 4 tb |
| Register pack (6a) | Gộp 5 register cũ → 1 `CFG_PACKED` (M/K/N/ACT/START) → 1 AXI write thay 5 | — |
| Bitstream | Re-package IP + AXI Timer + APM vào block design; WNS +3.714ns @100MHz | Vivado |
| Firmware | `accel_*` API mới, per-layer `lstamp`, counter snapshot | build pass |

### 1.2 Phase 1a-i — HW K-accumulation (tag v-phase1a)

**Mục tiêu:** giải Vấn đề 3a (Pico tự cộng dồn K bằng SW → accelerator idle).

**Cơ chế:** `psum_buf` chuyển từ ghi-đè-mỗi-tile → **cộng-dồn qua K-tile trong HW**; `POST_PROC` (bias + activation) chỉ chạy ở K-tile cuối.

**Điều khiển — 2 CFG spare bit** (không thêm register):
- `CFG[15] ACC_ACCUM`: 1 = cộng dồn, 0 = ghi đè (K-tile 0).
- `CFG[16] POST_SKIP`: 1 = bỏ POST_PROC+SEND (K-tile giữa), 0 = làm (K-tile cuối).

**File:** `accelerator_slave_lite_*.v` (2 output), `control_unit.v` (capture cộng dồn + transition), `accelerator.v` (wire), firmware `gemm_tile.c` (bỏ vòng SW accumulation), `accel.c` (`accel_configure_and_start_flags`).

**Đổi mới định lượng:** psum cộng dồn ở **40-bit full precision**, scale (>>11) + saturate **1 lần** ở cuối → **chính xác hơn** path SW cũ (vốn scale+saturate **mỗi tile** rồi cộng → mất precision).

**Verify:** `accelerator_top_tb` Case 5 — `K0+K1 (P+P) == single 2P`.

### 1.3 Phase 1a-ii — Data reuse (scratchpad-style, tag v-phase1a)

Giải Vấn đề 2 (memory wall) phía data reuse. 4 sub-step:

**A — Weight reuse (`SKIP_W_LOAD`, CFG[17]):**
- Weight đã nằm stationary trong `w_reg` của PE array → **bỏ reload** = có reuse, không cần DMA/scratchpad mới.
- `control_unit` ST_IDLE: skip_w_load → bỏ thẳng sang LOAD_BIAS, giữ weight cũ.
- Verify Case 6: `reuse-W == fresh-load`.

**B — Multi-slot accumulator (`ACC_SLOT`, CFG[19:18]):**
- `psum_buf[1 tile]` → `psum_buf[NUM_SLOTS=4][8][8]` (register) → giữ nhiều output tile cho blocking.
- Verify Case 7: 2 slot độc lập + holding + post đúng slot.

**C — Blocking loop (HW proof + firmware):**
- Firmware `gemm_tiled` restructure: `n-tile → block(4 M-tile) → K-tile → slot`. Mỗi k0 nạp weight 1 lần (slot 0), slot sau reuse (SKIP_W_LOAD) → cắt DDR weight **~4×** cho Conv.
- K-acc cộng dồn vào slot riêng; output ở K-tile cuối.
- FC (M=1) → nslots=1 → tự degenerate (đúng — FC không reuse weight được).
- Verify Case 8: `blocking (W-reuse + K-acc + slots) == simple K-acc`.

**D — Input reuse (`SKIP_IN_LOAD`, CFG[20]):**
- Giữ input trong `input_buf`, bỏ LOAD_IN → reuse input qua N-tile (cho FC).
- `control_unit` ST_LOAD_BIAS: skip_in_load → vào thẳng COMPUTE.
- Verify Case 9: `reuse-input == fresh-load`. (Mechanism; firmware FC để tối ưu sau.)

**Bản đồ CFG spare bit (as-built):**
```
[14]    START        [15] ACC_ACCUM    [16] POST_SKIP
[17]    SKIP_W_LOAD   [19:18] ACC_SLOT  [20] SKIP_IN_LOAD
```
→ Toàn bộ control Phase 1a nằm trong 1 register CFG sẵn có. **Không thêm register, không nới AXI addr, không đụng block design / AXI shim.**

---

## PHẦN 2 — KHÁC BIỆT SO VỚI KẾ HOẠCH BAN ĐẦU

Đây là các điểm thực thi **đi chệch khỏi plan gốc** — phần lớn là **cải tiến** phát hiện trong lúc làm.

### 2.1 K-accumulation: CFG spare bit thay vì register mới

- **Plan gốc (§7):** thêm register `SP_BASE_W/A`, `ACC_BASE`, `ACC_OVERWRITE_EN` → cần nới register map.
- **Thực tế:** 2 CFG spare bit (`ACC_ACCUM`/`POST_SKIP`), dùng `psum_buf` sẵn có cho K-acc single-tile (không cần instantiate `accumulator.v`).
- **Lợi:** surgical, không đụng AXI addr width / block design / AXI shim (tránh phá BD wiring — rủi ro lớn nhất khi sửa register).

### 2.2 Tách Phase 1a thành 1a-i (K-acc) và 1a-ii (reuse) theo rủi ro

- **Plan gốc:** Phase 1a = "scratchpad + accumulator" như 1 khối.
- **Thực tế:** tách vì đọc kiến trúc thấy accelerator là **streaming engine** (firmware đẩy data qua AXIS mỗi tile). Scratchpad-reuse cần accelerator tự quản data movement → thực chất chồng lấn **Phase 2c (CISC loop)**.
- **Lợi:** làm 1a-i (rủi ro thấp, giá trị cao) dứt điểm trước; 1a-ii làm tăng dần.

### 2.3 Weight reuse = "không reload w_reg" thay vì scratchpad SRAM cho weight

- **Plan gốc:** `scratchpad.v` (BRAM) giữ weight on-chip.
- **Insight thực tế:** weight **đã** stationary trong `w_reg` của 64 PE. Reuse = chỉ **bỏ lệnh reload** (`SKIP_W_LOAD`) — không cần DMA mới, không cần BRAM scratchpad cho weight.
- **Lợi:** đơn giản hơn nhiều; `scratchpad.v` (đã build + verified) chuyển vai trò sang reuse input/feature-map (1a-ii tương lai).

### 2.4 Multi-slot accumulator bằng register thay vì BRAM 8-bank

- **Plan gốc:** accumulator = BRAM 4KB (256-bit × 128).
- **Trở ngại phát hiện:** COMPUTE capture là **scatter chéo** (8 ô (m,n) khác nhau ghi song song/cycle). BRAM 1-port không ghi 8 ô/cycle → cần 8 bank cột + **re-time POST_PROC** (memory có latency) = rủi ro cao nhất.
- **Thực tế:** `psum_buf[NUM_SLOTS][8][8]` **register** → giữ combinational read, capture + post_proc **không đổi timing**.
- **Tradeoff (ghi rõ để defend):** dùng FF (~+7.7k) thay BRAM; block size = NUM_SLOTS=4 (reuse 4×, cắt 75% DDR weight — vẫn trên "đầu gối" đường cong lợi-ích-giảm-dần).

### 2.5 Cải tiến precision (ngoài plan)

K-accumulation HW cộng dồn **40-bit full precision** rồi scale 1 lần — chính xác hơn baseline SW (scale+saturate mỗi tile). Đây là **cải thiện accuracy "miễn phí"**, không có trong plan gốc.

### 2.6 Phát hiện thực nghiệm: residual psum tự rửa

- Lo ngại: bỏ reload weight để lại residual `psum_reg` trong PE → sai.
- **Sim chứng minh ngược lại:** systolic wavefront tự ghi đè chain trước khi capture (cmp_t≥8) → không sai.
- **Lợi:** tránh thêm `pi_pipe_clear` vào `pe.v` (giữ PE nguyên, surgical hơn). Đây là giá trị của verify-bằng-sim thay vì giả định.

### 2.7 Methodology: self-checking sim (ngoài plan)

Plan không nói cách verify chi tiết. Thực tế dùng **tính chất bất biến** để kiểm mà không cần golden: `P+P==2P` (K-acc), `reuse==fresh` (reuse), `blocking==simple` (blocking). → verify mạnh, không phụ thuộc tooling sinh golden.

---

## PHẦN 3 — CÔNG VIỆC CÒN LẠI

### 3.1 Còn lại trong Phase 1a (chưa đóng hoàn toàn)

| Việc | Vì sao chưa | Cần gì |
|---|---|---|
| Đo số thật: latency, **data reuse factor** (APM), accuracy | runtime | **board** |
| Synthesis Phase 1a: area (FF cost NUM_SLOTS), timing 100MHz, power | chưa chạy | Vivado synth |
| 1a-ii-D firmware (khai thác SKIP_IN_LOAD cho FC) | cần loop order n0-inner, payoff vừa | firmware |
| Sync `raas_map.h` sang 3 bản Vitis (nếu muốn nhất quán) | PS không dùng bit K-acc/reuse | tùy chọn |

> ⚠️ **Quan trọng:** mọi con số hiệu năng (×reuse, ↓latency) hiện là **mục tiêu thiết kế**, **chưa đo**. Chức năng đã verify (sim), định lượng cần board + synthesis.

### 3.2 Roadmap Phase còn lại (1b → 7)

| Phase | Nội dung | Trạng thái |
|---|---|---|
| **1b** | Double-buffering — pipeline Load‖Exec, ping-pong 2-bank scratchpad | Chưa bắt đầu |
| **2a** | HW im2col (`im2col.v`) — bỏ im2col SW (Vấn đề 3b) | Chưa |
| **2b** | HW pool (stage trong `post_proc.v`) — bỏ maxpool SW (3c) | Chưa |
| **2c** | CISC loop descriptor — accelerator tự DMA, firmware fire-and-forget (6b) | Chưa |
| **3a** | OS dataflow mode cho FC — kéo PE util FC 12.5%→≥80% (Vấn đề 1) | Chưa |
| **4** | Sparsity zero-skip — operand isolation (Vấn đề 5) | Chưa |
| **5a** | Fault injection framework (`fault_injector.v`) — trụ Reliability | Chưa |
| **5b** | TMR control FSM (`tmr_voter.v`) | Chưa |
| **5c** | ECC SECDED scratchpad (`ecc_*.v`) | Chưa |
| **6** | Generic firmware + model descriptor (Vấn đề 8b) | Chưa |
| **7** | Ablation + comparison + luận văn | Chưa |

### 3.3 Việc xuyên suốt (cross-cutting)

- **3d Interrupt-driven** (Phase 0 còn nợ): wire DONE → IRQ Pico, bỏ polling.
- **8a Operator library**: tách `ops.c`/`ops.h`.
- **Tooling**: `tools/post_process.py` (parse mailbox → bảng/plot), `scripts/report_all.tcl`.
- **Đo Phase 1a trên board** khi có → điền cột "after" đầu tiên của ablation.

### 3.4 Thứ tự đề xuất tiếp theo

1. (Có board?) Đo `v-baseline` + `v-phase1a` → 2 dòng ablation đầu.
2. (Không board) Phase 1b (double-buffer) hoặc Phase 2a (HW im2col) — tiếp trụ Memory hierarchy, vẫn verify offline bằng sim.
3. Chạy synthesis Phase 1a để confirm fit ZU3EG + timing + FF cost của NUM_SLOTS.

---

## Cross-references
- Thiết kế chi tiết + justification thông số: [phase1a_design.md](phase1a_design.md)
- Plan gốc: [implementation_plan.md](implementation_plan.md)
- 8 vấn đề → giải pháp: [limitations_solutions.md](limitations_solutions.md)
- Methodology đo: [evaluation_metrics.md](evaluation_metrics.md)
- Template số liệu baseline: [baseline_metrics.md](baseline_metrics.md)
