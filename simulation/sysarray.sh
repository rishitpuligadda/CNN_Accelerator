verilator --binary -j 0 -Wall \
	../rtl/systolic_array.v ../rtl/Processing_Element.v \
	../tb/tb_systolic_activity.v ../rtl/reset_sync.v \
	--top tb_systolic_activity --timing \
	--CFLAGS "-std=c++20" --trace

cd obj_dir || { echo "obj_dir not found"; exit 1; }
make -f Vtb_systolic_activity.mk Vtb_systolic_activity || { echo "Compilation failed"; exit 1; }
./Vtb_systolic_activity || { echo "Simulation failed"; exit 1; }

gtkwave systolic_activity.vcd
