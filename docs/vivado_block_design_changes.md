# Vivado Block Design Changes — Phase 0

> Các thay đổi cần làm trong Vivado IP Integrator (block design) sau khi đã cập nhật HDL.
> File này không thể tự động hóa hoàn toàn — user cần thực hiện thủ công hoặc thông qua TCL script
> trong Vivado (xem `scripts/build_bd.tcl` nếu có).

## Tóm tắt

Phase 0 không thay đổi I/O ports của `accelerator` IP — chỉ thay đổi internal register layout.
Tuy nhiên các thay đổi sau đây ở block design **cần thiết để đo được baseline metrics**:

1. **Re-package accelerator IP** sau khi sửa HDL (slave_lite + accelerator.v + control_unit.v + data_path.v).
2. **Thêm AXI Timer IP** — cho cycle counting độc lập (cross-check Pico `rdcycle`).
3. **Thêm AXI Performance Monitor (APM) IP** — đo DDR bandwidth + AXI transaction count.
4. (Phase 0 stretch) **Thêm AXI Interrupt Controller** — chuẩn bị cho Phase 0 IRQ task tiếp theo.

## 1. Re-package Accelerator IP

Sau khi sửa các file HDL của Phase 0, **bắt buộc** re-package IP để Vivado pick up thay đổi:

```tcl
# Trong Vivado TCL Console (ở project gốc accelerator_2_0):
ipx::edit_ip_in_project -upgrade true -name edit_ip_project \
    -directory /tmp/edit_accel \
    {/home/tam/Documents/RAAS/hw/accelerator_2_0/component.xml}

# Re-import HDL sources nếu IP packager hỏi
ipx::merge_project_changes files [ipx::current_core]
ipx::merge_project_changes hdl_parameters [ipx::current_core]

# Save + re-package
ipx::save_core [ipx::current_core]
close_project -delete
```

Hoặc qua GUI: **Tools → Create and Package New IP → Edit Existing IP** → chọn component.xml → File Groups → Merge changes from HDL → Re-package IP.

Sau đó trong project RAS:
```tcl
report_ip_status
upgrade_ip [get_ips accelerator_*]
```

→ Kiểm tra rằng IP version mới đã được pick up. Block design sẽ tự refresh.

### Kiểm tra port signatures không đổi

Sau re-package, các port AXI bên ngoài của accelerator IP **phải giữ nguyên**:
- `s00_axi` (AXI-Lite slave, 32-bit data, 5-bit addr)
- `s00_axis` (AXIS slave, 32-bit data)
- `m00_axis` (AXIS master, 32-bit data)
- Clock + resetn ports

→ Nếu Vivado báo port mismatch, kiểm tra rằng addr_width = 5 (chưa widening). Nếu đã thay đổi, BD wire sẽ break.

## 2. Thêm AXI Timer IP

**Mục đích:** Cycle counter độc lập, có thể đọc qua AXI từ PS hoặc PicoRV32. Cross-check số `rdcycle` từ Pico.

### Steps trong BD

1. Add IP: **AXI Timer** (`xilinx.com:ip:axi_timer:2.0`).
2. Customize: chọn "Configurable Timer Pair", 32-bit, clock = `s_axi_aclk` (PL fabric clock).
3. Connect:
   - `s_axi` → AXI SmartConnect master port (cấp 1 master port mới nếu cần).
   - `s_axi_aclk` → PL fabric clock (100 MHz).
   - `s_axi_aresetn` → ps_reset interconnect_aresetn.
4. Address Editor: assign 64KB tại `0x4002_0000` (PicoRV32 view).
   **CHỈ map trong Pico view** — KHÔNG map trong PS view. Lý do: Vivado sẽ báo "BD 41-1267 related address spaces" nếu map cả 2 master với offset khác nhau. Pico là consumer duy nhất → đủ.

### Address constant cần thêm vào `sw/common/raas_map.h`

```c
#define RAAS_PICO_TIMER_BASE     0x40020000u
/* PS không cần access trực tiếp — Pico ghi kết quả vào mailbox */
```

(Đã có macros cơ bản trong header — sẽ thêm trong Phase 0 round 2.)

## 3. Thêm AXI Performance Monitor (APM) IP

**Mục đích:** Đo throughput + transaction count trên AXI buses (DMA → DDR, accelerator → DDR, etc.).

### Steps trong BD

1. Add IP: **AXI Performance Monitor** (`xilinx.com:ip:axi_perf_mon:5.0`).
2. Customize:
   - Mode: **Profile** (đo throughput + latency + transaction count).
   - Number of monitor slots: 2 (1 cho MM2S, 1 cho S2MM).
   - Enable Read Latency + Write Latency.
3. Connect monitor slots:
   - Slot 0: tap vào AXI master interface của DMA MM2S (hoặc PS HP0 input — để đo total DDR read traffic).
   - Slot 1: tap vào AXI master interface của DMA S2MM.
