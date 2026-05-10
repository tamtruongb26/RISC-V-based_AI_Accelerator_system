#==============================================================================
# run_pe_tb.tcl
#
# Loads PE testbench in a fresh standalone Vivado simulation project
# (separate from Accelerator_v2_tb.xpr to avoid conflict with old broadcast pe.v).
#
# Usage trong Vivado GUI Tcl Console:
#   source /home/tam/Documents/RAAS/hw/accelerator_2_0/scripts/run_pe_tb.tcl
#
# Sau khi script chạy xong:
#   - Vivado mở waveform window cho pe_tb.
#   - Bấm "Run All" (hoặc gõ `run all` trong Tcl Console) để bắt đầu sim.
#   - Đọc log Tcl Console để thấy [OK]/[FAIL] từng check, kết quả cuối cùng
#     là "=== ALL PE TESTS PASSED ===" hoặc "=== <N> PE TEST FAILURES ===".
#==============================================================================

set repo_root  /home/tam/Documents/RAAS
set hdl_dir    $repo_root/hw/accelerator_2_0/hdl
set tb_dir     $repo_root/hw/accelerator_2_0/tb
set sim_root   $repo_root/hw/accelerator_2_0/sim_projects
set proj_dir   $sim_root/pe_tb_proj
set proj_name  accel2_pe_tb

# Đóng project hiện có nếu còn mở
if {[current_project -quiet] != ""} {
    close_project -quiet
}

# Tạo lại project sạch mỗi lần (delete + create)
file mkdir $sim_root
file delete -force $proj_dir
create_project $proj_name $proj_dir -part xczu3eg-sbva484-1-i -force

# Add HDL source (PE)
add_files -fileset sources_1 $hdl_dir/pe.v

# Add testbench
add_files -fileset sim_1 $tb_dir/pe_tb.sv

# Set tops
set_property top pe    [get_filesets sources_1]
set_property top pe_tb [get_filesets sim_1]
set_property top_lib   xil_defaultlib [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Tăng simulation runtime cho user (mặc định 1us, mình cần ~3us)
set_property -name {xsim.simulate.runtime} -value {5us} -objects [get_filesets sim_1]

puts "INFO: Project tạo tại: $proj_dir"
puts "INFO: Đang launch behavioral simulation..."

# Launch simulation
launch_simulation -mode behavioral

puts ""
puts "=================================================================="
puts " PE testbench đã load."
puts " - Bấm 'Run All' trên toolbar HOẶC gõ trong Tcl Console: run all"
puts " - Đọc log để thấy \[OK\]/\[FAIL\] từng check."
puts " - Pass khi cuối log có dòng: === ALL PE TESTS PASSED ==="
puts "=================================================================="
