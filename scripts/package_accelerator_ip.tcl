# ============================================================================
# package_accelerator_ip.tcl — đóng gói IP accelerator MỚI (có autonomy 2c)
#   với clock/reset association ĐẦY ĐỦ cho cả 4 interface.
#
# Dùng: Vivado Tcl Console (KHÔNG mở project nào):
#   cd /home/tam/Documents/RAAS
#   source scripts/package_accelerator_ip.tcl
#
# Sau đó: Settings → IP → Repository → Add $IPDIR → Refresh.
#   Trong BD: xoá block accelerator cũ, Add IP "RAAS Accelerator (autonomy)",
#   nối lại S00_AXI / S00_AXIS / M00_AXIS / M_AXI_DMA + clock/reset.
# ============================================================================
set REPO   /home/tam/Documents/RAAS
set HDL    $REPO/hw/accelerator_2_0/hdl
set IPNAME accelerator_auto
set IPDIR  $REPO/hw/$IPNAME
set PART   xczu3eg-sbva484-1-i

close_project -quiet
create_project -force pkg_$IPNAME /tmp/pkg_$IPNAME -part $PART

add_files -norecurse [glob $HDL/*.v]
add_files -norecurse $HDL/sigmoid_rom.mem
set_property file_type {Memory Initialization Files} [get_files $HDL/sigmoid_rom.mem]
set_property top accelerator [current_fileset]
update_compile_order -fileset sources_1

file mkdir $IPDIR
ipx::package_project -root_dir $IPDIR -vendor raas -library user \
    -taxonomy /UserIP -module accelerator -import_files -force

set core [ipx::current_core]
set_property name         $IPNAME $core
set_property version      1.0 $core
set_property display_name {RAAS Accelerator (autonomy)} $core
set_property description   {8x8 WS/OS systolic + im2col/pool + Phase2c autonomy} $core

# ── In ra tên interface Vivado tự nhận (để đối chiếu nếu lệnh dưới sai tên) ──
puts "=== Bus interfaces inferred ==="
foreach bi [ipx::get_bus_interfaces -of_objects $core] {
    puts "  [get_property name $bi]"
}

# ── Associate clock + reset cho TẤT CẢ interface (mấu chốt) ──
# Nếu tên interface in ra khác (vd hoa/thường), sửa cho khớp rồi chạy lại 4 dòng này.
ipx::associate_bus_interfaces -busif S00_AXI   -clock s00_axi_aclk  -reset s00_axi_aresetn  $core
ipx::associate_bus_interfaces -busif S00_AXIS  -clock s00_axis_aclk -reset s00_axis_aresetn $core
ipx::associate_bus_interfaces -busif M00_AXIS  -clock m00_axis_aclk -reset m00_axis_aresetn $core
ipx::associate_bus_interfaces -busif m_axi_dma -clock s00_axi_aclk  -reset s00_axi_aresetn  $core

ipx::create_xgui_files $core
ipx::update_checksums  $core
ipx::save_core         $core

puts "=== ĐÓNG GÓI XONG: $IPDIR ==="
puts "Tiếp: Settings→IP→Repository add $IPDIR, refresh catalog, dùng trong BD."
