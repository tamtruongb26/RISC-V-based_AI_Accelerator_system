# =============================================================================
# check_phase0.tcl — Quick syntax + elaboration check cho HDL Phase 0
#
# Mục đích: Verify rằng các thay đổi HDL Phase 0 (counter + register pack)
# pass syntax check và elaboration trong Vivado, chưa cần synth/impl đầy đủ.
#
# Usage:
#   source /home/tam/Documents/app/2025.2.1/Vivado/settings64.sh
#   vivado -mode batch -nojournal -nolog -source scripts/check_phase0.tcl
#
# Output:
#   - Console: lỗi parse/elab nếu có
#   - report_messages.log: tổng kết tất cả messages
# =============================================================================

set HDL_DIR "/home/tam/Documents/RAAS/hw/accelerator_2_0/hdl"
set PART    "xczu3eg-sbva484-1-i"

# ── Step 1: Tạo project tạm trong RAM ──────────────────────────────────
create_project phase0_check /tmp/phase0_check -part $PART -force

# ── Step 2: Add HDL sources ────────────────────────────────────────────
add_files -norecurse [list \
    $HDL_DIR/pe.v \
    $HDL_DIR/data_path.v \
    $HDL_DIR/sigmoid_lookup.v \
    $HDL_DIR/post_proc.v \
    $HDL_DIR/control_unit.v \
    $HDL_DIR/accelerator_slave_lite_v2_0_S00_AXI.v \
    $HDL_DIR/accelerator_slave_stream_v2_0_S00_AXIS.v \
    $HDL_DIR/accelerator_master_stream_v2_0_M00_AXIS.v \
    $HDL_DIR/accelerator.v \
]

# Sigmoid ROM init file
add_files -norecurse $HDL_DIR/sigmoid_rom.mem
set_property file_type {Memory Initialization Files} \
    [get_files $HDL_DIR/sigmoid_rom.mem]

# ── Step 3: Set top module ─────────────────────────────────────────────
set_property top accelerator [current_fileset]

# ── Step 4: Update compile order (sẽ catch missing modules) ────────────
puts "==================== Update compile order ===================="
update_compile_order -fileset sources_1

# ── Step 5: Run elaboration only (không full synth, nhanh hơn) ─────────
puts "==================== Elaborate design ===================="
if {[catch {synth_design -top accelerator -part $PART -rtl -mode out_of_context} err]} {
    puts "ELABORATION FAILED: $err"
    exit 1
}

# ── Step 6: Report messages ────────────────────────────────────────────
puts "==================== Message summary ===================="
report_messages -severity {CRITICAL WARNING} -file /tmp/phase0_check/phase0_messages.log
report_messages -severity {ERROR}
puts "Full message log: /tmp/phase0_check/phase0_messages.log"

# ── Step 7: Report DRC (basic checks) ──────────────────────────────────
puts "==================== DRC summary ===================="
if {[catch {report_drc -name phase0_drc -file /tmp/phase0_check/phase0_drc.log} err]} {
    puts "DRC report skipped (chưa có placed design): $err"
}

puts ""
puts "==================== PHASE 0 CHECK COMPLETE ===================="
puts "Project: /tmp/phase0_check"
puts "Logs:    /tmp/phase0_check/phase0_messages.log"

close_project
