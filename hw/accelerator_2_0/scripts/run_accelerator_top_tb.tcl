#==============================================================================
# run_accelerator_top_tb.tcl
#
# Loads accelerator_top_tb (end-to-end integration TB) trong Vivado.
#
# Usage trong Vivado GUI Tcl Console:
#   source /home/tam/Documents/RAAS/hw/accelerator_2_0/scripts/run_accelerator_top_tb.tcl
#
# Sau khi script chạy xong:
#   - Vivado mở behavioral simulation cho accelerator_top_tb.
#   - Bấm "Run All" (hoặc gõ `run all` trong Tcl Console).
#   - Pass khi log có dòng: === ALL ACCELERATOR TOP TESTS PASSED ===
#==============================================================================

set repo_root  /home/tam/Documents/RAAS
set hdl_dir    $repo_root/hw/accelerator_2_0/hdl
set tb_dir     $repo_root/hw/accelerator_2_0/tb
set sim_root   $repo_root/hw/accelerator_2_0/sim_projects
set proj_dir   $sim_root/accelerator_top_tb_proj
set proj_name  accel2_top_tb

if {[current_project -quiet] != ""} {
    close_project -quiet
}

file mkdir $sim_root
file delete -force $proj_dir
create_project $proj_name $proj_dir -part xczu3eg-sbva484-1-i -force

# Add HDL sources (tất cả 8 file Verilog)
foreach f [glob $hdl_dir/*.v] { add_files -fileset sources_1 $f }
add_files -fileset sources_1 -norecurse $hdl_dir/sigmoid_rom.mem
set_property file_type {Memory Initialization Files} [get_files $hdl_dir/sigmoid_rom.mem]

# Add testbench
add_files -fileset sim_1 $tb_dir/accelerator_top_tb.sv

# Set tops
set_property top accelerator         [get_filesets sources_1]
set_property top accelerator_top_tb  [get_filesets sim_1]
set_property top_lib                 xil_defaultlib [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Tăng simulation runtime (sweep 50 tile mất ~500us)
set_property -name {xsim.simulate.runtime} -value {3ms} -objects [get_filesets sim_1]

puts "INFO: Project tạo tại: $proj_dir"
puts "INFO: Đang launch behavioral simulation..."

launch_simulation -mode behavioral

puts ""
puts "=================================================================="
puts " accelerator_top testbench đã load."
puts " - Bấm 'Run All' trên toolbar HOẶC gõ trong Tcl Console: run all"
puts " - Sweep 50 tile mất ~30s sim time"
puts " - Pass khi cuối log có dòng: === ALL ACCELERATOR TOP TESTS PASSED ==="
puts "=================================================================="
