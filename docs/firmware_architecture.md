# Cấu trúc Firmware PicoRV32 (RAAS)

Tài liệu này mô tả chi tiết kiến trúc phần mềm chạy trên lõi vi điều khiển PicoRV32 (RV32IM bare-metal) trong hệ thống RAAS. Firmware đóng vai trò là trình điều khiển (driver) và trình phân bổ (orchestrator), điều khiển luồng dữ liệu giữa DDR, DMA, và lõi Accelerator (Systolic Array 8x8).

Hệ thống cung cấp hai phiên bản Firmware độc lập được quản lý qua một `Makefile` duy nhất:
1. **Smoke Test Firmware** (`make all`): Kiểm tra phần cứng cơ bản.
2. **LeNet-5 Inference Firmware** (`make lenet`): Chạy mô hình mạng nơ-ron tích chập đầy đủ.

---

## 1. Tổng quan Bộ nhớ & Giao tiếp (Memory & Communication)

PicoRV32 không có cache (L1/L2) và kết nối trực tiếp với AXI Interconnect. 
Không gian địa chỉ được chia làm 3 vùng chính:
- **BRAM (0x0000_0000 - 0x0000_FFFF):** 64KB Instruction & Data Memory nội bộ trên FPGA (chứa mã thực thi `.elf` / `.bin`).
- **Accelerator & DMA (0x0200_0000 và 0x0400_0000):** Vùng thanh ghi điều khiển bộ tăng tốc cứng và điều khiển AXI DMA (MM2S / S2MM).
- **DDR Memory (0x1000_0000 - ...):** Vùng RAM ngoài (được chia sẻ với lõi ARM Cortex-A53 của PS) dùng để chứa trọng số, feature maps, ảnh đầu vào và trao đổi trạng thái.

### Cơ chế Mailbox (Đồng bộ hóa PS - PL)
PicoRV32 giao tiếp với vi xử lý ARM (PS) thông qua một thanh ghi quy ước trên DDR gọi là **Mailbox**.
- PS ghi trạng thái `BOOT` (0x0) vào Mailbox, nạp Firmware vào BRAM, nạp Data vào DDR, rồi thả tín hiệu Reset.
- PicoRV32 khởi động, ghi trạng thái `STARTED` (0x1) vào Mailbox.
- PicoRV32 chạy tính toán. Nếu có lỗi (Timeout), ghi mã lỗi (Negative Error Code). Nếu thành công, ghi trạng thái `PASS` (0x2).
- PS liên tục poll (hỏi vòng) địa chỉ Mailbox này để lấy kết quả.

---

## 2. Phiên bản 1: Smoke Test Firmware (`make all`)

**Mục đích:** Xác minh tính toàn vẹn của phần cứng (DMA, Systolic Array, AXI Interconnect) trước khi chạy mạng Neural Network lớn.

**Thành phần:** `src/main.c`, `src/dma.c`, `src/accel.c`, `src/mailbox.c`.

**Luồng thực thi:**
1. Khởi động và gửi tín hiệu `STARTED`.
2. Reset AXI DMA.
3. Chạy 1 phép tính `C[8x8] = A[8x8] * W[8x8] + Bias[8]` thông qua Systolic Array.
4. Gửi `W` ➜ `Bias` ➜ `A` qua kênh `MM2S` (DMA).
5. Kích hoạt Accelerator với chế độ `BYPASS` hoặc `RELU`.
6. Chờ nhận kết quả `C` qua kênh `S2MM` (DMA).
7. Gửi tín hiệu `PASS` và kết thúc.

Data Layout cho Smoke test chiếm rất nhỏ (~12KB DDR), sử dụng file header `smoketest_data.h`.

---

## 3. Phiên bản 2: LeNet-5 Inference Firmware (`make lenet`)

**Mục đích:** Chạy inference cho toàn bộ kiến trúc mạng LeNet-5 (nhận diện chữ số viết tay MNIST), tự động phân rã các toán hạng lớn thành các tile 8x8 cho phần cứng xử lý.

**Thành phần bổ sung:** `src/main_lenet.c`, `src/lenet.c`, `src/gemm_tile.c`, `src/im2col.c`, `src/pool.c`.

### 3.1. Phân mảnh ma trận (`gemm_tile.c`)
Vì Systolic Array chỉ hỗ trợ kích thước cố định `8x8`, mọi phép nhân ma trận tùy ý `M x K` nhân với `K x N` phải được cắt nhỏ (tiled):
- **Padding:** Các viền không đủ kích thước 8 được độn thêm số 0 (Zero Padding).
- **K-Accumulation (Phần mềm cộng dồn):** Khi chiều `K > 8` (VD: Lớp FC1 có `K = 256`), phần cứng không thể cộng dồn 32 tile liên tiếp. Firmware xử lý bằng cách:
  - Gửi `Bias = 0` vào Accelerator.
  - Thu thập kết quả trung gian (`Partial Sums`) lưu vào bộ đệm `TILE_OUT`.
  - Dùng CPU (PicoRV32) cộng dồn các ma trận này lại với nhau (bằng mã C).
  - Sau khi duyệt hết chuỗi `K`, CPU mới tiến hành cộng dồn `Bias` chuẩn và chạy hàm kích hoạt `ReLU`.

