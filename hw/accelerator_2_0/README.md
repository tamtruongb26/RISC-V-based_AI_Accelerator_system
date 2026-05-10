# accelerator_2_0 — TPU-like Weight-Stationary Systolic Array

GEMM accelerator 8×8 systolic, weight-stationary, fixed-point Q1.4.11. Là IP user.org cho hệ thống RAAS (PicoRV32 host + AXI DMA + Zynq UltraScale+ Ultra96-v2).

## 1. Cấu trúc thư mục

```
hw/accelerator_2_0/
├── README.md                        ← file này
├── hdl/                             ← RTL source
│   ├── pe.v                         (Bước 1b) Processing Element TPU canonical
│   ├── data_path.v                  (Bước 1c) SA_N×SA_N grid với horizontal a chain
│   ├── control_unit.v               (Bước 4) FSM lập lịch tile
│   ├── sigmoid_lookup.v             (Bước 6) ROM 1024×10-bit sigmoid LUT
│   ├── post_proc.v                  (Bước 7) Pipeline 3-stage: bias + activation + saturate
│   ├── accelerator.v                (Bước 10) Top wrapper
│   ├── accelerator_slave_lite_v2_0_S00_AXI.v       (Bước 9) AXI-Lite register file
│   ├── accelerator_slave_stream_v2_0_S00_AXIS.v    (Bước 9) AXIS slave (DMA → accelerator)
│   └── accelerator_master_stream_v2_0_M00_AXIS.v   (Bước 9) AXIS master (accelerator → DMA)
├── tb/                              ← SystemVerilog testbench
│   ├── pe_tb.sv                     (Bước 2)
│   ├── data_path_tb.sv              (Bước 3)
│   ├── control_unit_tb.sv           (Bước 5)
│   ├── post_proc_tb.sv              (Bước 8)
│   └── accelerator_top_tb.sv        (Bước 11)
└── scripts/                         ← TCL runner cho Vivado GUI
    └── run_*.tcl
```

## 2. Kiến trúc TPU canonical

```
                col 0       col 1       col 2          col N-1
row 0  a[0]──►PE(0,0)──►PE(0,1)──►PE(0,2)──► ... ──►PE(0,N-1)──►
              ↓psum     ↓psum     ↓psum                ↓psum
row 1  a[1]──►PE(1,0)──►PE(1,1)──►PE(1,2)──► ... ──►PE(1,N-1)──►
              ↓psum     ↓psum     ↓psum                ↓psum
                                  ...
row K-1  a[K-1]──►PE(K-1,0)──►PE(K-1,1)──► ... ──►PE(K-1,N-1)──►
                  ↓ result   ↓ result            ↓ result
                  C[m][0]    C[m][1]              C[m][N-1]
```

- **a chảy ngang** 1 cycle/PE (registered hop, low fan-out).
- **psum chảy dọc** 1 cycle/row (cộng dồn K terms).
- **weight đứng yên**: nạp 1 lần đầu tile, dùng cho cả tile.
- Sau pipeline-fill, throughput = 1 row output/cycle.
- Latency 1 tile M×K×N: **M+N+K-1** cycle.

## 3. Số học Q1.4.11

```
Bit:  15 | 14 13 12 11 | 10 9 8 7 6 5 4 3 2 1 0
       S |   I3..I0    |       F10..F0
```

- 16-bit signed, dải [-16.0, +15.99951…], step 2⁻¹¹ ≈ 4.88×10⁻⁴.
- PE: Q1.4.11 × Q1.4.11 = Q2.8.22 (32-bit) → sign-extend lên 40-bit cho ACC để cộng tối đa K=8 phần tử mà không overflow.
- post_proc: 40-bit acc → truncate về Q1.8.7 → cộng bias → activation → saturate Q1.4.11.

## 4. Pattern firmware lái 1 tile (skewed feed)

Vì a chảy ngang 1 cycle/PE và psum chảy dọc 1 cycle/row, để cùng 1 phần tử C[m][n] = Σ A[m][k]·W[k][n] được tính đúng, firmware phải feed input THEO HƯỚNG SKEW:

**Tại cycle t, PE row r nhận**: `pi_a_left[r] = A[m=t-r][r]` khi `0 ≤ t-r < M`, ngược lại `pi_valid_left[r]=0`.

```
cycle  | a[0]      a[1]      a[2]      a[3]      a[4]   ...
-------+--------------------------------------------------------
  0    | A[0][0]   x         x         x         x          ← chỉ row 0 valid
  1    | A[1][0]   A[0][1]   x         x         x          ← row 0,1 valid (skewed by r)
  2    | A[2][0]   A[1][1]   A[0][2]   x         x          ← row 0,1,2 valid
  3    | A[3][0]   A[2][1]   A[1][2]   A[0][3]   x
 ...
  K-1  | (pipeline ổn định)
 ...
M+K-1  | (last input vào)
M+N+K-1| C[M-1][N-1] xuất ra po_psum_bottom[N-1]
```

**Output capture**: tại cycle `cmp_t`, nếu `po_valid_bottom[n]=1`:
```
m_index = (cmp_t - n - K) mod 8
psum_buf[m_index][n] ← po_psum_bottom[n]
```

## 5. Lifecycle 1 tile (FSM control_unit)

