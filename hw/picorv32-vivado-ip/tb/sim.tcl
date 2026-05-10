# Create an in-memory project
create_project -in_memory -part xczu3eg-sbva484-1-i

# Read source files
read_verilog /home/tam/Documents/RAAS/hw/picorv32-vivado-ip/src/picorv32.v

# Read testbench
read_verilog -sv /home/tam/Documents/RAAS/hw/picorv32-vivado-ip/tb/picorv32_fw_tb.sv

# Set top module
set_property top picorv32_fw_tb [get_filesets sim_1]

# Launch simulation
launch_simulation

# Run for 500 us to let firmware boot and run
run 500 us
