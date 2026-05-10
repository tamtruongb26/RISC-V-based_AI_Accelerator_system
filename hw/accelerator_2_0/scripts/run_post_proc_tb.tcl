#==============================================================================
# run_post_proc_tb.tcl
#
# Loads post_proc + sigmoid_lookup testbench trong Vivado.
#
# Usage trong Vivado GUI Tcl Console:
#   source /home/tam/Documents/RAAS/hw/accelerator_2_0/scripts/run_post_proc_tb.tcl
#
# Sau khi script chạy xong:
#   - Vivado mở behavioral simulation cho post_proc_tb.
#   - Bấm "Run All" (hoặc gõ `run all` trong Tcl Console).
#   - Pass khi log có dòng: === ALL POST_PROC TESTS PASSED ===
#==============================================================================

set repo_root  /home/tam/Documents/RAAS
set hdl_dir    $repo_root/hw/accelerator_2_0/hdl
set tb_dir     $repo_root/hw/accelerator_2_0/tb
set sim_root   $repo_root/hw/accelerator_2_0/sim_projects
set proj_dir   $sim_root/post_proc_tb_proj
set proj_name  accel2_post_proc_tb

# Đóng project hiện có nếu còn mở
if {[current_project -quiet] != ""} {
    close_project -quiet
}

# Tạo lại project sạch mỗi lần
file mkdir $sim_root
file delete -force $proj_dir
create_project $proj_name $proj_dir -part xczu3eg-sbva484-1-i -force

# Add HDL sources
add_files -fileset sources_1 $hdl_dir/sigmoid_lookup.v
add_files -fileset sources_1 $hdl_dir/post_proc.v
add_files -fileset sources_1 -norecurse $hdl_dir/sigmoid_rom.mem
set_property file_type {Memory Initialization Files} [get_files $hdl_dir/sigmoid_rom.mem]

# Add testbench
add_files -fileset sim_1 $tb_dir/post_proc_tb.sv

# Set tops
set_property top post_proc      [get_filesets sources_1]
set_property top post_proc_tb   [get_filesets sim_1]
set_property top_lib            xil_defaultlib [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Tăng simulation runtime
set_property -name {xsim.simulate.runtime} -value {5us} -objects [get_filesets sim_1]

puts "INFO: Project tạo tại: $proj_dir"
puts "INFO: Đang launch behavioral simulation..."

launch_simulation -mode behavioral

puts ""
puts "=================================================================="
puts " post_proc testbench đã load."
puts " - Bấm 'Run All' trên toolbar HOẶC gõ trong Tcl Console: run all"
puts " - Đọc log để thấy \[OK\]/\[FAIL\] từng case."
puts " - Pass khi cuối log có dòng: === ALL POST_PROC TESTS PASSED ==="
puts "=================================================================="