4. Connect `s_axi` của APM tới SmartConnect (cho PS/Pico đọc counter).
5. Connect `s_axi_aclk`, `s_axi_aresetn`.
6. Address Editor: assign 64KB tại `0x4003_0000` (**Pico view ONLY**).
   Lý do giống Timer — tránh "related address spaces" warning.

### Sử dụng

Sau khi APM gắn vào, đọc counter qua MMIO. Xem [APM PG037](https://docs.xilinx.com/v/u/en-US/pg037_axi_perf_mon) cho register offsets.

Để đơn giản trong Phase 0, có thể chỉ đọc tổng byte read/write sau 1 inference rồi reset counter.

## 4. (Stretch) Thêm AXI Interrupt Controller

Chuẩn bị cho task IRQ wiring ở increment 2 của Phase 0.

### Steps trong BD

1. Add IP: **AXI Interrupt Controller** (`xilinx.com:ip:axi_intc:4.1`).
2. Customize: Number of interrupts = 4 (accelerator DONE + future expansion).
3. Connect:
   - `s_axi` → SmartConnect.
   - `intr` (input vector) → để trống bây giờ (sẽ wire accelerator.po_irq_done sau khi HDL được mở rộng — round 2 Phase 0).
   - `irq` (output) → PicoRV32 IRQ input port (nếu Pico IP đã enable IRQ support).
4. Address Editor: 64KB tại `0x4004_0000`.

**Lưu ý:** PicoRV32 IRQ support phải được enable ở IP wrapper. Xem PicoRV32 IP customization.

## 5. Build flow sau khi sửa BD

```tcl
# Validate BD
validate_bd_design

# Save BD
save_bd_design

# Re-generate wrapper
make_wrapper -files [get_files RAS.bd] -top
add_files -norecurse <path_to_wrapper>

# Re-synth + impl
launch_runs synth_1 -jobs 4
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
```

## 6. Xuất XSA cho Vitis

```tcl
write_hw_platform -fixed -include_bit -force -file <path>/RAS.xsa
```

Sau đó update Vitis workspace platform → rebuild PS app.

## 6.5 Lỗi BD validation thường gặp + cách fix

### `[BD 41-1267]` Slave segment mapped at different offsets

**Nguyên nhân**: Map cùng 1 slave vào cả Pico AND PS view với offset khác nhau. Vivado xem 2 master này là "related" (chia sẻ crossbar) → bắt buộc cùng offset.

**Fix**: Unmap khỏi 1 master. Phase 0 Timer/APM → chỉ giữ Pico view, unmap PS view.

```
Window → Address Editor → expand zynq_ultra_ps_e_0/Data
→ right-click axi_timer_0/S_AXI/Reg → Unmap Segment
→ right-click axi_perf_mon_0/S_AXI/Reg → Unmap Segment
```

### `[BD 41-1347]` PicoRV32 resetn connected to async reset

**Nguyên nhân**: `picorv32_0/resetn` nối với `sw_reset_0/po_sw_rstn` — async reset từ PS register. Best-practice là dùng sync reset từ `proc_sys_reset`.

**Đây là cảnh báo pre-existing**, đã có trước Phase 0. Chạy được trên board nhưng có timing risk.

**Fix (optional, nên làm sau Phase 0)**: Thêm `Utility Vector Logic` (AND 2-input) gộp `sw_reset` + `peripheral_aresetn`:

```
Add IP: Utility Vector Logic (AND, 1-bit, 2 inputs)
util_vector_logic_0/Op1 ← sw_reset_0/po_sw_rstn
util_vector_logic_0/Op2 ← proc_sys_reset_0/peripheral_aresetn
util_vector_logic_0/Res → picorv32_0/resetn
```

Pico chỉ release khi CẢ sw_reset (PS cho phép) VÀ peripheral_aresetn (clock stable) đều OK.

## 7. Sanity checks sau khi build

| Check | Cách verify |
|---|---|
| Bitstream sinh ra không có DRC violation | Vivado `report_drc` |
| Timing close 100 MHz | `report_timing_summary` → WNS ≥ 0 |
| Resource utilization fit | `report_utilization` < 100% |
| Address map không overlap | Address Editor visual check |
| `read_register(ACCEL_BASE + CFG)` trả về giá trị đúng | Vitis debug console |
| Đọc counter via CNT_SEL + CNT_VAL hoạt động | Pico smoke test |

## 8. Rollback nếu có sự cố

Nếu sau Phase 0 changes hardware không hoạt động:

1. `git stash` các thay đổi HDL.
2. Re-package IP (revert).
3. Reset BD changes (Vivado: Sources → revert BD).
4. Bitstream cũ vẫn còn trong `fpga/RAS.runs/impl_1/` — flash lại để verify hardware không bị hỏng.

## Cross-references

- HDL changes: `hw/accelerator_2_0/hdl/control_unit.v`, `data_path.v`, `accelerator.v`, `accelerator_slave_lite_v2_0_S00_AXI.v`
- Firmware changes: `sw/picorv32/include/accel.h`, `src/accel.c`, `sw/common/raas_map.h`, `sw/picorv32/src/lenet.c`
- Output measurement template: [baseline_metrics.md](baseline_metrics.md)
