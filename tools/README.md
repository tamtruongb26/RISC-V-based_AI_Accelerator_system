# Tools — RAAS LeNet-5 Inference Pipeline

Thư mục này chứa các script Python hỗ trợ luồng inference LeNet-5 trên hệ thống RAAS (RISC-V AI Accelerator System). Mục đích chính: chuyển đổi model PyTorch đã train → dữ liệu C header cho firmware/PS app, và cung cấp golden reference để verify phần cứng.

## Tổng quan luồng dữ liệu

```
PyTorch Model (train.py)
    │
    ▼
models/export_0.986/*_q1_4_11.hex   ← weights đã quantize Q1.4.11
    │
    ├──► lenet_reference.py          ← chạy inference fixed-point trên Python
    │        │                          để tạo golden output từng layer
    │        ▼
    │    tools/golden/*.hex          ← golden output per layer (debug firmware)
    │
    └──► gen_lenet_data.py           ← đóng gói weights + image → C header
             │
             ▼
         sw/vitis/RAS_lenet/src/lenet_data.h   ← PS app #include để nạp vào DDR
```

---

## Step 1: Python — Export Data + Golden Reference

### 1a. `lenet_reference.py` — Golden Reference Model

**Mục đích:** Chạy toàn bộ LeNet-5 inference bằng số học Q1.4.11 fixed-point **trên Python**, để có golden output từng layer. Khi firmware trên PicoRV32 cho ra kết quả sai, ta so sánh từng layer với golden để xác định layer nào bị lỗi.

**Tại sao cần fixed-point reference thay vì dùng thẳng PyTorch?**
PyTorch chạy floating-point 32-bit, trong khi phần cứng dùng Q1.4.11 (16-bit). Kết quả sẽ khác nhau do truncation/saturation. Script này mô phỏng chính xác cùng phép tính mà phần cứng sẽ thực hiện:
- Phép nhân: `a × b` → tích 32-bit → dịch phải 11 bit (truncate, không round)
- Tích lũy: cộng dồn trong 32-bit (tương đương 40-bit accumulator trong hardware)
- Bias: cộng sau khi tích lũy xong → saturate về [-32768, +32767]
- ReLU: `max(0, x)` trên giá trị Q1.4.11

**Luồng xử lý chi tiết:**

| Bước | Phép toán | Input | Output |
|---|---|---|---|
| Load image | Pixel [0,255] ÷ 255 → Q1.4.11 | MNIST raw bytes | `image_q[784]` |
| Conv1 | `im2col(1×28×28, k=5)` → GEMM(576×25, 25×6) + bias + ReLU | image_q | conv1_out[576×6] |
| Pool1 | maxpool 2×2 trên [6×24×24] | conv1_out (reshape CHW) | pool1_out[6×12×12] |
| Conv2 | `im2col(6×12×12, k=5)` → GEMM(64×150, 150×16) + bias + ReLU | pool1_out | conv2_out[64×16] |
| Pool2 | maxpool 2×2 trên [16×8×8] | conv2_out (reshape CHW) | pool2_out[16×4×4] |
| FC1 | GEMM(1×256, 256×120) + bias + ReLU | pool2_out (flatten=256) | fc1_out[120] |
| FC2 | GEMM(1×120, 120×84) + bias + ReLU | fc1_out | fc2_out[84] |
| FC3 | GEMM(1×84, 84×10) + bias + ReLU | fc2_out | fc3_out[10] |
| Argmax | index of max value | fc3_out | predicted_digit |

**Điểm quan trọng — Weight Transpose:**
PyTorch lưu weight Conv2d theo `[C_out, C_in, kH, kW]` (ví dụ Conv1: `[6, 1, 5, 5]` = 150 phần tử). Khi flatten ra, nó là ma trận `[C_out × K_total]` = `[6 × 25]`. Nhưng phép GEMM cần `W[K_total × C_out]` = `[25 × 6]`, nên phải **transpose** trước khi nhân.

**Cách chạy:**
```bash
python3 tools/lenet_reference.py --image-index 0
```

