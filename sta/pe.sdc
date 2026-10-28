set CLK_PERIOD 10.0
set CLK_PORT   clk

create_clock -name clk -period $CLK_PERIOD [get_ports $CLK_PORT]
set_clock_uncertainty 0.25 [get_clocks clk]
set_clock_transition  0.15 [get_clocks clk]

set clk_idx       [lsearch [all_inputs] [get_ports $CLK_PORT]]
set ALL_IN_NO_CLK [lreplace [all_inputs] $clk_idx $clk_idx]

set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 -pin X $ALL_IN_NO_CLK
set_load 0.0334 [all_outputs]

set_input_delay 0.8 -clock clk [get_ports {N[*] W[*] en first last}]
set_input_delay [expr 0.2 * $CLK_PERIOD] -clock clk [get_ports rst_n]

set_output_delay [expr 0.2 * $CLK_PERIOD] -clock clk [get_ports {E[*] S[*] done}]
set_output_delay [expr 0.4 * $CLK_PERIOD] -clock clk [get_ports {result[*]}]

set_max_transition 1.5 [current_design]
set_max_fanout     16  [current_design]
