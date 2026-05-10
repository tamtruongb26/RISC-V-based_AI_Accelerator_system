#==============================================================================
# run_data_path_tb.tcl
#
# Loads data_path testbench (TPU canonical 8x8 systolic) trong Vivado.
#
# Usage trong Vivado GUI Tcl Console:
#   source /home/tam/Documents/RAAS/hw/accelerator_2_0/scripts/run_data_path_tb.tcl
#
# Sau khi script chạy xong:
#   - Vivado mở behavioral simulation cho data_path_tb.
#   - Bấm "Run All" (hoặc gõ `run all` trong Tcl Console).
#   - Pass khi log có dòng: === ALL DATA_PATH TESTS PASSED ===
#==============================================================================

set repo_root  /home/tam/Documents/RAAS
set hdl_dir    $repo_root/hw/accelerator_2_0/hdl
set tb_dir     $repo_root/hw/accelerator_2_0/tb
set sim_root   $repo_root/hw/accelerator_2_0/sim_projects
set proj_dir   $sim_root/data_path_tb_proj
set proj_name  accel2_data_path_tb

# Đóng project hiện có nếu còn mở
if {[current_project -quiet] != ""} {
    close_project -quiet
}

# Tạo lại project sạch mỗi lần
file mkdir $sim_root
file delete -force $proj_dir
create_project $proj_name $proj_dir -part xczu3eg-sbva484-1-i -force

# Add HDL sources
add_files -fileset sources_1 $hdl_dir/pe.v
add_files -fileset sources_1 $hdl_dir/data_path.v

# Add testbench
add_files -fileset sim_1 $tb_dir/data_path_tb.sv

# Set tops
set_property top data_path     [get_filesets sources_1]
set_property top data_path_tb  [get_filesets sim_1]
set_property top_lib           xil_defaultlib [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Tăng simulation runtime cho user
set_property -name {xsim.simulate.runtime} -value {20us} -objects [get_filesets sim_1]

puts "INFO: Project tạo tại: $proj_dir"
puts "INFO: Đang launch behavioral simulation..."

launch_simulation -mode behavioral

puts ""
puts "=================================================================="
puts " data_path testbench đã load."
puts " - Bấm 'Run All' trên toolbar HOẶC gõ trong Tcl Console: run all"
puts " - Đọc log để thấy \[OK\]/\[FAIL\] từng case."
puts " - Pass khi cuối log có dòng: === ALL DATA_PATH TESTS PASSED ==="
puts "=================================================================="