```
IDLE
 │ pi_start (CONTROL[0]=1 từ AXI-Lite)
 ▼
LOAD_W_RECV  ↔  LOAD_W_PULSE        (8 hàng × (4 word AXIS recv + 1 cycle pulse) = 40 cycle)
 │ done
 ▼
LOAD_BIAS                            (4 word AXIS = 8 bias)
 │ done
 ▼
LOAD_INPUT                           (⌈M×K/2⌉ word AXIS)
 │ done
 ▼
COMPUTE                              (M+N+K-1 cycle, drive skewed a + capture psum)
 │ cmp_t == M+N+K-2 → done
 ▼
POST_PROC                            (M×N cycle feed + 3 cycle pipeline drain)
 │ done
 ▼
SEND_OUT                             (M × ⌈N/2⌉ word AXIS)
 │ done
 ▼
DONE → IDLE
```

## 6. Address map AXI-Lite (S00_AXI)

> Sẽ điền chi tiết sau Bước 9 (file `accelerator_slave_lite_v2_0_S00_AXI.v`).

| Offset | Tên | R/W | Mô tả |
|---|---|---|---|
| 0x00 | `TILE_M` | R/W | Số hàng A trong tile (1..8) |
| 0x04 | `TILE_K` | R/W | Số cột A / hàng B (1..8) |
| 0x08 | `TILE_N` | R/W | Số cột B (1..8) |
| 0x0C | `CONTROL` | R/W | bit0=START (auto-clear), bit2:1=ACT_MODE (00=bypass, 01=ReLU, 10=sigmoid) |
| 0x10 | `STATUS` | R | bit0=BUSY, bit1=DONE |

## 7. Word packing AXIS (32-bit data, little-endian element)

Mọi stream word 32-bit chứa **2 phần tử Q1.4.11**:

```
word[15:0]  = element index chẵn  (2*pair + 0)
word[31:16] = element index lẻ    (2*pair + 1)
```

- Số word LOAD_W: SA_N × SA_N / 2 = 32 word (nạp đủ 8×8 weight, zero-pad nếu tile nhỏ).
- Số word LOAD_BIAS: SA_N / 2 = 4 word.
- Số word LOAD_INPUT: M × ⌈K/2⌉.
- Số word SEND_OUT: M × ⌈N/2⌉.

## 8. Build & Simulation

### Mở Vivado GUI
Dùng MCP server hoặc thủ công:
```
vivado fpga/Accelerator_v2_tb.xpr
```

### Add source mới
- `Add Sources → Add Files → hw/accelerator_2_0/hdl/*.v` (Synthesis & Simulation).
- `Add Sources → Add Files → hw/accelerator_2_0/tb/*.sv` (Simulation only).

### Chạy testbench
- Trong Sources panel → right-click TB → `Set as Top`.
- `Run Simulation → Run Behavioral Simulation`.
- Tcl Console hiển thị `[OK]` / `[FAIL]` từng test case.
- Pass criteria: in `=== ALL <module> TESTS PASSED ===`.

### TCL runner (để chạy nhanh)
```tcl
source hw/accelerator_2_0/scripts/run_pe_tb.tcl
source hw/accelerator_2_0/scripts/run_data_path_tb.tcl
source hw/accelerator_2_0/scripts/run_control_unit_tb.tcl
source hw/accelerator_2_0/scripts/run_post_proc_tb.tcl
source hw/accelerator_2_0/scripts/run_accelerator_top_tb.tcl
```

## 9. Reference: broadcast version cũ

Trước khi rebuild theo TPU canonical, `pe.v` và `data_path.v` được viết theo kiến trúc **broadcast + vertical staircase** (a[r] broadcast cùng giá trị tới mọi cột row r). Phiên bản gốc đó vẫn còn ở:

- [fpga/Accelerator_v2_tb.srcs/sources_1/new/pe.v](../../fpga/Accelerator_v2_tb.srcs/sources_1/new/pe.v)
- [fpga/Accelerator_v2_tb.srcs/sources_1/new/data_path.v](../../fpga/Accelerator_v2_tb.srcs/sources_1/new/data_path.v)

Folder cũ của accelerator_2_0 (component.xml, AXI shims cũ, FSM cũ) nằm tại `hw/accelerator_2_0_old_backup/` để tham khảo, không tham gia build.

## 10. Trạng thái plan rebuild

Plan: [planning-ho-n-thi-n-accelerator-2-0-refactored-wand](/home/tam/.claude/plans/planning-ho-n-thi-n-accelerator-2-0-refactored-wand.md)

| Bước | Mô tả | Trạng thái |
|---|---|---|
| 1a | Copy pe.v + data_path.v nguyên bản | ✅ Done |
| 1b | Modify pe.v → TPU canonical | ✅ Done |
| 1c | Modify data_path.v → TPU canonical | ✅ Done |
| 1d | README (file này) | ✅ Done |
| 2 | TB pe_tb.sv | ⏳ Pending |
| 3 | TB data_path_tb.sv (skewed feed) | ⏳ Pending |
| 4 | control_unit.v FSM | ⏳ Pending |
| 5 | TB control_unit_tb.sv | ⏳ Pending |
| 6 | sigmoid_lookup.v + ROM | ⏳ Pending |
| 7 | post_proc.v | ⏳ Pending |
| 8 | TB post_proc_tb.sv | ⏳ Pending |
| 9 | 3 AXI shim | ⏳ Pending |
| 10 | accelerator.v top wrapper | ⏳ Pending |
| 11 | TB accelerator_top_tb.sv | ⏳ Pending |
| 12 | IP packaging | ⏳ Pending |
| 13 | BD integration (RAS.bd) | ⏳ Pending |
| 14 | Smoke test 1 tile từ PicoRV32 | ⏳ Pending |
