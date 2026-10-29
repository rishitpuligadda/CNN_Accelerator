#!/bin/bash
mkdir -p waveforms outputs
rm -rf obj_dir

verilator --binary -j 0 -Wall \
	../rtl/vu_lane.v ../tb/tb_vu_lane.v \
	--top tb_vu_lane --x-assign unique --x-initial unique --timing --timescale 1ns/1ps \
	--CFLAGS "-std=c++20" --trace \
	|| { echo "Build failed"; exit 1; }

./obj_dir/Vtb_vu_lane +verilator+rand+reset+2 || { echo "Simulation failed"; exit 1; }
