# Xây Dựng Hệ Thống RAAS Từ Con Số 0

Tài liệu này trả lời câu hỏi: nếu phải tự xây lại đồ án RAAS từ đầu, ta làm
bước nào trước, bước nào sau, vì sao thứ tự đó hợp lý, và mỗi bước tạo ra
artifact gì cho bước kế tiếp.

Đây không phải là lộ trình đọc code. Đây là lộ trình thiết kế một hệ thống
hardware/software co-design gồm mô hình MLP, accelerator RTL, AXI, DMA,
PicoRV32 firmware, Zynq PS boot app và demo board Ultra96v2.

## 0. Sơ Đồ Xây Dựng Từ Thuật Toán Đến Board Demo

```text
Bài toán MNIST
    |
    v
Reference model Python/C
    |  tạo golden output, sigmoid behavior, expected digit
    v
Fixed-point + packing contract
    |  Q1.4.11, 32-bit word [B|A], weight/bias order
    v
Accelerator core RTL
    |  BRAM + MAC + sigmoid LUT + FSM, chưa cần full system
    v
AXI accelerator IP
    |  AXI-Lite register control + AXI-Stream data in/out
    v
Memory map + DDR layout
    |  base address, buffer address, mailbox protocol
    v
DMA transfer sequence
    |  MM2S input/bias/weight, S2MM layer outputs
    v
PicoRV32 firmware
    |  configure accelerator, schedule DMA, argmax, write mailbox
    v
Boot BRAM + SW reset
    |  PS can load firmware first, then release Pico
    v
Zynq PS app
    |  preload data, copy firmware, poll mailbox, print PASS/FAIL
    v
Vivado block design + Vitis build
    |  integrate PS, Pico, DMA, accelerator, BRAM, reset, DDR
    v
XSIM + board verification
```

Sơ đồ hệ thống khi chạy trên board:

```text
          control/load path                          data path

Zynq PS ---------------------> Boot BRAM <---------------- PicoRV32
   |                               ^                           |
   | copy firmware                 | fetch instruction          | AXI-Lite config
   | preload DDR                   |                           v
   | release reset             SW Reset                  MLP Accelerator
   | poll mailbox                                             ^     |
   v                                                          |     v
DDR image/bias/weight/output/mailbox <---- AXI DMA ---- AXI-Stream in/out
```

## 1. Hợp Đồng Hệ Thống Cuối Cùng

Trước khi viết code, cần đóng băng mục tiêu hệ thống:

- Bài toán: nhận một ảnh MNIST, chạy MLP `784 -> 16 -> 16 -> 10`, trả ra chữ số dự đoán.
- Board: Ultra96v2, dùng Zynq UltraScale+ MPSoC.
- Zynq PS: boot hệ thống, nạp firmware PicoRV32, nạp dữ liệu demo vào DDR, poll mailbox.
- PicoRV32: host controller trong PL, cấu hình accelerator và AXI DMA.
- MLP accelerator: tính toán mạng neural network bằng fixed-point.
- AXI DMA: chuyển dữ liệu giữa DDR và accelerator qua AXI-Stream.
- DDR: chứa image, bias, weight, hidden output, final output và mailbox.
- Boot BRAM: chứa firmware để PicoRV32 chạy từ reset vector `0x00000000`.

Nếu chưa có hợp đồng này, không nên bắt đầu viết RTL hoặc firmware. Lý do là
mọi phần sau đều phụ thuộc vào câu trả lời "ai điều khiển ai", "dữ liệu nằm ở
đâu", và "khối nào giao tiếp với khối nào".

## 2. Chuỗi Phụ Thuộc Thiết Kế

