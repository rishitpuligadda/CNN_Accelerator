#!/bin/bash
MACRO_V=../macros/sky130_sram_2kbyte_1rw1r_32x512_8.v

EXTRA=""
if [ "$1" = "macro" ]; then
	EXTRA="-DUSE_SRAM_MACRO -Wno-BLKSEQ $MACRO_V"
fi

rm -rf obj_dir

verilator --binary -j 0 -Wall \
	../rtl/act_feeder.v ../rtl/ram_1rw1r.v ../tb/tb_act_feeder.v $EXTRA \
	--top tb_act_feeder --x-assign unique --x-initial unique --timing --timescale 1ns/1ps \
	--CFLAGS "-std=c++20" --trace \
	|| { echo "Build failed"; exit 1; }

./obj_dir/Vtb_act_feeder +verilator+rand+reset+2 || { echo "Simulation failed"; exit 1; }
