# =============================================================================
# jtag_smoketest.tcl — Automated XSDB JTAG Debug Script for RAAS Project
#
# Description:
#   This TCL script automates the JTAG target connection, FPGA bitstream programming,
#   PS architecture initialization (clocks/DDR), and application ELF downloading
#   for the Ultra96-v2 board using Xilinx System Debugger (XSDB).
#
# Usage:
#   1. Connect your Ultra96-v2 board via JTAG/USB and power it on.
#   2. Source the Vitis environment settings in your bash terminal:
#        source /home/tam/Documents/app/2025.2.1/Vitis/settings64.sh
#   3. Run XSDB with this script:
#        xsdb scripts/jtag_smoketest.tcl
# =============================================================================

# ── Step 1: Connect to local Hardware Server ───────────────────────────
puts "Connecting to the local hw_server..."
if {[catch {connect} err]} {
    puts "ERROR: Could not connect to hw_server. Make sure Vivado/Vitis hw_server is running."
    exit 1
}

# ── Step 2: Program the FPGA (PL Bitstream) ────────────────────────────
puts "Searching for PL FPGA target..."
targets -set -filter {name =~ "*PL*"}

set bitstream_path "/home/tam/Documents/RAAS/fpga/RAS.runs/impl_1/RAS_wrapper.bit"
puts "Programming PL with bitstream: $bitstream_path..."
if {[catch {fpga -file $bitstream_path} err]} {
    puts "ERROR: FPGA programming failed. Check JTAG connection or power."
    exit 1
}
puts "FPGA programmed successfully."

# ── Step 3: Initialize Processing System (clocks, DDR controller) ──────
puts "Loading psu_init.tcl for hardware initialization..."
set psu_init_path "/home/tam/Documents/RAAS/sw/vitis/RAS_platform/hw/sdt/psu_init.tcl"
if {[catch {source $psu_init_path} err]} {
    puts "ERROR: Could not source psu_init.tcl at: $psu_init_path"
    exit 1
}

# Select the ARM Cortex-A53 Core 0 target
puts "Selecting target processor: ARM Cortex-A53 Core 0..."
targets -set -filter {name =~ "*A53*#0"}

# Reset the processor core
puts "Resetting processor..."
rst -processor

# Execute the init functions from psu_init.tcl
puts "Running psu_init..."
if {[catch {psu_init} err]} {
    puts "ERROR: psu_init execution failed. Is the hardware design correct?"
    exit 1
}

puts "Running psu_post_config..."
if {[catch {psu_post_config} err]} {
    puts "ERROR: psu_post_config execution failed."
    exit 1
}
puts "PS system clocks and DDR controller initialized."

# ── Step 4: Download and Run the Application ───────────────────────────
set elf_path "/home/tam/Documents/RAAS/sw/vitis/RAS_application/build/RAS_application.elf"
puts "Downloading application ELF: $elf_path..."
if {[catch {dow $elf_path} err]} {
    puts "ERROR: Failed to download ELF to memory. Verify DDR is initialized properly."
    exit 1
}

puts "Starting execution (continue)..."
con

puts "================================================================="
puts "SUCCESS: Application is running! Monitor your UART console:"
puts "         sudo picocom -b 115200 /dev/ttyUSB1"
puts "================================================================="
exit 0
