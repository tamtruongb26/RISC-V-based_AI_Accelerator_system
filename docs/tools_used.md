# Danh sách các công cụ và phần mềm sử dụng cho đồ án

Dựa trên cấu trúc và tài liệu của dự án "RISC-V-based AI Accelerator system", dưới đây là danh sách chi tiết các công cụ (tools), phần mềm và công nghệ được sử dụng:

## 1. Thiết kế Phần cứng và FPGA (Hardware/FPGA Design)
- **Xilinx Vivado (Phiên bản 2025.2.1):** Công cụ chính để tổng hợp (synthesis), triển khai (implementation), mô phỏng XSIM, và cấu hình phần cứng cho FPGA (board Ultra96v2 - Zynq UltraScale+ MPSoC). Vivado cũng được dùng để tích hợp các IP như AXI DMA, SmartConnect và tạo các custom IP (MLP Accelerator, SW Reset). Cài đặt hiện dùng trong máy: `/home/tam/Documents/app/2025.2.1/Vivado/bin/vivado`.
- **Ngôn ngữ mô tả phần cứng (HDL):** Verilog và SystemVerilog được sử dụng để viết mã nguồn cho các Custom IPs trong thư mục `hw/`.

## 2. Vi xử lý và Firmware cho RISC-V
- **PicoRV32:** Lõi vi xử lý mềm (soft-core) kiến trúc RISC-V 32-bit, đóng vai trò làm Host Controller điều phối quá trình suy luận của mạng nơ-ron.
- **RISC-V GNU Toolchain (`riscv32-xilinx-elf-gcc`):** Trình biên dịch chéo (cross-compiler) được sử dụng để biên dịch firmware nhị phân chạy trên lõi PicoRV32. Đường dẫn mặc định trong Makefile: `/home/tam/Documents/app/2025.2.1/gnu/riscv/lin/x86_64-oesdk-linux/usr/bin/riscv32-xilinx-elf/riscv32-xilinx-elf-gcc`.

## 3. Lập trình Hệ thống (Processing System - PS)
- **Xilinx Vitis (Phiên bản 2025.2.1):** Môi trường phát triển phần mềm được sử dụng để viết mã C cho Zynq PS. Phần mềm trên PS chịu trách nhiệm giữ PicoRV32 ở reset, nạp firmware vào BRAM, tải dữ liệu mô hình vào DDR, release reset, đọc mailbox và in kết quả `PASS/FAIL`. Cài đặt hiện dùng trong máy: `/home/tam/Documents/app/2025.2.1/Vitis/bin/vitis`.

## 4. Huấn luyện Mô hình AI và Kịch bản tiện ích (Machine Learning & Utilities)
- **Python (Phiên bản 3.12.3):** Ngôn ngữ dùng cho các script tiện ích. Script `tools/export_raas_demo_data.py` xuất dữ liệu demo quyết định từ các vector MNIST fixed-point trong thư mục `references/`, đóng gói input/bias/weight đúng với RTL hiện tại và tạo golden output cho mô phỏng/board test.
- **C/C++:** Được sử dụng để viết các mã tham chiếu (reference code) nhằm xác thực thuật toán và kết quả suy luận trước khi triển khai trên phần cứng thực tế (thư mục `model/C/`).

## 5. Các chuẩn giao tiếp (Protocols/Interfaces)
- **Giao thức AXI (Advanced eXtensible Interface):** 
  - **AXI-Lite:** Dùng để cấu hình thanh ghi điều khiển cho MLP Accelerator và DMA.
  - **AXI-Stream:** Dùng để truyền nhận dữ liệu tốc độ cao giữa DMA và MLP Accelerator.
- **AXI Memory Mapped:** Dùng cho PicoRV32 và Zynq PS để truy cập bộ nhớ DDR4 và các ngoại vi thông qua hệ thống SmartConnect.

## 6. Bản đồ địa chỉ demo board hiện dùng
- **Accelerator:** `0x4000_0000`, thanh ghi hidden packing `slv_reg1 = 0x0010_0010`.
- **AXI DMA:** `0x4001_0000`.
- **Pico boot BRAM:** Pico thấy ở `0x0000_0000`, PS loader thấy ở `0xA000_0000`, kích thước 64 KB.
- **SW Reset:** PS điều khiển ở `0xA003_0000`, ghi `0` để giữ reset và `1` để release PicoRV32.
- **DDR buffers:** image `0x1000_0000`, biases `0x1000_1000`, weights `0x1000_2000`, hidden/final outputs `0x1010_0000`, `0x1010_0100`, `0x1010_0200`, mailbox `0x1010_1000`.
