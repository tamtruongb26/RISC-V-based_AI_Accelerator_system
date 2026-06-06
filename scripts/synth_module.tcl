# =============================================================================
# synth_module.tcl — OOC synthesis 1 module bất kỳ, report area.
# Dùng env: RAAS_TOP (tên module), RAAS_FILES (danh sách .v cách nhau space).
#   RAAS_TOP=ecc_secded RAAS_FILES="..../ecc_secded.v" \
#     vivado -mode batch -nojournal -nolog -source scripts/synth_module.tcl
# =============================================================================
set PART "xczu3eg-sbva484-1-i"
set TOP   $::env(RAAS_TOP)
set FILES $::env(RAAS_FILES)

create_project -in_memory -part $PART
foreach f $FILES { read_verilog $f }
synth_design -top $TOP -part $PART -mode out_of_context
puts "===== AREA: $TOP ====="
report_utilization
