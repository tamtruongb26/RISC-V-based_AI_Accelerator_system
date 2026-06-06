# =============================================================================
# synth_accel.tcl — Out-of-context synthesis của accelerator IP.
#
# Mục đích: lấy số area (LUT/FF/DSP/BRAM) + timing (slack @100MHz) thật cho
# accelerator — nửa "verify offline" còn lại bên cạnh simulation. Dùng để:
#   - Xác nhận design fit ZU3EG + close timing 100MHz.
#   - Định lượng chi phí FF của multi-slot accumulator (trade Phase 1a-ii-B).
#   - Cho số "after" cho bảng ablation (so với v-baseline).
#
# Usage:
#   source /home/tam/Documents/app/2025.2.1/Vivado/settings64.sh
#   cd <repo>/build/synth_accel && \
#     vivado -mode batch -nojournal -nolog -source <repo>/scripts/synth_accel.tcl
#   (chạy trong build/synth_accel để $readmemh("sigmoid_rom.mem") tìm thấy file)
# =============================================================================

set REPO    "/home/tam/Documents/RAAS"
# HDL_DIR override được qua env RAAS_HDL_DIR (để synth v-baseline vs v-phase1a)
if {[info exists ::env(RAAS_HDL_DIR)]} {
    set HDL_DIR $::env(RAAS_HDL_DIR)
} else {
    set HDL_DIR "$REPO/hw/accelerator_2_0/hdl"
}
set PART    "xczu3eg-sbva484-1-i"
set CLK_NS  10.0    ;# 100 MHz

# ── In-memory project ──────────────────────────────────────────────────
create_project -in_memory -part $PART

# Đọc toàn bộ HDL nguồn của accelerator
foreach f [glob $HDL_DIR/*.v] {
    read_verilog $f
}

# ── Synthesize OOC (top = accelerator) ─────────────────────────────────
synth_design -top accelerator -part $PART -mode out_of_context

# ── Timing constraint: 100 MHz trên 3 clock port (cùng clock) ──────────
foreach clkport {s00_axi_aclk s00_axis_aclk m00_axis_aclk} {
    if {[llength [get_ports -quiet $clkport]] > 0} {
        create_clock -name $clkport -period $CLK_NS [get_ports $clkport]
    }
}

# ── Reports ────────────────────────────────────────────────────────────
puts "\n================= UTILIZATION ================="
report_utilization
puts "\n================= TIMING SUMMARY ================="
report_timing_summary -delay_type max -max_paths 1 -nworst 1

# Ghi file để xem lại
report_utilization      -file utilization.rpt
report_timing_summary   -file timing.rpt
puts "\n[synth_accel] done — reports: build/synth_accel/{utilization,timing}.rpt"
