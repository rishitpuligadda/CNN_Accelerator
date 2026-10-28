`timescale 1ns/1ps

module tb_skew_buffer;
	parameter LANES  = 4;
	parameter WIDTH  = 8;
	parameter VIS    = 10;
	parameter CYCLES = 2000;

	localparam TOTAL = VIS + CYCLES;

	reg                    clk, rst_n;
	reg  [LANES*WIDTH-1:0] din;
	wire [LANES*WIDTH-1:0] dout;

	reg  [LANES*WIDTH-1:0] hist [0:TOTAL-1];
	reg  [WIDTH-1:0]       expv;
	integer                t, i, errors, checks, phase_err;

	skew_buffer #(.LANES(LANES), .WIDTH(WIDTH)) dut (
		.clk(clk), .rst_n(rst_n), .din(din), .dout(dout)
	);

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

	task check_cycle;
		begin
			for (i = 0; i < LANES; i = i + 1) begin
				if (t >= i) expv = hist[t-i][i*WIDTH +: WIDTH];
				else        expv = {WIDTH{1'b0}};
				checks = checks + 1;
				if (dout[i*WIDTH +: WIDTH] !== expv) begin
					errors    = errors + 1;
					phase_err = phase_err + 1;
					if (errors <= 10)
						$display("FAIL cycle %0d lane %0d: got %0d, expected %0d", t, i, dout[i*WIDTH +: WIDTH], expv);
				end
			end
		end
	endtask

	initial begin
		$dumpfile("waveforms/skew_buffer.vcd");
		$dumpvars(0, tb_skew_buffer);

		errors = 0; checks = 0; phase_err = 0;
		din    = {(LANES*WIDTH){1'b0}};
		rst_n  = 1'b0;
		repeat (2) @(negedge clk);
		rst_n  = 1'b1;

		$display("");
		$display("skew_buffer: LANES=%0d WIDTH=%0d   (lane i should come out i cycles late)", LANES, WIDTH);
		$display("");
		$display("Every lane gets the cycle number as input, so the output should form a staircase:");
		$write("cycle |  din:");
		for (i = 0; i < LANES; i = i + 1) $write("  L%0d", i);
		$write("  |  dout:");
		for (i = 0; i < LANES; i = i + 1) $write("  L%0d", i);
		$display("");

		for (t = 0; t < VIS; t = t + 1) begin
			@(negedge clk);
			for (i = 0; i < LANES; i = i + 1)
				din[i*WIDTH +: WIDTH] = WIDTH'(t + 1);
			hist[t] = din;
			#1;
			$write("%5d |      ", t);
			for (i = 0; i < LANES; i = i + 1) $write("%4d", din[i*WIDTH +: WIDTH]);
			$write("  |       ");
			for (i = 0; i < LANES; i = i + 1) $write("%4d", dout[i*WIDTH +: WIDTH]);
			$display("");
			check_cycle;
		end
		$display("(0 = reset value, not yet reached by the delayed data)");
		$display("staircase phase: %0d cycles x %0d lanes, %0d mismatches", VIS, LANES, phase_err);

		phase_err = 0;
		for (t = VIS; t < TOTAL; t = t + 1) begin
			@(negedge clk);
			for (i = 0; i < LANES; i = i + 1)
				din[i*WIDTH +: WIDTH] = WIDTH'($random);
			hist[t] = din;
			#1;
			check_cycle;
		end
		$display("random phase:    %0d cycles x %0d lanes, %0d mismatches", CYCLES, LANES, phase_err);
		$display("");

		if (errors != 0) $fatal(1, "FAIL: %0d error(s)", errors);
		$display("PASS: skew_buffer LANES=%0d WIDTH=%0d, %0d lane checks", LANES, WIDTH, checks);
		$finish;
	end
endmodule
