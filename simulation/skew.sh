#!/bin/bash
rm -rf obj_dir

verilator --binary -j 0 -Wall \
	../rtl/skew_buffer.v ../tb/tb_skew_buffer.v \
	--top tb_skew_buffer --timing --timescale 1ns/1ps \
	--CFLAGS "-std=c++20" --trace \
	|| { echo "Build failed"; exit 1; }

./obj_dir/Vtb_skew_buffer || { echo "Simulation failed"; exit 1; }
