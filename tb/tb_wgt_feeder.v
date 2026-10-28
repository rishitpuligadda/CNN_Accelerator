`timescale 1ns/1ps

module tb_wgt_feeder;
	parameter OUT_REG = 1;

	localparam ADDR  = 10;
	localparam DEPTH = 1 << ADDR;
	localparam QMAX  = 16384;
	localparam LAT   = 2 + OUT_REG;

	reg             clk, rst_n, start, adv;
	reg  [ADDR-1:0] base;
	wire            mem_en, valid;
	wire [ADDR-1:0] mem_addr;
	wire [31:0]     mem_rdata, lanes, skewed;

	reg             tb_en0;
	reg  [ADDR-1:0] tb_addr0;
	reg  [31:0]     tb_wdata0;
	wire [31:0]     unused_rdata0;

	reg  [31:0]     model [0:DEPTH-1];
	reg  [31:0]     exp_q [0:QMAX-1];
	integer         exp_t [0:QMAX-1];
	integer         q_head, q_tail, mon_err, words, cyc, ptr, lat_bad;
	reg             mon_on, trace, stair;
	integer         errors, a, n, t0;

	wgt_feeder #(.WIDTH(32), .ADDR(ADDR), .OUT_REG(OUT_REG)) dut (
		.clk(clk), .rst_n(rst_n), .start(start), .base(base), .adv(adv),
		.mem_rdata(mem_rdata), .mem_en(mem_en), .mem_addr(mem_addr),
		.lanes(lanes), .valid(valid)
	);

	ram_1rw1r #(.DEPTH(DEPTH)) u_ram (
		.clk(clk),
		.en0(tb_en0), .we0(tb_en0), .be0(4'hF), .addr0(tb_addr0), .wdata0(tb_wdata0), .rdata0(unused_rdata0),
		.en1(mem_en), .addr1(mem_addr), .rdata1(mem_rdata)
	);

	skew_buffer #(.LANES(4), .WIDTH(8)) u_skew (
		.clk(clk), .rst_n(rst_n), .din(lanes), .dout(skewed)
	);

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

	always @(posedge clk) cyc <= cyc + 1;

	always @(negedge clk) begin
		if (mon_on) begin
			if (valid) begin
				words <= words + 1;
				if (q_head == q_tail) begin
					mon_err <= mon_err + 1;
					$display("FAIL t=%0t: valid with no expected word", $time);
				end
				else begin
					if (lanes !== exp_q[q_head]) begin
						mon_err <= mon_err + 1;
						if (mon_err < 10) $display("FAIL t=%0t: lanes = %h, expected %h", $time, lanes, exp_q[q_head]);
					end
					if (cyc - exp_t[q_head] != LAT) lat_bad <= lat_bad + 1;
				end
				q_head <= q_head + 1;
			end
			else if (lanes !== 32'h0) begin
				mon_err <= mon_err + 1;
				$display("FAIL t=%0t: lanes = %h while valid = 0", $time, lanes);
			end
		end
	end

	always @(negedge clk) begin
		if (trace) begin
			$write("  %4d |   %b     %b  |    %b      %4d   |   %b   ", cyc - t0, start, adv, mem_en, mem_addr, valid);
			if (valid) $display("%08h", lanes);
			else       $display("   --");
		end
		if (stair)
			$display("  %4d |   %b   | %4d %4d %4d %4d | %4d %4d %4d %4d", cyc - t0, valid,
			         lanes[7:0], lanes[15:8], lanes[23:16], lanes[31:24],
			         skewed[7:0], skewed[15:8], skewed[23:16], skewed[31:24]);
	end

	task pass_(input integer b, input integer m, input integer bubble_pct);
		integer k;
		begin
			if (b < 0 || b + m > DEPTH || m < 1) $fatal(1, "pass_: bad arguments");
			@(negedge clk);
			start = 1'b1;
			base  = b[ADDR-1:0];
			t0    = cyc;
			@(negedge clk);
			start = 1'b0;
			ptr   = b;
			k     = 0;
			while (k < m) begin
				adv = ({$random} % 100) >= bubble_pct;
				if (adv) begin
					exp_q[q_tail] = model[ptr];
					exp_t[q_tail] = cyc;
					q_tail = q_tail + 1;
					ptr = ptr + 1;
					k   = k + 1;
				end
				@(negedge clk);
			end
			adv = 1'b0;
			repeat (LAT + 1) @(negedge clk);
		end
	endtask

	initial begin
		$dumpfile("wgt_feeder.vcd");
		$dumpvars(0, tb_wgt_feeder);

		errors = 0; q_head = 0; q_tail = 0; mon_err = 0; words = 0; cyc = 0; ptr = 0; lat_bad = 0; t0 = 0;
		mon_on = 1'b0; trace = 1'b0; stair = 1'b0;
		start = 1'b0; adv = 1'b0; base = 0;
		tb_en0 = 1'b0; tb_addr0 = 0; tb_wdata0 = 0;

`ifdef USE_SRAM_MACRO
		$display("wgt_feeder OUT_REG=%0d -> ram_1rw1r DEPTH=%0d, mode: sky130 macro", OUT_REG, DEPTH);
