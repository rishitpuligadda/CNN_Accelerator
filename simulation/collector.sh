#!/bin/bash
rm -rf obj_dir

verilator --binary -j 0 -Wall \
	../rtl/result_collector.v ../rtl/systolic_array.v ../rtl/Processing_Element.v \
	../rtl/skew_buffer.v ../tb/tb_result_collector.v \
	--top tb_result_collector --x-assign unique --x-initial unique --timing --timescale 1ns/1ps \
	--CFLAGS "-std=c++20" --trace \
	|| { echo "Build failed"; exit 1; }

./obj_dir/Vtb_result_collector +verilator+rand+reset+2 || { echo "Simulation failed"; exit 1; }
