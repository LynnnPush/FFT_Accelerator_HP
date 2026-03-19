# Create a vcd directory if it doesn't exist
if {![file exists vcd]} {
    file mkdir vcd
}

# Update this value with the accelerator start time
run 41.069274ms

# Start activity annotation
set vcd_file "./vcd/et4351.phys.hold.vcd"
vcd files $vcd_file
vcd add -r -internal -ports -file $vcd_file /*
vcd dumpportson $vcd_file
vcd on $vcd_file

# Update this value with the accelerator runtime
run 10.083us

# Stop activity annotation
vcd off $vcd_file
vcd dumpportsoff $vcd_file

run -all

exit
 