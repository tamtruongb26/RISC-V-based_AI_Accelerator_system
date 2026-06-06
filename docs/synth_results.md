# Synthesis Results — Accelerator OOC (area + timing)

> Out-of-context synthesis của `accelerator` IP (chỉ riêng accelerator, không
> gồm PicoRV32/DMA/interconnect). Board: ZU3EG. Clock target 100 MHz (10ns).
> Script: [scripts/synth_accel.tcl](../scripts/synth_accel.tcl).
> Đây là nửa "verify offline" còn lại (sim = chức năng, synth = area/timing).

## Ablation: v-baseline (Phase 0) → v-phase1a

| Tài nguyên | v-baseline | v-phase1a | Δ | ZU3EG |
|---|---|---|---|---|
| LUT | 6,003 (8.5%) | 12,058 (17.1%) | +6,055 (~2×) | 70,560 |
| **FF (Register)** | 9,108 (6.5%) | 17,519 (12.4%) | **+8,411** | 141,120 |
| DSP48 | 67 | 67 | 0 | 360 |
| BRAM 36Kb | 0.5 | 0.5 | 0 | 216 |
| WNS @100MHz | +8.43ns | +8.68ns | — | (0 fail) |
| Setup fail endpoints | 0 | 0 | — | — |

## Đọc kết quả

- **FF +8,411 ≈ chi phí multi-slot accumulator** (Phase 1a-ii-B). Baseline psum_buf
  1 slot = 8×8×40 = 2,560 FF; phase1a 4 slot = 10,240 FF → +7,680, cộng logic
  K-acc/reuse/mux ≈ +8.4k. **Khớp claim "~+7.7k FF"** trong design note.
- **DSP không đổi (67)** = 64 PE + ~3 (post_proc). Đúng 1 DSP/PE.
- **BRAM không đổi (0.5)** = chỉ sigmoid_rom. Multi-slot làm bằng **register** (không
  BRAM) → đúng trade Phase 1a-ii-B (FF thay BRAM, tránh re-time).
- **Timing 100MHz pass dư cả 2 version** (WNS ~+8.5ns → critical path ~1.3ns).
  Phase 1a **không** làm xấu timing.

## Kết luận

Phase 1a tốn **~2× LUT/FF** nhưng tuyệt đối vẫn nhỏ (17% LUT, 12% FF) → **fit ZU3EG
thừa**, còn nhiều chỗ cho Phase 2-5 (gồm trụ Reliability). Đổi lại: HW K-accumulation
+ weight/input reuse + multi-slot blocking. **Trade hợp lý, timing không đổi.**

## Caveat (đọc đúng)

- **OOC synthesis** = chưa place & route → timing là **ước lượng (lạc quan)**; area
  khá chính xác. Số tuyệt đối có thể đổi khi tích hợp full system + impl.
- Chỉ **accelerator** (chưa gồm Pico/DMA/SmartConnect/boot BRAM).
- Power **chưa đo** (cần SAIF từ sim activation thật + post-impl).
- → Dùng để so **tương đối** (baseline vs phase1a) + xác nhận fit/timing, không phải
  số cuối cùng cho luận văn (số cuối cần post-implementation + board).

## Cross-references
- Thông số thiết kế + lý do: [phase1a_design.md](phase1a_design.md)
- Tổng kết đổi mới: [innovations_summary.md](innovations_summary.md)
- Template số liệu board: [baseline_metrics.md](baseline_metrics.md)
