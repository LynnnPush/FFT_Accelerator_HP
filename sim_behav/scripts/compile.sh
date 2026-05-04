#!/bin/bash
##########################################################################
### Compile DUT + UVM TB once. Called by regress.sh before the per-test
### simulate loop so we don't pay vlog cost on every seed.
##########################################################################
set -e

source ../setup.sh

UVM_HOME=$(dirname $(which vlog))/../verilog_src/uvm-1.2/src

workLib=workLib_uvm
rm -rf ${workLib}
vlib ${workLib}
vmap work ${workLib}

# DPI-C reference model
gcc -fPIC -shared -O2 \
    ../src/testbench/uvm/ref_model/fft_ref.c \
    -o fft_ref.so -lm

# DUT
vlog -cover sbceft \
     /data/Cadence/gpdk045_v60/Synopsys_sram/saed32sram.v \
     ../src/design/accelerator.v \
     ../src/design/accelerator_fft.v \
     ../src/design/accelerator_mem.v \
     -timescale 1ns/1ps

# UVM TB
vlog -sv -cover sbceft \
     +incdir+${UVM_HOME} \
     +incdir+../src/testbench/uvm \
     ${UVM_HOME}/uvm_pkg.sv \
     ../src/testbench/uvm/fft_if.sv \
     ../src/testbench/uvm/tb_top.sv \
     -timescale 1ns/1ps
