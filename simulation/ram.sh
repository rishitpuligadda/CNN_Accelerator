#!/bin/bash
MACRO_V=../macros/sky130_sram_2kbyte_1rw1r_32x512_8.v

EXTRA=""
if [ "$1" = "macro" ]; then
	EXTRA="-DUSE_SRAM_MACRO -Wno-BLKSEQ $MACRO_V"
fi

rm -rf obj_dir

verilator --binary -j 0 -Wall \
	../rtl/ram_1rw1r.v ../tb/tb_ram_1rw1r.v $EXTRA \
	--top tb_ram_1rw1r --timing --timescale 1ns/1ps \
	--CFLAGS "-std=c++20" --trace \
	|| { echo "Build failed"; exit 1; }

./obj_dir/Vtb_ram_1rw1r || { echo "Simulation failed"; exit 1; }
