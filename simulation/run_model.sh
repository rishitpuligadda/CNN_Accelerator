#!/bin/bash
# Run the compiled model in simulation/model/ on the RTL (tb/tb_model.v).
# The model files are written by py_run_model.sh (8x8 digits) or py_run_keras.sh (a Keras model).
#   ./run_model.sh [macro] [+all]
mkdir -p waveforms outputs
[ -f model/model_params.vh ] || { echo "no compiled model in simulation/model/ - run py_run_model.sh or py_run_keras.sh first"; exit 1; }
EXTRA=""
if [ "$1" = "macro" ]; then
	EXTRA="-DUSE_SRAM_MACRO -Wno-BLKSEQ ../macros/sky130_sram_2kbyte_1rw1r_32x512_8.v"
	shift
fi
rm -rf obj_dir
verilator --binary -j 0 -Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -I. \
	../rtl/accel_top.v ../rtl/layer_seq.v ../rtl/writeback.v ../rtl/pkt_fifo.v ../rtl/layer_config.v \
	../rtl/layer_controller.v ../rtl/dma.v ../rtl/ram_1rw1r.v ../rtl/act_feeder.v ../rtl/wgt_feeder.v \
	../rtl/skew_buffer.v ../rtl/systolic_array.v ../rtl/Processing_Element.v ../rtl/reset_sync.v \
	../rtl/result_collector.v ../rtl/vector_unit.v ../rtl/vu_regs.v ../rtl/vu_lane.v \
	../tb/tb_model.v $EXTRA \
	--top tb_model --x-assign unique --x-initial unique --timing --timescale 1ns/1ps \
	--CFLAGS "-std=c++20" --trace \
	|| { echo "Build failed"; exit 1; }
./obj_dir/Vtb_model +verilator+rand+reset+2 "$@" || { echo "Simulation failed"; exit 1; }
