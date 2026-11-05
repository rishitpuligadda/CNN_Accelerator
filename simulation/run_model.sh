#!/bin/bash
# Run the compiled model in simulation/model/ on the RTL (tb/tb_model.v).
# The model files are written by py_run_model.sh (8x8 digits) or py_run_keras.sh (a Keras model).
#   ./run_model.sh [macro] [+vcd]        (gallery options go to the checker: CHECK="--all --names=cat,dog,...")
# The C++ build runs JOBS parallel compiles (default 2; more is faster but needs more memory: JOBS=8 ./run_model.sh).
# Waveform tracing is compiled in only when +vcd is given (it makes the build much bigger).
mkdir -p waveforms outputs
[ -f model/model_params.vh ] || { echo "no compiled model in simulation/model/ - run py_run_model.sh or py_run_keras.sh first"; exit 1; }
EXTRA=""
if [ "$1" = "macro" ]; then
	EXTRA="-DUSE_SRAM_MACRO -Wno-BLKSEQ ../macros/sky130_sram_2kbyte_1rw1r_32x512_8.v"
	shift
fi
TRACE=""
for a in "$@"; do [ "$a" = "+vcd" ] && TRACE="--trace"; done
rm -rf obj_dir
verilator --binary --build-jobs "${JOBS:-2}" -Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -I. \
	../rtl/accel_top.v ../rtl/layer_seq.v ../rtl/writeback.v ../rtl/pkt_fifo.v ../rtl/layer_config.v \
	../rtl/layer_controller.v ../rtl/dma.v ../rtl/ram_1rw1r.v ../rtl/act_feeder.v ../rtl/wgt_feeder.v \
	../rtl/skew_buffer.v ../rtl/systolic_array.v ../rtl/Processing_Element.v ../rtl/reset_sync.v \
	../rtl/result_collector.v ../rtl/vector_unit.v ../rtl/vu_regs.v ../rtl/vu_lane.v \
	../tb/tb_model.v $EXTRA \
	--top tb_model --x-assign unique --x-initial unique --timing --timescale 1ns/1ps \
	--CFLAGS "-std=c++20" $TRACE \
	|| { echo "Build failed (if the log says 'Killed', the machine ran out of memory: try JOBS=1)"; exit 1; }
./obj_dir/Vtb_model +verilator+rand+reset+2 "$@" || { echo "Simulation failed"; exit 1; }
# the chip has finished; now compare what it produced with the golden model
python3 ../python/check_results.py model outputs/chip_results.hex $CHECK