**Output:**
- In golden output từng layer lên console
- Tạo thư mục `tools/golden/` chứa hex file per layer (dùng so sánh với firmware)
- Exit code 0 nếu predicted đúng, 1 nếu sai

### 1b. `gen_lenet_data.py` — Export Weights + Image → C Header

**Mục đích:** Đọc weights Q1.4.11 đã quantize từ `models/export_0.986/`, kết hợp với 1 ảnh MNIST test, đóng gói thành file C header `lenet_data.h`. File này được PS app (Vitis) `#include` để nạp dữ liệu vào DDR trước khi PicoRV32 chạy inference.

**Xử lý chính:**
1. Đọc 10 file hex (5 weight + 5 bias) từ thư mục export
2. **Transpose tất cả weight matrices** từ PyTorch layout sang GEMM layout (giống reference model)
3. Đọc 1 ảnh MNIST → quantize pixel/255.0 → Q1.4.11
4. Pack 2 giá trị uint16 → 1 uint32 (little-endian, khớp với AXI 32-bit data bus)
5. Xuất ra C arrays: `lenet_image[]`, `lenet_conv1_weight[]`, `lenet_conv1_bias[]`, ...

**Cách chạy:**
```bash
python3 tools/gen_lenet_data.py --image-index 0
# Output: sw/vitis/RAS_lenet/src/lenet_data.h (306 KB)
```

**Format output (ví dụ):**
```c
#define LENET_TEST_LABEL  7u

/* Input image 28x28, 784 elements Q1.4.11 */
static const uint32_t lenet_image[392] = {
    0x00000000u, 0x00000000u, ...
};

/* conv1 weight [25x6] transposed, 150 elements */
static const uint32_t lenet_conv1_weight[75] = { ... };

/* conv1 bias [6] elements */
static const uint32_t lenet_conv1_bias[3] = { ... };
```

---

## Step 2: Firmware — `lenet_map.h` + `gemm_tile.c`

### 2a. `sw/picorv32/include/lenet_map.h` — DDR Layout Defines

**Mục đích:** Định nghĩa tất cả địa chỉ offset trong DDR cho LeNet-5 inference. File này là "bản đồ" mà cả firmware PicoRV32 lẫn PS app cùng tham chiếu để biết weights/bias/image/feature maps nằm ở đâu trong DDR.

Các offset khớp với [system_description.md §5.1](../docs/system_description.md). PS app ghi dữ liệu vào đúng offset này, sau đó PicoRV32 đọc từ cùng offset đó.

### 2b. `sw/picorv32/src/gemm_tile.c` — Tiled GEMM Core

**Mục đích:** Đây là hàm **quan trọng nhất** của toàn bộ firmware — thực hiện phép nhân ma trận tổng quát `C[M×N] = A[M×K] × W[K×N] + bias[N]` bằng cách chia thành nhiều tile 8×8 rồi gửi xuống systolic array accelerator qua DMA.

**Tại sao cần tiling?** Systolic array chỉ hỗ trợ tile tối đa 8×8. Nhưng LeNet-5 có ma trận lớn hơn nhiều (ví dụ FC1: 256×120). Nên firmware phải:
1. Chia ma trận lớn thành các sub-matrix 8×8
2. Gửi từng sub-matrix xuống accelerator
3. Cộng dồn kết quả khi K > 8 (software accumulation)
4. Apply bias + ReLU bằng software sau khi cộng xong tất cả K-tiles

**Thuật toán tiling (3 vòng lặp lồng nhau):**
```
for n_tile in (0, 8, 16, ..., N):     ← duyệt cột output
  for m_tile in (0, 8, 16, ..., M):   ← duyệt hàng output
    zero accumulator C_acc[8×8]
    for k_tile in (0, 8, 16, ..., K): ← duyệt chiều tích lũy
      1. Copy sub-weight W[k..k+8, n..n+8] → TILE_W_BUF (pad nếu < 8)
      2. Copy sub-input  A[m..m+8, k..k+8] → TILE_IN_BUF (pad nếu < 8)
      3. Set bias = 0 (accelerator bypass, ta tự cộng bias sau)
      4. Configure accelerator: M=8, K=min(8,remaining), N=8, act=BYPASS
      5. DMA stream: weights → bias(zeros) → input → output
      6. Đọc tile output từ TILE_OUT_BUF
      7. C_acc[i][j] += tile_output[i][j]  (cộng dồn Q1.4.11)
    // Sau khi hết K-tiles:
    8. C_acc[i][j] += bias[n+j]            (cộng bias 1 lần)
    9. if ReLU: C_acc[i][j] = max(0, C_acc[i][j])
    10. Ghi C_acc vào C[m..m+8, n..n+8] trên DDR
```