### 3.2. Tiền xử lý Dữ liệu Convolution (`im2col.c` & `pool.c`)
- **im2col:** Bộ tăng tốc chỉ giải quyết bài toán nhân ma trận (GEMM), do đó, phép tích chập (Convolution) được firmware "phẳng hóa" (flatten) bằng thuật toán `im2col`.
  - Trích xuất từng receptive field của ảnh đầu vào.
  - Xếp thành một ma trận 2D khổng lồ `[H_out*W_out] x [C_in*kH*kW]`.
  - Đưa xuống hàm `gemm_tiled`.
- **Max-Pool 2x2:** Việc tìm giá trị max là một tác vụ cực kỳ đơn giản. Việc setup DMA và Accelerator mất quá nhiều xung nhịp (overhead) nên `pool.c` được triển khai 100% bằng Software chạy trực tiếp trên PicoRV32.

### 3.3. Orchestration & Ping-Pong Buffers (`lenet.c`)
Inference chạy qua 7 layer: `Conv1 ➜ Pool1 ➜ Conv2 ➜ Pool2 ➜ FC1 ➜ FC2 ➜ FC3`.
Thay vì cấp phát 7 vùng nhớ riêng biệt trên DDR làm tràn RAM, Firmware sử dụng kỹ thuật **Ping-Pong Buffers**:
- Cấp 2 vùng nhớ cố định: `FMAP_A` và `FMAP_B`.
- Lớp 1 đọc ảnh, ghi vào `FMAP_B`.
- Lớp 2 đọc `FMAP_B`, ghi vào `FMAP_A` ...
Sau Conv1 và Conv2, Firmware tự động chạy hàm **Transpose** chuyển đổi từ định dạng lưu trữ của GEMM (`HWC`) về định dạng kênh ảnh (`CHW`) để chuẩn bị cho bước Max Pool.

---

## 4. Đánh giá Hiệu năng (Performance Benchmarking)

Được tích hợp trong `main_lenet.c`, chức năng Benchmarking sử dụng thanh ghi `rdcycle` nội bộ của RISC-V để đếm số chu kỳ xung nhịp trôi qua.
- **Hardware Run:** Gọi `lenet5_infer(use_hw = 1)`. Các hàm `gemm` gửi tính toán xuống bộ tăng tốc Systolic.
- **Software Run:** Gọi `lenet5_infer(use_hw = 0)`. Các hàm `gemm` chạy hàm nhân ma trận 3 vòng lặp bằng `C` nguyên bản.

**Phân tích Kết quả (Ví dụ thực tế ở tần số 100MHz):**
- Hardware Cycles: `239,428,381` (~2.39s)
- Software Cycles: `436,173,845` (~4.36s)
- Mức tăng tốc (Speedup): **1.82x**

**Giải thích "Cổ chai Dữ liệu" (Data Starvation Limit):**
Mặc dù mảng 8x8 có thể nhân ma trận cực nhanh (đạt giới hạn lý thuyết khoảng hơn 3.500 lần). Tuy nhiên, tốc độ thực tế chỉ đạt 1.82x bởi vì:
1. **L1 Cache:** PicoRV32 không có bộ đệm dữ liệu (L1 Data Cache), và đang đọc từng điểm ảnh 16-bit qua bus AXI (tốn 40-50 cycles / 1 lần đọc DDR).
2. **Overhead của CPU:** Việc dùng CPU chuẩn bị dữ liệu (im2col, cắt tile 8x8, cộng dồn Partial Sums bằng phần mềm) chiếm hơn **99% tổng số chu kỳ** của hệ thống. 
3. **Phần cứng thiếu đói:** Accelerator chỉ cần 24 cycles để giải quyết 1 khối 8x8, nhưng phải chờ CPU hàng trăm nghìn cycles để nhặt và sắp xếp dữ liệu. Đây là hệ thống "Memory Bound" và "Software-Tiling Bound" điển hình.

---

## 5. Hướng dẫn Build

Sử dụng chuỗi công cụ RISC-V GCC (`riscv32-xilinx-elf-gcc`).
Vào thư mục `sw/picorv32`:

```bash
make clean

# 1. Build Smoke Test (Sẽ tạo ra firmware.bin và copy tới RAS_application)
make all

# 2. Build LeNet-5 (Sẽ tạo ra firmware_lenet.bin và copy tới RAS_lenet)
make lenet
```

Lưu ý: Header chứa mã Hex của firmware sẽ được tự động xuất ra thư viện tương ứng trong Project của Vitis (ví dụ: `RAS_lenet/src/firmware_image.h`) thông qua script Python `bin_to_c.py`. Mọi thay đổi trong Firmware sẽ yêu cầu Rebuild project ở Vitis để hiệu lực.
