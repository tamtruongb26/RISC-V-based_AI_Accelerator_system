# Run pe_tb in Vivado batch mode
# Usage: vivado -mode batch -source run_pe_tb.tcl
set proj_dir [file dirname [info script]]/pe_sim_proj
file mkdir $proj_dir
create_project -force pe_sim $proj_dir -part xczu3eg-sbva484-1-i

add_files -fileset sources_1 [list \
    [file dirname [info script]]/../hdl/pe.v \
]
add_files -fileset sim_1 [list \
    [file dirname [info script]]/pe_tb.sv \
]
set_property top pe_tb [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {2us} -objects [get_filesets sim_1]

launch_simulation
run all
close_sim
exit