**Tại sao bias = 0 trong từng tile?** Vì accelerator tự động cộng bias trong post-proc pipeline. Nhưng khi K > 8, ta phải cộng dồn nhiều tile trước rồi mới cộng bias, nên gửi bias = 0 cho accelerator và tự cộng bằng software ở cuối.

**Padding:** Khi tile ở biên (ví dụ M còn lại = 3 thay vì 8), firmware pad thêm zeros vào TILE_IN_BUF/TILE_W_BUF để đủ 8×8, vì accelerator luôn xử lý 8×8. Output pad sẽ bị bỏ qua khi ghi lại DDR.

**Build & verify:**
```bash
make lenet    # build firmware_lenet.elf (bao gồm gemm_tile.o)
```

---

## Step 3: Firmware — `im2col.c` + `pool.c`

### 3a. `sw/picorv32/src/im2col.c` — im2col Transform

**Mục đích:** Chuyển đổi feature map 3D (CHW) thành ma trận 2D để convolution trở thành phép nhân ma trận mà systolic array có thể thực hiện.

**Tại sao cần im2col?** Systolic array chỉ biết nhân ma trận `C = A × B`. Nhưng convolution là phép trượt kernel trên ảnh, không phải phép nhân ma trận trực tiếp. im2col "giả lập" convolution bằng cách:

1. Với mỗi vị trí output (h, w), ta trích xuất vùng receptive field kích thước `C_in × kH × kW`
2. Flatten vùng đó thành 1 hàng
3. Xếp tất cả các hàng → ma trận `[H_out*W_out × C_in*kH*kW]`

Sau đó, nhân ma trận này với weight matrix `[C_in*kH*kW × C_out]` cho kết quả đúng bằng convolution.

**Ví dụ Conv1 (1×28×28, kernel 5×5, 6 filters):**

```
Input: 1 channel × 28×28        Weight (PyTorch): [6, 1, 5, 5]
                                 Weight (transposed): [25 × 6]

im2col output: [576 × 25]       576 = 24×24 output positions
               Mỗi hàng = 1 patch 5×5 = 25 elements

GEMM: [576 × 25] × [25 × 6] = [576 × 6]
      = Conv1 output (24×24×6 dưới dạng [H_out*W_out × C_out])
```

**Thứ tự duyệt trong receptive field:** CHW — với mỗi output pixel, duyệt lần lượt:
```
for c in 0..C_in:        ← channel ngoài cùng
  for kh in 0..kH:       ← chiều dọc kernel
    for kw in 0..kW:     ← chiều ngang kernel
```
Thứ tự này khớp với cách PyTorch flatten weight `[C_out, C_in, kH, kW]`, nên sau khi transpose weight thành `[C_in*kH*kW, C_out]`, phép nhân sẽ cho kết quả đúng.

**Hiệu năng:** Conv1 im2col tạo 576×25 = 14400 phần tử, mỗi phần tử cần 1 read + 1 write DDR. Với PicoRV32 @ 100MHz, ước tính ~1ms. Chấp nhận được.

### 3b. `sw/picorv32/src/pool.c` — Max-Pool 2×2

**Mục đích:** Giảm kích thước spatial của feature map xuống một nửa (cả chiều rộng lẫn chiều cao) bằng cách chọn giá trị lớn nhất trong mỗi vùng 2×2.

**Tại sao chạy bằng software?** Max-pool chỉ là so sánh và chọn max — không cần phép nhân, không cần systolic array. Chạy trực tiếp trên PicoRV32 nhanh hơn setup DMA + accelerator cho phép tính đơn giản này.

