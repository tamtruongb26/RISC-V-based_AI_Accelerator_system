# sigmoid_lookup — Design Spec

## 1. Mục đích

ROM lookup-table tính `sigmoid(x) = 1/(1+exp(-x))` cho post_proc.
Hardware không có FP / EXP unit → buộc dùng LUT đã pre-compute từ Python.

---

## 2. Q-format quy ước

### 2.1 Input address — Q1.3.6 (10-bit signed, two's complement)

```
   bit:    9   8 7 6 5   4 3 2 1 0
          [S] [I I I I] [F F F F F F]      (Wait — chỉnh: 1 sign + 3 int + 6 frac = 10)
                ▲           ▲
                │           └── 6 fraction bits (resolution = 1/64 ≈ 0.0156)
                └── 3 integer bits (range -8..+7)
```

Chính xác bit-width:
- bit `[9]` = sign
- bit `[8:6]` = integer (3 bits)
- bit `[5:0]` = fraction (6 bits)

Range: `[-8.000, +7.984375]`, step `1/64 = 0.015625`.

**Encoding của address index 0..1023**:
- Index `0..511` → x = `index/64` (positive: 0.0 → 7.984)
- Index `512..1023` → x = `(index - 1024)/64` (negative: -8.0 → -0.015625)

(Same scheme as 2's complement, signed view of 10-bit unsigned address.)

### 2.2 Output data — Q1.0.9 (10-bit unsigned)

```
   bit:    9   8 7 6 5 4 3 2 1 0
          [0] [F F F F F F F F F]
                ▲
                └── 9 fraction bits (resolution = 1/512 ≈ 0.00195)
```

- Sign bit `[9]` luôn = 0 (sigmoid(x) ∈ [0, 1)).
- Range stored: `[0, 0.998046875]` (= 511/512 max).
- `sigmoid(0) = 0.5` → stored as `256` (= `0x100`).
- `sigmoid(+∞) ≈ 1` → stored as `511` (= `0x1FF`, không dùng `512` vì hết bit).
- `sigmoid(-∞) ≈ 0` → stored as `0`.

**Vì sao Q1.0.9 unsigned thay vì signed?** Sigmoid không bao giờ âm → tiết kiệm 1 bit cho fraction. Caller tự thêm sign bit khi cần ghép vào pipeline Q1.4.11.

---

## 3. Module interface

```verilog
module sigmoid_lookup (
    input  wire        pi_clk,
    input  wire        pi_ena,            // clock enable (BRAM)
    input  wire [9:0]  pi_addr,           // Q1.3.6 input
    output reg  [9:0]  po_data            // Q1.0.9 output, registered (1-cycle latency)
);
```

- **Latency**: 1 cycle. Tại `pi_clk` edge `t`, sample `pi_addr`. Tại edge `t+1`, `po_data` valid.
- **Port count**: single-port (chỉ post_proc đọc). Old v1 dùng dual-port nhưng không cần thiết — simplify.
- **Backing storage**: `(* rom_style = "block" *)` → force Vivado map vào BRAM (1 BRAM 18Kb đủ chứa 1024×10 = 10240 bits).

---

## 4. Saturation handling — KHÔNG ở module này

LUT là pure ROM. **Caller (post_proc) PHẢI saturate input trước**.

Lý do:
- Input post_proc là Q1.8.7 (16-bit) sau truncate từ Q2.8.22.
- Address là Q1.3.6 (10-bit, range ±8).
- Nếu `Q1.8.7 value > +7.984375` → caller clamp về `addr = 10'h1FF` (= max positive Q1.3.6).
- Nếu `Q1.8.7 value < -8.0` → caller clamp về `addr = 10'h200` (= min negative Q1.3.6).

→ Tách logic saturate ra ngoài giúp module này nhỏ + đơn giản hơn để verify.

---

## 5. ROM content generation

File `tools/gen_sigmoid_rom.py`:

### Algorithm
```python
for idx in range(1024):
    # idx → signed Q1.3.6 → float
    if idx < 512:
        x = idx / 64.0                  # positive: 0.0 .. 7.984
    else:
        x = (idx - 1024) / 64.0         # negative: -8.0 .. -0.0156

    # sigmoid(x)
    s = 1.0 / (1.0 + math.exp(-x))

    # Q1.0.9 quantize
    val = round(s * 512)
    val = max(0, min(511, val))         # clamp [0, 511]

    rom[idx] = val
```

### Output formats

**Option 1 (PREFER)**: `sigmoid_rom.mem` — 1024 dòng hex 3-nibble:
```
100   # rom[0] = 0x100 = 256 = 0.5
104   # rom[1]  ≈ 0.508
...
```
Module `sigmoid_lookup.v` dùng `$readmemh("sigmoid_rom.mem", rom)` initial.

**Option 2**: Generate trực tiếp `initial begin rom[0] = ...; end` block trong `.v` file (như accelerator_1_0 cũ làm). **KHÔNG chọn** vì khó re-gen + commit lớn hơn.

→ **Chọn Option 1**.

---

## 6. Sample expected values (for TB sanity check)

| x (float) | addr (Q1.3.6 hex) | sigmoid(x) | data (Q1.0.9 hex) | data (decimal) |
|---|---|---|---|---|
| 0.000000  | 0x000 | 0.5000 | 0x100 | 256 |
| +1.000000 | 0x040 | 0.7311 | 0x176 | 374 |
| +2.000000 | 0x080 | 0.8808 | 0x1C3 | 451 |
| +4.000000 | 0x100 | 0.9820 | 0x1F7 | 503 |
| +7.984375 | 0x1FF | 0.99966 | 0x1FF | 511 (saturated max) |
| −1.000000 | 0x3C0 | 0.2689 | 0x08A | 138 |
| −4.000000 | 0x300 | 0.0180 | 0x009 | 9 |
| −8.000000 | 0x200 | 0.000335 | 0x000 | 0 |

Error budget: ±1 LSB Q1.0.9 (= ±1/512 ≈ 0.002) so với sigmoid float chính xác.

---

## 7. Synthesis target

- 1 × BRAM 18Kb (Ultra96 có 432 BRAM18 → tổng 0.23%).
- 0 LUT cho ROM data path.
- 1 register stage for output.

---

## 8. Why Q1.3.6 thay Q1.4.5 (v1)?

| | v1 (Q1.4.5) | v2 (Q1.3.6) |
|---|---|---|
| Range | ±16 | ±8 |
| Resolution | 1/32 ≈ 0.031 | **1/64 ≈ 0.016** (gấp 2) |
| Coverage of sigmoid | 99.9999...% | 99.97% |
| Effective info | wasted ở vùng x∈[8,16] (sigmoid đã ~1) | tập trung vào vùng "active" |

→ v2 cho output **chính xác hơn** trong range mà sigmoid thực sự thay đổi. Loss ở vùng |x|∈[8,16] không quan trọng vì sigmoid bão hòa trước đó.

---

## 9. File deliverables

| File | Mục đích |
|---|---|
| `hw/accelerator_2_0/hdl/sigmoid_lookup.v` | RTL module |
| `hw/accelerator_2_0/hdl/sigmoid_rom.mem` | Generated 1024-line hex file |
| `tools/gen_sigmoid_rom.py` | Python script sinh `.mem` |
| `hw/accelerator_2_0/hdl/sigmoid_spec.md` | Tài liệu này |

(Verification gộp vào `post_proc_tb.sv` ở Bước 8 — không có TB riêng.)