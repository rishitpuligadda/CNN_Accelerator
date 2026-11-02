#!/bin/bash
mkdir -p waveforms outputs
rm -rf obj_dir

verilator --binary -j 0 -Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
	../tb/tb_vu_model.v \
	--top tb_vu_model --timing --timescale 1ns/1ps \
	--CFLAGS "-std=c++20" \
	|| { echo "Build failed"; exit 1; }

./obj_dir/Vtb_vu_model || { echo "Simulation failed"; exit 1; }
