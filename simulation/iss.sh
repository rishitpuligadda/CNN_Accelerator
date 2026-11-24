#!/bin/bash
# ./iss.sh [macro]   (macro: the local memory as the four sky130 1 KB SRAM macro models)
EXTRA=""
if [ "$1" = "macro" ]; then
	EXTRA="-DUSE_SRAM_MACRO -Wno-BLKSEQ ../macros/sky130_sram_1kbyte_1rw1r_32x256_8.v"
	shift
fi
mkdir -p waveforms outputs
rm -rf obj_dir

verilator --binary -j 0 -Wall \
	../rtl/vector_unit.v ../rtl/vu_regs.v ../rtl/vu_lane.v ../tb/tb_vu_iss.v $EXTRA \
	--top tb_vu_iss --x-assign unique --x-initial unique --timing --timescale 1ns/1ps \
	--CFLAGS "-std=c++20" --trace \
	|| { echo "Build failed"; exit 1; }

./obj_dir/Vtb_vu_iss +verilator+rand+reset+2 "$@" || { echo "Simulation failed"; exit 1; }
