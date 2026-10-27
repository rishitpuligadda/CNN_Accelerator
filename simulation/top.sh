#!/bin/bash
MACRO_V=../macros/sky130_sram_2kbyte_1rw1r_32x512_8.v

EXTRA=""
if [ "$1" = "macro" ]; then
	EXTRA="-DUSE_SRAM_MACRO -Wno-BLKSEQ $MACRO_V"
fi

rm -rf obj_dir

verilator --binary -j 0 -Wall \
	../rtl/accel_top.v ../rtl/layer_config.v ../rtl/layer_controller.v ../rtl/dma.v ../rtl/ram_1rw1r.v \
	../rtl/act_feeder.v ../rtl/wgt_feeder.v ../rtl/skew_buffer.v ../rtl/systolic_array.v \
	../rtl/Processing_Element.v ../rtl/reset_sync.v ../rtl/result_collector.v \
	../tb/tb_accel_top.v $EXTRA \
	--top tb_accel_top --x-assign unique --x-initial unique --timing --timescale 1ns/1ps \
	--CFLAGS "-std=c++20" --trace \
	|| { echo "Build failed"; exit 1; }

./obj_dir/Vtb_accel_top +verilator+rand+reset+2 || { echo "Simulation failed"; exit 1; }
