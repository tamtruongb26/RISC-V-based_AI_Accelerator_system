# ============================================================================
# report_all.tcl — xuất toàn bộ report đánh giá sau implementation
#
# Dùng: SAU khi impl_1 xong (open_run impl_1), trong Vivado Tcl Console:
#   source /home/tam/Documents/RAAS/scripts/report_all.tcl
#
# Sinh ra (thư mục reports/): utilization, timing, power, drc + bản tóm tắt.
# → điền nhóm #3 (resource), #4 (timing), #5 (power) của evaluation_metrics.md.
# ============================================================================
set REPO /home/tam/Documents/RAAS
set OUT  $REPO/reports
file mkdir $OUT

# Mở impl run nếu chưa
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "WARNING: impl_1 chưa xong 100%. Chạy launch_runs impl_1 trước."
}
open_run impl_1 -quiet

puts "=== 1/5 Utilization ==="
report_utilization        -file $OUT/utilization.rpt
report_utilization -hierarchical -file $OUT/utilization_hier.rpt

puts "=== 2/5 Timing ==="
report_timing_summary     -file $OUT/timing_summary.rpt
report_timing -max_paths 10 -file $OUT/timing_critical.rpt

puts "=== 3/5 Power (vectorless estimate) ==="
report_power              -file $OUT/power.rpt

puts "=== 4/5 DRC ==="
report_drc                -file $OUT/drc.rpt

puts "=== 5/5 Tóm tắt nhanh ==="
set wns [get_property SLACK [lindex [get_timing_paths -max_paths 1 -nworst 1 -setup] 0]]
puts ""
puts "════════════════ XONG ════════════════"
puts "Reports tại: $OUT/"
puts "  utilization.rpt      → LUT/FF/DSP/BRAM (nhóm #3)"
puts "  utilization_hier.rpt → breakdown per-module (#3)"
puts "  timing_summary.rpt   → f_clk/WNS/TNS (#4)"
puts "  timing_critical.rpt  → critical path (#4)"
puts "  power.rpt            → static/dynamic power estimate (#5)"
puts "  drc.rpt              → design rule check"
puts "WNS = $wns ns (≥0 = timing closed)"