| Bước | Artifact tạo ra | Vì sao phải làm ở đây | Bước sau dùng gì |
|---|---|---|---|
| 1. Định nghĩa bài toán và kiến trúc | Sơ đồ khối, vai trò PS/Pico/DMA/accelerator | Chưa biết kiến trúc thì chưa thể chia phần cứng và phần mềm | Tất cả khối lấy sơ đồ này làm hợp đồng |
| 2. Mô hình tham chiếu | Python/C reference, golden output | RTL cần biết thuật toán đúng là gì | Testbench và board demo so với golden |
| 3. Fixed-point và packing | `Q1.4.11`, word `[B \| A]`, thứ tự weight/bias | Bit width và layout dữ liệu phải cố định trước khi viết datapath | RTL, DMA transfer và firmware dùng chung |
| 4. Accelerator core thuần RTL | MAC, sigmoid LUT, BRAM, FSM nội bộ | Phải chứng minh phần tính toán đúng trước khi thêm bus | AXI wrapper bọc core đã ổn định |
| 5. AXI wrapper cho accelerator | AXI-Lite register map, AXI-Stream in/out | CPU và DMA cần interface chuẩn để nói chuyện với accelerator | Firmware cấu hình register và DMA stream dữ liệu |
| 6. Memory map và DDR layout | Base address, buffer address, mailbox layout | Firmware chỉ là đọc/ghi địa chỉ, nên địa chỉ phải ổn định trước | Pico firmware, PS app, simulation dùng chung |
| 7. DMA sequence | Thứ tự MM2S/S2MM theo từng layer | Accelerator nhận stream, nên phải định nghĩa stream order chính xác | Pico firmware hiện thực sequence |
| 8. Firmware PicoRV32 | Bare-metal firmware chạy từ BRAM | Firmware cần register map, DMA map và DDR layout đã chốt | PS app nhúng firmware binary |
| 9. Boot BRAM và reset | Linker script, BRAM mapping, SW reset | Pico phải có nơi fetch instruction và phải chạy sau khi PS nạp xong | PS app copy firmware rồi release reset |
| 10. PS app | Boot loader, data loader, mailbox poll, PASS/FAIL | PS app cần firmware binary và mailbox protocol | Board demo hoàn chỉnh |
| 11. Vivado block design và verification | Bitstream, XSA, test logs | Chỉ ghép full system khi interface từng khối đã rõ | Demo board và bảo vệ đồ án |

## 3. Quy Trình Xây Dựng Theo Tầng

### Bước 1: Định Nghĩa Bài Toán Và Kiến Trúc Đích

Artifact cần tạo:

- Một block diagram có PS, PicoRV32, SmartConnect, AXI DMA, accelerator, DDR, boot BRAM, SW reset.
- Một bảng vai trò từng khối.
- Một quyết định rõ: PS chỉ boot/demo, PicoRV32 mới là host controller chính trong PL.

Lý do làm đầu tiên:

- Nếu PS cũng điều phối inference thì firmware PicoRV32 không còn là trung tâm.
- Nếu không dùng DMA thì accelerator phải nhận dữ liệu bằng register hoặc CPU copy từng word, vừa chậm vừa làm sai mục tiêu tăng tốc phần cứng.
- Nếu không có DDR layout thì cả DMA và firmware không có hợp đồng dữ liệu.

Milestone đạt yêu cầu:

- Có thể kể bằng lời: PS giữ Pico reset, PS nạp firmware và data, PS release reset, Pico cấu hình DMA/accelerator, accelerator chạy MLP, Pico ghi mailbox, PS in kết quả.

### Bước 2: Làm Mô Hình Thuật Toán Tham Chiếu

Artifact cần tạo:

- MLP reference bằng Python hoặc C.
- Hàm sigmoid tương đương phần cứng.
- Bộ dữ liệu gồm image, bias, weight và golden output.
- Script export dữ liệu sang C header và file `.mem` cho simulation.

Trong repo hiện tại, artifact tương ứng là:

- `tools/export_raas_demo_data.py`
- `sw/common/raas_demo_data.h`
- `build/sim/data/raas_demo_image.mem`
- `build/sim/data/raas_demo_bias.mem`
- `build/sim/data/raas_demo_weight.mem`
- `build/sim/data/raas_demo_golden.mem`

Lý do phải làm trước RTL:

- RTL không nên định nghĩa thuật toán bằng cảm tính. Nó cần target output để so.
- Fixed-point, saturation và lookup sigmoid rất dễ lệch 1 bit. Nếu không có golden output, board demo sai cũng không biết sai ở đâu.

Milestone đạt yêu cầu:

- Chạy script export dữ liệu và biết image nào được chọn, expected digit là gì, golden packed score là gì.

### Bước 3: Đóng Băng Fixed-Point Và Packing

