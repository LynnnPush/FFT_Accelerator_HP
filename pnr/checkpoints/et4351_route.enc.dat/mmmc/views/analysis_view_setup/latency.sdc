set_clock_latency -source -early -min -rise  -0.668118 [get_ports {clk}] -clock clk 
set_clock_latency -source -early -min -fall  -0.668895 [get_ports {clk}] -clock clk 
set_clock_latency -source -early -max -rise  -0.668118 [get_ports {clk}] -clock clk 
set_clock_latency -source -early -max -fall  -0.668895 [get_ports {clk}] -clock clk 
set_clock_latency -source -late -min -rise  -0.668118 [get_ports {clk}] -clock clk 
set_clock_latency -source -late -min -fall  -0.668895 [get_ports {clk}] -clock clk 
set_clock_latency -source -late -max -rise  -0.668118 [get_ports {clk}] -clock clk 
set_clock_latency -source -late -max -fall  -0.668895 [get_ports {clk}] -clock clk 
