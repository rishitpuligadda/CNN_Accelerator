verilator --binary -j 0 -Wall \
	../rtl/Processing_Element.v ../tb/tb_processing_element.v \
	--top tb_processing_element --timing \
	--CFLAGS "-std=c++20" --trace

cd obj_dir || { echo "obj_dir not found"; exit 1; }
make -f Vtb_processing_element.mk Vtb_processing_element || { echo "Compilation failed"; exit 1; }
./Vtb_processing_element || { echo "Simulation failed"; exit 1; }

gtkwave pe_dump.vcd
