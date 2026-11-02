#!/bin/bash
mkdir -p waveforms outputs

for L in 4 8; do
	rm -rf obj_dir
	verilator --binary -j 0 -Wall \
		../rtl/vector_unit.v ../rtl/vu_regs.v ../rtl/vu_lane.v ../tb/tb_vu_xlane.v \
		--top tb_vu_xlane -GLANES=$L --x-assign unique --x-initial unique --timing --timescale 1ns/1ps \
		--CFLAGS "-std=c++20" --trace \
		|| { echo "Build failed"; exit 1; }

	./obj_dir/Vtb_vu_xlane +verilator+rand+reset+2 "$@" || { echo "Simulation failed (LANES=$L)"; exit 1; }
done
