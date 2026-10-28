`timescale 1ns/1ps

module tb_processing_element;
	parameter WIDTH = 8;

	wire signed [WIDTH-1:0]   E, S;
	wire signed [4*WIDTH-1:0] acc;
	reg  signed [WIDTH-1:0]   N, W;
	reg                       clk, rst_n;
	reg                       en, clr;

	// Expected values from the reference model below
	reg  signed [WIDTH-1:0]   exp_E, exp_S;
	reg  signed [4*WIDTH-1:0] exp_acc;
	integer                   errors = 0;

	Processing_Element #(.WIDTH(WIDTH)) dut (
		.clk(clk), .en(en),
		.rst_n(rst_n), .clr(clr),
		.N(N), .W(W), .E(E), .S(S),
		.acc(acc)
	);

	// Clock: must start at a known value, or ~X stays X in 4-state simulators
	initial clk = 1'b0;
	always #5 clk = ~clk;

	// Reference model, written differently from the DUT on purpose:
	// N * W evaluated in a 32-bit signed context (implicit sign extension)
	// instead of the DUT's 16-bit product + explicit extension.
	/* verilator lint_off WIDTHEXPAND */
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			exp_acc <= {4*WIDTH{1'b0}};
			exp_E   <= {WIDTH{1'b0}};
			exp_S   <= {WIDTH{1'b0}};
		end
		else if (en) begin
			if (clr) exp_acc <= {4*WIDTH{1'b0}};
			else     exp_acc <= exp_acc + N * W;
			exp_E <= W;
			exp_S <= N;
		end
	end
	/* verilator lint_on WIDTHEXPAND */

	// Print and check once per cycle, on the falling edge,
	// after the rising-edge updates have settled
	always @(negedge clk) begin
		$display("t=%0t  N=%4d W=%4d en=%b clr=%b | S=%4d E=%4d acc=%0d",
		         $time, N, W, en, clr, S, E, acc);
		if (rst_n && (acc !== exp_acc || E !== exp_E || S !== exp_S)) begin
			$display("  MISMATCH: acc=%0d (exp %0d)  E=%0d (exp %0d)  S=%0d (exp %0d)",
			         acc, exp_acc, E, exp_E, S, exp_S);
			errors = errors + 1;
		end
	end

	// Apply one set of inputs on the next falling edge
	task drive(input signed [WIDTH-1:0] n, w, input e, c);
		begin
			@(negedge clk);
			N = n; W = w; en = e; clr = c;
		end
	endtask

	initial begin
		$dumpfile("waveforms/pe_dump.vcd");
		$dumpvars(0, tb_processing_element);

		// Every input known from time 0
		rst_n = 1'b0; en = 1'b0; clr = 1'b0;
		N = {WIDTH{1'b0}}; W = {WIDTH{1'b0}};

		@(negedge clk) rst_n = 1'b1;

		// Basic accumulation, including a negative operand
		drive(-8'sd68, 8'sd2, 1, 0);
		drive( 8'sd3,  8'sd4, 1, 0);
		drive( 8'sd1,  8'sd2, 1, 0);

		// Clear
		drive( 8'sd1,  8'sd2, 1, 1);
		drive( 8'sd4,  8'sd9, 1, 0);
		drive(-8'sd1,  8'sd8, 1, 0);

		// en low: inputs keep changing, outputs must stay frozen
		drive( 8'sd5,   8'sd5, 0, 0);
		drive(-8'sd7,   8'sd3, 0, 0);
		drive( 8'sd10, -8'sd10, 0, 1);  // clr must also be ignored while en is low

		// Resume
		drive( 8'sd1,  8'sd8, 1, 0);

		// Corner cases: largest positive and largest negative products
		drive(8'h80, 8'h80, 1, 0);      // -128 * -128 = +16384
		drive(8'h7F, 8'h80, 1, 0);      //  127 * -128 = -16256

		@(negedge clk);
		@(negedge clk);

		if (errors == 0) $display("PASS: all cycles matched the reference model");
		else             $display("FAIL: %0d mismatching cycle(s)", errors);
		$finish;
	end
endmodule