**Ví dụ Pool1 (6×24×24 → 6×12×12):**
```
Với mỗi channel c (0..5):
  Với mỗi vùng 2×2 ở vị trí (h, w):
    output[c][h][w] = max(input[c][2h][2w],   input[c][2h][2w+1],
                         input[c][2h+1][2w], input[c][2h+1][2w+1])
```

**Layout:** Input và output đều ở CHW (channel-first, row-major). Mỗi phần tử là Q1.4.11 (16-bit), lưu trong DDR với 2 phần tử per word.

---

## Step 4: Firmware — `lenet.c` + `main_lenet.c` + Makefile

### 4a. `sw/picorv32/src/lenet.c` — Layer Orchestration

**Mục đích:** Xâu chuỗi 7 layer thành pipeline inference hoàn chỉnh, quản lý ping-pong buffers.

**Ping-pong buffers:** Thay vì cấp vùng DDR riêng cho output từng layer (tốn không gian), ta dùng 2 buffer luân phiên:
- Layer lẻ (Conv1, Conv2, FC1, FC3) đọc từ buffer X, ghi vào buffer Y
- Layer chẵn (Pool1, Pool2, FC2) đọc từ buffer Y, ghi vào buffer X

Cụ thể:

| Step | Layer | Input buffer | Output buffer |
|---|---|---|---|
| 1 | Conv1 | IMAGE → im2col → GEMM | → FMAP_A (temp HWC) → transpose → FMAP_B |
| 2 | Pool1 | FMAP_B | → FMAP_A |
| 3 | Conv2 | FMAP_A → im2col → GEMM | → FMAP_B (temp HWC) → transpose → FMAP_A |
| 4 | Pool2 | FMAP_A | → FMAP_B |
| 5 | FC1   | FMAP_B | → FMAP_A |
| 6 | FC2   | FMAP_A | → FMAP_B |
| 7 | FC3   | FMAP_B | → FMAP_A |
| 8 | Argmax | FMAP_A[10] | → predicted digit |

**HWC→CHW transpose:** GEMM output là `[H_out*W_out × C_out]` (mỗi hàng = 1 pixel, mỗi cột = 1 channel). Nhưng Pool kỳ vọng CHW layout `[C × H × W]`. Nên sau mỗi Conv GEMM, firmware thực hiện transpose:
```
src[hw * C + c]  →  dst[c * H_out * W_out + hw]
```
FC layers không cần transpose vì M=1 (chỉ 1 hàng).

**Debug checkpoint:** Mỗi layer ghi index vào `LENET_DDR_LAYER_DBG_OFF`. Nếu firmware hang, PS có thể đọc giá trị này để biết layer nào bị stuck.

### 4b. `sw/picorv32/src/main_lenet.c` — Entry Point

**Mục đích:** Entry point đơn giản — boot signal → DMA reset → inference → report → halt.

Luồng:
```
1. mailbox = STARTED   (PS biết firmware đã boot)
2. dma_reset()         (clean state)
3. lenet5_infer()      (chạy 7 layer, trả về predicted digit)
4. Ghi predicted digit vào DDR
5. mailbox = PASS      (PS biết inference xong)
6. while(1) nop        (halt, PS đọc result)
```

### 4c. Makefile — Hai target riêng biệt

**Mục đích:** Cho phép build smoke test và LeNet-5 firmware độc lập, không xung đột `main()`.

| Command | Firmware | Entry point | Size |
|---|---|---|---|
| `make all` | `firmware.bin` (smoke test) | `src/main.c` | 932 B |
| `make lenet` | `firmware_lenet.bin` (LeNet-5) | `src/main_lenet.c` | 3636 B |

Cả hai chia sẻ các module: `accel.c`, `dma.c`, `mailbox.c`.  
LeNet-5 thêm: `gemm_tile.c`, `im2col.c`, `pool.c`, `lenet.c`.

Object files dùng prefix (`smoke.*` / `lenet.*`) để tránh xung đột trong cùng thư mục `build/`.

```bash
make clean          # xóa build/
make all            # build smoke test firmware
make lenet          # build lenet firmware
make hex_lenet      # tạo firmware_lenet.hex cho Vivado simulation
```