Quyết định dữ liệu:

- Input, bias, weight dùng 16-bit fixed-point `Q1.4.11`.
- Mỗi AXI-Stream word rộng 32 bit.
- Mỗi word chứa hai giá trị 16 bit: `[value_portB | value_portA]`.
- Accelerator tính hai neuron song song, tương ứng port A và port B.

Quyết định weight layout:

- Weight được nhóm theo layer.
- Trong mỗi layer, weight được nhóm theo neuron pair.
- Trong mỗi neuron pair, stream `previous_layer_size` word.
- Mỗi word là `[weight_neuronB_i | weight_neuronA_i]`.

Lý do phải làm trước accelerator:

- BRAM width, địa chỉ BRAM, số transfer DMA và FSM load dữ liệu đều phụ thuộc vào packing.
- Nếu thay packing sau khi viết RTL, phải sửa cả datapath, testbench, firmware và PS data loader.

Milestone đạt yêu cầu:

- Có thể tự tính: image `784` pixel thành `392` word, hidden `16` node thành `8` word, output `10` node thành `5` word.

### Bước 4: Thiết Kế Accelerator Core Thuần RTL

Nên xây core trước khi nghĩ tới Vivado IP Integrator:

- Input BRAM.
- Bias BRAM.
- Weight BRAM.
- Output BRAM.
- Neuron MAC.
- Saturation.
- Sigmoid lookup table.
- FSM load input, load bias, load weight, compute, store result, send output.

Lý do chưa thêm AXI ngay:

- Nếu core sai, AXI không giúp gì mà chỉ che lỗi.
- Test một core đơn giản dễ hơn test full AXI system.
- Sau khi core đúng, AXI chỉ là lớp vận chuyển dữ liệu.

Milestone đạt yêu cầu:

- Testbench có thể feed image/bias/weight vào core và so final output với golden.

### Bước 5: Bọc Accelerator Thành AXI IP

Sau khi core đúng, thêm interface hệ thống:

- AXI-Lite slave cho register cấu hình.
- AXI-Stream slave để nhận data từ DMA MM2S.
- AXI-Stream master để xuất output về DMA S2MM.

Register contract:

| Offset | Ý nghĩa |
|---|---|
| `0x00` | Input layer nodes, hiện tại `784` |
| `0x04` | Hidden nodes packed `[H2 | H1]`, hiện tại `0x00100010` |
| `0x08` | Output nodes, hiện tại `10` |
| `0x0C` | Control: bit 0 `NN_EN`, bit 1 `DATA_RDY` |
| `0x10` | Status: bit 0 `BSY` |

Lý do AXI-Lite và AXI-Stream tách nhau:

- AXI-Lite phù hợp cho register cấu hình ít dữ liệu.
- AXI-Stream phù hợp cho luồng dữ liệu liên tục image/bias/weight/output.
- DMA tự nhiên nối DDR memory-mapped với AXI-Stream.

Milestone đạt yêu cầu:

- AXI testbench ghi register, stream dữ liệu vào, bắt output stream ra, so với golden.

### Bước 6: Thiết Kế Memory Map Và DDR Layout

Source of truth trong repo hiện tại là `sw/common/raas_memory_map.h`.

Memory map chính:

| Region | Address | Chủ sở hữu |
|---|---:|---|
| Pico boot BRAM, Pico view | `0x00000000` | PicoRV32 fetch instruction |
| Pico boot BRAM, PS view | `0xA0000000` | PS copy firmware |
| Accelerator AXI-Lite | `0x40000000` | PicoRV32 cấu hình inference |
| AXI DMA | `0x40010000` | PicoRV32 lập lịch DMA |
| SW reset | `0xA0030000` | PS giữ/release Pico reset |
| DDR image | `0x10000000` | Input image |
| DDR biases | `0x10001000` | Bias words |
| DDR weights | `0x10002000` | Weight words |
| DDR hidden1 | `0x10100000` | Output layer hidden 1 |
| DDR hidden2 | `0x10100100` | Output layer hidden 2 |
| DDR final output | `0x10100200` | Final score words |
| DDR mailbox | `0x10101000` | Pico báo trạng thái cho PS |

DDR layout:

