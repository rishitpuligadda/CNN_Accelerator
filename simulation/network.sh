#!/bin/bash
mkdir -p waveforms outputs
rm -rf obj_dir

verilator --binary -j 0 -Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
	../rtl/accel_top.v ../rtl/layer_seq.v ../rtl/writeback.v ../rtl/pkt_fifo.v ../rtl/layer_config.v \
	../rtl/layer_controller.v ../rtl/dma.v ../rtl/ram_1rw1r.v ../rtl/act_feeder.v ../rtl/wgt_feeder.v \
	../rtl/skew_buffer.v ../rtl/systolic_array.v ../rtl/Processing_Element.v ../rtl/reset_sync.v \
	../rtl/result_collector.v ../rtl/vector_unit.v ../rtl/vu_regs.v ../rtl/vu_lane.v \
	../tb/tb_network.v $EXTRA \
	--top tb_network --x-assign unique --x-initial unique --timing --timescale 1ns/1ps \
	--CFLAGS "-std=c++20" --trace \
	|| { echo "Build failed"; exit 1; }

./obj_dir/Vtb_network +verilator+rand+reset+2 "$@" || { echo "Simulation failed"; exit 1; }