`else
		$display("wgt_feeder OUT_REG=%0d -> ram_1rw1r DEPTH=%0d, mode: behavioral", OUT_REG, DEPTH);
`endif
		$display("the feeder reads one weight word for every adv pulse; each word comes out %0d cycles later", LAT);

		rst_n = 1'b0;
		repeat (2) @(negedge clk);
		rst_n  = 1'b1;
		mon_on = 1'b1;

		for (a = 0; a < DEPTH; a = a + 1) begin
			if (a >= 1000 && a < 1008) model[a] = {4{8'(a - 999)}};
			else                       model[a] = $random;
			@(negedge clk);
			tb_en0 = 1'b1; tb_addr0 = a[ADDR-1:0]; tb_wdata0 = model[a];
		end
		@(negedge clk);
		tb_en0 = 1'b0;

		$display("");
		$display("1) Trace: base=512, 5 words, adv with bubbles (as act_feeder gives for stride > 1):");
		$display("     words 512..516 = %08h %08h %08h %08h %08h", model[512], model[513], model[514], model[515], model[516]);
		$display("   cyc | start adv  | mem_en mem_addr | valid  lanes");
		t0    = cyc + 1;
		trace = 1'b1;
		pass_(512, 5, 40);
		trace = 1'b0;

		$display("");
		$display("2) Passes without and with bubbles, across the bank boundary and the whole RAM:");
		pass_(0, 1, 0);
		pass_(37, 9, 0);
		pass_(0, 512, 0);
		pass_(512, 512, 30);
		pass_(0, 784, 50);
		pass_(0, 1024, 0);
		pass_(1023, 1, 0);
		for (n = 0; n < 20; n = n + 1) pass_({$random} % 900, 1 + {$random} % 100, {$random} % 60);
		$display("    %0d words streamed so far, %0d errors, %0d with the wrong latency", words, mon_err, lat_bad);

		$display("");
		$display("3) Into the skew buffer: words 1000..1007 hold 1,1,1,1 / 2,2,2,2 / ...");
		$display("   cyc | valid |   lanes L0..L3    |  to array L0..L3");
		repeat (4) @(negedge clk);
		t0    = cyc + 1;
		stair = 1'b1;
		pass_(1000, 8, 0);
		repeat (3) @(negedge clk);
		stair = 1'b0;

		repeat (3) @(negedge clk);
		$display("");
		$display("4) Monitor: %0d words checked, %0d still expected, %0d errors, %0d with the wrong latency",
		         words, q_tail - q_head, mon_err, lat_bad);
		if (q_head != q_tail) errors = errors + 1;
		errors = errors + mon_err + lat_bad;
		$display("");

		if (errors != 0) $fatal(1, "FAIL: %0d error(s)", errors);
		$display("PASS: %0d words streamed, every word on time", words);
		$finish;
	end
endmodule