| Buffer | Word count | Byte count | Nội dung |
|---|---:|---:|---|
| Image | `392` | `1568` | `784` pixel packed hai pixel mỗi word |
| Bias | `21` | `84` | `16 + 16 + 10` bias packed theo pair |
| Weight | `6480` | `25920` | Layer 1 `6272`, layer 2 `128`, output `80` word |
| Hidden 1 | `8` | `32` | `16` output hidden1 packed |
| Hidden 2 | `8` | `32` | `16` output hidden2 packed |
| Final output | `5` | `20` | `10` score packed |
| Mailbox | `20` | `80` | magic, state, error, predicted, expected, image index, final words |

Lý do bước này đứng trước firmware:

- Firmware chỉ biết ghi/đọc địa chỉ. Nếu địa chỉ còn thay đổi, firmware không thể ổn định.
- PS app, Pico firmware, testbench và tài liệu đều phải dùng cùng một layout.

Milestone đạt yêu cầu:

- Có thể nhìn một địa chỉ DDR và biết nó là input, weight, output hay mailbox.

### Bước 7: Thiết Kế DMA Transfer Sequence

DMA có hai kênh chính:

- MM2S: đọc DDR rồi stream vào accelerator.
- S2MM: nhận stream từ accelerator rồi ghi về DDR.

Một layer luôn chạy theo pattern:

1. Start S2MM trước, trỏ đến output buffer của layer.
2. MM2S gửi input buffer của layer.
3. Với mỗi neuron pair, MM2S gửi 1 bias word.
4. Với mỗi neuron pair, MM2S gửi `previous_nodes` weight word.
5. Wait S2MM idle để chắc output layer đã ghi xong.

Lý do start S2MM trước:

- Khi accelerator xuất kết quả, DMA receive path phải sẵn sàng.
- Nếu S2MM chưa sẵn sàng, stream output có thể bị stall hoặc timeout.

DMA sequence cụ thể:

| Layer | Input source | Input words | Output dest | Output words | Pair count | Bias offset | Weight offset |
|---|---|---:|---|---:|---:|---:|---:|
| Hidden 1 | `0x10000000` image | `392` | `0x10100000` | `8` | `8` | `0..7` | `0..6271`, 8 groups x 784 |
| Hidden 2 | `0x10100000` hidden1 | `8` | `0x10100100` | `8` | `8` | `8..15` | `6272..6399`, 8 groups x 16 |
| Output | `0x10100100` hidden2 | `8` | `0x10100200` | `5` | `5` | `16..20` | `6400..6479`, 5 groups x 16 |

Milestone đạt yêu cầu:

- Có thể viết pseudo-code `stream_layer(input_addr, input_words, output_addr, output_words, previous_nodes, bias_offset, weight_offset)`.

### Bước 8: Viết Firmware PicoRV32

Firmware PicoRV32 nên được xây theo các mốc tăng dần:

1. Firmware tối thiểu ghi `RUNNING` vào mailbox.
2. Thêm ghi register accelerator: input nodes, hidden nodes, output nodes, control.
3. Thêm reset và start AXI DMA.
4. Thêm `stream_layer` cho hidden 1.
5. Thêm hidden 2 và output layer.
6. Thêm đọc final output, argmax, ghi `DONE` hoặc `ERROR`.

Lý do Pico firmware đứng sau DMA/memory map:

- Firmware cần biết base address của accelerator, DMA và DDR.
- Firmware cần biết số word mỗi transfer.
- Firmware cần biết mailbox protocol để báo kết quả cho PS.

Artifact cần tạo:

- `startup.S` để khởi động bare-metal.
- `linker.ld` để link firmware vào boot BRAM `0x00000000`.
- `main.c` chứa DMA sequence và mailbox protocol.
- Makefile dùng RISC-V cross compiler tạo `.elf`, `.bin`, `.lst`.

Milestone đạt yêu cầu:

- `make -C sw/picorv32` tạo firmware binary và header để PS app nhúng.

### Bước 9: Tích Hợp PicoRV32, Boot BRAM Và SW Reset

PicoRV32 cần ba thứ để chạy được:

