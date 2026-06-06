# Autonomous Accelerator — Design Note (integration im2col + scratchpad + double-buffer + CISC)

> Đợt tích hợp lớn nhất: biến accelerator từ "streaming tile engine" (firmware
> điều phối từng tile) → "autonomous layer engine" (DDR → accel → DDR, Pico chỉ
> ra descriptor). Gộp các module đã verified: `im2col.v`, `scratchpad.v`,
> `accumulator.v` + các skip-bit Phase 1a-ii.
> Board: ZU3EG. Tham chiếu: [phase1a_design.md](phase1a_design.md) §11-12.

## 1. Vì sao gộp 4 thứ này

im2col, scratchpad-reuse, double-buffer, CISC loop **chỉ phát huy khi tích hợp cùng nhau**:
- im2col-HW một mình (giữ firmware đẩy AXIS) → vẫn round-trip DDR cho A.
- scratchpad-reuse cần loop order do accelerator kiểm soát.
- double-buffer cần 2-lane load/exec trong accelerator.
- → Tách rời sẽ chắp vá. Nhưng **không phải làm hết 1 lần** — xem §6 phân tầng.

## 2. Phân tầng theo rủi ro (QUYẾT ĐỊNH cốt lõi)

"Autonomous" gồm **2 tầng** rất khác nhau:

| Tầng | Nội dung | BD change? | Sim verify? | Rủi ro |
|---|---|---|---|---|
| **T1 — Internal integration** | im2col + scratchpad reuse + double-buffer **bên trong** accelerator. Firmware vẫn trigger DMA mỗi layer. | **KHÔNG** | **Có** | Trung |
| **T2 — Autonomy (CISC + self-DMA)** | Accelerator tự lập trình DMA + outer-loop FSM. Pico fire-and-forget. | **CÓ** (thêm AXI master) | Khó | **Cao** |

→ **T1 làm được incremental + sim, không đụng block design.** T2 mới cần BD change (accelerator điều khiển DMA) — đây là phần "DDR→accel→DDR tự chủ" thật sự.

→ **Khuyến nghị: làm T1 trước** (gặt im2col + reuse + double-buffer, verify offline). T2 để sau / khi có board xác nhận Phase 1a.

## 3. Tầng T1 — Internal integration (no BD change)

### 3.1 Data flow T1

```
Firmware (mỗi layer): DMA feature map + weight → AXIS → accelerator; START; chờ DONE; DMA output ra
Accelerator nội bộ:
   feature map → Scratchpad (vùng FM)
   im2col.v: FM → A-block (Scratchpad vùng A)        ← gỡ im2col SW
   GEMM: A-block × weight (reuse, SKIP_W_LOAD) → multi-slot accumulator (HW K-acc)
   double-buffer: im2col sinh A-block N+1 ‖ GEMM ăn A-block N (ping-pong vùng A)
   post_proc (+bias +act +pool) → AXIS out
```

### 3.2 Module slot vào đâu

| Module (verified) | Vai trò trong T1 |
|---|---|
| `scratchpad.v` (2-bank) | giữ FM + A-block, ping-pong vùng A cho double-buffer |
| `im2col.v` | sinh A-block từ FM trong scratchpad (state `IM2COL_RUN`) |
| `accumulator` (multi-slot, đã trong control_unit) | psum blocking (đã có Phase 1a-ii-B) |
| skip-bit (SKIP_W_LOAD/SKIP_IN_LOAD) | reuse (đã có Phase 1a-ii) |

### 3.3 Increment T1 (mỗi bước sim verify)

```
T1-a: wire scratchpad.v + im2col.v vào accelerator.v
      control_unit state IM2COL_RUN: FM(scratchpad) → im2col → A(scratchpad)
      → accelerator_top_tb case: feed raw FM, expect output = im2col+GEMM
      firmware: bỏ im2col_sw() cho 1 layer thử
T1-b: GEMM đọc A-block từ scratchpad (thay input_buf streaming)
T1-c: double-buffer — tách load-lane (im2col sinh A-block) ‖ exec-lane (GEMM),
      handshake EMPTY/READY ping-pong vùng A
```

### 3.4 Rủi ro T1
- im2col↔scratchpad↔GEMM addressing phải khớp (block boundary). Mitigation: sim case nhỏ trước.
- A-block > 1 bank → blocking on-chip (sinh block vừa bank). Mitigation: tính block size theo §3 design note.
- Timing: thêm scratchpad read latency vào path. Mitigation: pipeline +1 stage nếu trượt (synth check).

## 4. Tầng T2 — Autonomy (CISC loop + self-DMA, CÓ BD change)

### 4.1 Thay đổi kiến trúc cốt lõi

Accelerator phải **tự lập trình DMA** thay vì firmware. Cần:
- **Thêm AXI-Lite master port** trên accelerator → drive register config của AXI DMA.
- **Outer-loop FSM**: đếm tile_idx_m/k/n, tự khởi DMA mỗi block, tự double-buffer.
- **Descriptor registers** (firmware ghi 1 lần): `LOOP_M/K/N_TOTAL`, `LOOP_A/W/C_BASE`, `LOOP_ACT_MODE`, `op_type` (conv/fc), im2col params.
- **IRQ** khi layer xong (3d).

### 4.2 BD change (phá nguyên tắc "không đụng BD" — cân nhắc kỹ)
- Thêm master port accelerator → SmartConnect → DMA config.
- Re-package IP, re-validate BD, re-synth full system.
- → Đây là lần đầu Phase 1-2 phải đụng block design. Rủi ro tích hợp cao.

### 4.3 Increment T2
```
T2-a: descriptor registers + outer-loop FSM (vẫn firmware-fed data) — sim
T2-b: AXI-Lite master port + DMA init logic — sim với DMA model
T2-c: firmware → fire-and-forget (ghi descriptor + chờ IRQ)
T2-d: BD: thêm master port, re-package, full-system synth/impl
```

## 5. Khuyến nghị thực thi

1. **Làm T1 trước** (im2col + reuse + double-buffer internal). Gặt phần lớn lợi ích memory-hierarchy, verify offline, không đụng BD. Tag `v-phase2-T1`.
2. **Đo board nếu có** sau T1 → xác nhận reuse 1×→10× + latency giảm thật.
3. **T2 (autonomy)** chỉ làm khi: (a) T1 đã verify lợi ích, (b) chấp nhận BD change + full-system rebuild. Đây là phase rủi ro nhất — cân nhắc để gần cuối, hoặc thừa nhận "firmware-orchestrated" là đủ cho luận văn (T1) và T2 là future work.

→ **T1 ≈ "2a integration + 1b"** (user muốn 2a→1b). **T2 ≈ Phase 2c** (CISC). Tách rõ giúp gặt lợi ích sớm mà không ôm rủi ro BD ngay.

## 6. Cái gì KHÔNG đổi (giữ surgical)
- Phase 1a control bits (CFG[15:20]) tái dùng nguyên.
- pe.v / data_path.v core không đụng (chỉ thay nguồn feed input_buf → scratchpad).
- post_proc.v: T1 giữ nguyên; pool (2b) thêm stage sau.

## Cross-references
- Module verified: `scratchpad.v`, `accumulator.v`, `im2col.v` (sim PASS).
- [phase1a_design.md](phase1a_design.md) §11-12 (streaming arch + scope split).
- [implementation_plan.md](implementation_plan.md) Phase 1b, 2a, 2c.
- [innovations_summary.md](innovations_summary.md) roadmap.
