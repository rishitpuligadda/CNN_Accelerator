#!/bin/bash
mkdir -p waveforms outputs
rm -rf obj_dir

verilator --binary -j 0 -Wall \
	../rtl/vector_unit.v ../rtl/vu_regs.v ../rtl/vu_lane.v ../tb/tb_vector_unit.v \
	--top tb_vector_unit --x-assign unique --x-initial unique --timing --timescale 1ns/1ps \
	--CFLAGS "-std=c++20" --trace \
	|| { echo "Build failed"; exit 1; }

./obj_dir/Vtb_vector_unit +verilator+rand+reset+2 || { echo "Simulation failed"; exit 1; }