- Instruction memory: boot BRAM ở Pico view `0x00000000`.
- Loader path: PS view của cùng BRAM ở `0xA0000000`.
- Reset control: SW reset để PS giữ Pico dừng trong lúc copy firmware.

Boot sequence đúng:

1. PS ghi `0` vào SW reset để giữ PicoRV32 trong reset.
2. PS xóa boot BRAM.
3. PS copy firmware binary vào boot BRAM qua địa chỉ `0xA0000000`.
4. PS flush cache nếu vùng ghi có cache.
5. PS preload DDR image/bias/weight/output/mailbox.
6. PS ghi `1` vào SW reset để release PicoRV32.
7. Pico fetch instruction từ `0x00000000`.

Lý do cần reset:

- Nếu Pico chạy trước khi firmware được copy, reset vector sẽ đọc rác hoặc chương trình cũ.
- Reset cho phép PS kiểm soát thời điểm bắt đầu demo.

Milestone đạt yêu cầu:

- Pico firmware nhỏ có thể boot và ghi mailbox, chưa cần chạy full accelerator.

### Bước 10: Viết PS App Để Boot Và Kiểm Tra

PS app không nên điều phối inference. PS app chỉ chuẩn bị và quan sát:

- Hold Pico reset.
- Copy Pico firmware vào boot BRAM.
- Preload image, bias, weight vào DDR.
- Zero hidden/output/mailbox.
- Ghi expected label và image index vào mailbox.
- Release Pico reset.
- Poll mailbox.
- So final words với golden output.
- In `RAAS PASS` hoặc `RAAS FAIL`.

Lý do PS app đứng sau Pico firmware:

- PS app cần nhúng `pico_firmware_image.h`.
- PS app cần biết mailbox struct mà Pico firmware sẽ ghi.
- PS app cần biết generated demo data từ reference model.

Milestone đạt yêu cầu:

- PS console in được mailbox state, predicted digit, golden score và PASS/FAIL.

### Bước 11: Tích Hợp Vivado Block Design

Chỉ ghép block design đầy đủ khi các contract đã ổn định:

- Zynq PS.
- SmartConnect.
- PicoRV32 IP.
- AXI DMA.
- MLP accelerator IP.
- Boot BRAM.
- SW reset IP.
- DDR qua PS HP port.

Thứ tự tích hợp khuyến nghị:

1. Package accelerator IP với AXI-Lite và AXI-Stream.
2. Package SW reset IP.
3. Package PicoRV32 Vivado IP.
4. Tạo block design tối thiểu PS + BRAM + reset + Pico.
5. Thêm accelerator AXI-Lite path.
6. Thêm DMA và AXI-Stream path.
7. Thêm HP port DDR path.
8. Assign address map.
9. Generate bitstream và export hardware cho Vitis.

Lý do tích hợp muộn:

- Full block design có nhiều nguồn lỗi: clock, reset, address decode, AXI handshake, cache, DMA, firmware.
- Nếu từng khối chưa được kiểm chứng, board fail sẽ rất khó truy nguyên.

Milestone đạt yêu cầu:

- Bitstream và hardware handoff có thể dùng để build Vitis app.

## 4. Verification Theo Tầng

Không debug từ board trước. Debug từ tầng thấp lên:

| Tầng | Kiểm tra | Dấu hiệu pass |
|---|---|---|
| Reference model | Chạy export script | Sinh được `raas_demo_data.h` và `build/sim/data/raas_demo_*.mem` |
| Fixed-point data | Kiểm tra word count và packing | Image 392 word, bias 21 word, weight 6480 word, golden 5 word |
| Accelerator simulation | Chạy XSIM smoke test | `RAAS accelerator smoke PASS` |
| Pico firmware build | `make -C sw/picorv32` | Có `.elf`, `.bin`, `.lst`, `pico_firmware_image.h` |
| PS loader | Build Vitis app | Firmware size nhỏ hơn 64 KB, data preload đúng |
| Board demo | Chạy trên Ultra96v2 | Mailbox `DONE`, predicted đúng expected, score match golden |

Các lệnh kiểm thử chính:

```sh
python3 tools/export_raas_demo_data.py
make -C sw/picorv32
/home/tam/Documents/app/2025.2.1/Vivado/bin/vivado -mode batch -source script/02_run_smoke_sim.tcl
```

## 5. Debug Checklist

| Hiện tượng | Tầng nên kiểm tra trước | Nguyên nhân thường gặp |
|---|---|---|
| Export script fail | Reference data | Thiếu reference files, sigmoid ROM không đủ 1024 entry, sai tên array |
| XSIM final mismatch | RTL core hoặc fixed-point | Sai saturation, sigmoid address, packing `[B \| A]`, weight order |
| XSIM timeout output | AXI-Stream/FSM | Accelerator không assert output valid, FSM kẹt load weight/input |
| Firmware quá lớn | Pico build/link | Code vượt 64 KB boot BRAM, linker hoặc compiler flag sai |
| Mailbox không đổi | Boot/reset | PS chưa release reset, firmware chưa copy đúng BRAM, Pico không fetch được instruction |
| DMA MM2S error | DDR/source address | Sai source address, length, DMA chưa run, address map chưa route tới DDR |
| DMA S2MM timeout | Output stream | S2MM chưa start, accelerator không xuất output, TLAST/transfer count sai |
| Predicted sai nhưng firmware chạy hết | Data/RTL arithmetic | Golden data khác RTL, bias/weight offset sai, fixed-point lệch |
| Score mismatch trên board nhưng XSIM pass | PS cache hoặc data preload | Chưa flush/invalidate cache, Vitis app dùng header cũ |
| Board không boot demo | Vivado/Vitis handoff | Bitstream/XSA không khớp app, address map trong hardware khác header |

Quy tắc debug:

- Nếu fail ở tầng thấp, chưa lên tầng cao.
- Nếu mới sửa data format, chạy lại reference export và XSIM trước khi lên board.
- Nếu mới sửa address map, kiểm tra `raas_memory_map.h`, Vivado address editor, PS app và Pico firmware cùng lúc.
- Nếu mailbox không đổi, debug boot/reset trước DMA.
- Nếu mailbox báo DMA error, debug DMA register/status trước accelerator math.

## 6. Tài Liệu Cần Có Khi Bảo Vệ

Checklist tài liệu nên chuẩn bị:

- Sơ đồ xây dựng từ thuật toán đến board demo.
- Bảng phụ thuộc "bước trước tạo gì, bước sau dùng gì".
- Memory map và DDR layout.
- DMA transfer sequence cho hidden 1, hidden 2, output layer.
- Boot sequence PS/Pico.
- Verification ladder.
- Debug checklist.

Câu giải thích ngắn gọn cần nói được:

- Có reference model trước RTL để có golden output và khóa thuật toán.
- Khóa fixed-point và packing trước RTL vì datapath, BRAM, DMA và firmware đều phụ thuộc vào chúng.
- Accelerator cần AXI-Lite cho register cấu hình và AXI-Stream cho data path tốc độ cao.
- DMA được dùng để tránh CPU copy từng word và để nối DDR với stream accelerator.
- PicoRV32 tồn tại vì đồ án muốn RISC-V soft-core trong PL làm host controller.
- Boot BRAM cần thiết vì Pico cần instruction memory ngay sau reset.
- SW reset cần thiết để PS nạp firmware xong rồi mới cho Pico chạy.
- PS app chỉ boot/demo, còn Pico firmware mới điều phối inference.
- Debug phải đi từ reference, RTL, firmware, PS loader, rồi mới board.

## 7. Định Nghĩa Hoàn Thành

Bạn đã hiểu cách xây hệ thống khi có thể tự trả lời:

- Nếu bắt đầu từ file trắng, bước đầu tiên cần quyết định gì?
- Vì sao chưa nên mở Vivado block design ngay từ ngày đầu?
- Dữ liệu image, bias, weight được tạo ra ở đâu và đi qua hệ thống như thế nào?
- Một layer MLP biến thành bao nhiêu DMA transfer?
- PicoRV32 cần biết những địa chỉ nào để điều phối inference?
- PS cần làm gì trước khi release reset Pico?
- Nếu demo board fail, debug từ tầng nào trước?

Khi trả lời được các câu này, bạn không chỉ "đọc hiểu code RAAS", mà đã hiểu
logic kỹ thuật để xây ra hệ thống RAAS.
