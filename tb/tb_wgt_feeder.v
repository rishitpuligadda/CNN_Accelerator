`timescale 1ns/1ps

module tb_wgt_feeder;
	localparam WIDTH = 32;
	localparam ADDR  = 10;
	localparam DEPTH = 1 << ADDR;
	localparam QMAX  = 16384;

	reg             clk, rst_n, start;
	reg  [ADDR-1:0] base;
	reg  [ADDR:0]   m;
	wire            busy, mem_en, valid;
	wire [ADDR-1:0] mem_addr;
	wire [WIDTH-1:0] mem_rdata, lanes, skewed;

	reg             tb_en0, tb_we0;
	reg  [ADDR-1:0] tb_addr0;
	reg  [31:0]     tb_wdata0;
	wire [31:0]     rdata0;

	reg  [31:0]     model [0:DEPTH-1];
	reg  [31:0]     exp_q [0:QMAX-1];
	integer         q_head, q_tail, mon_err, rises, words, tcyc, t0;
	reg             valid_prev, trace, stair, mon_on;
	integer         errors, checks, passes, a, t, first, cnt, r0, w0;

	wgt_feeder #(.WIDTH(WIDTH), .ADDR(ADDR)) dut (
		.clk(clk), .rst_n(rst_n),
		.start(start), .base(base), .m(m),
		.mem_rdata(mem_rdata),
		.busy(busy), .mem_en(mem_en), .mem_addr(mem_addr),
		.lanes(lanes), .valid(valid)
	);

	ram_1rw1r #(.DEPTH(DEPTH)) u_ram (
		.clk(clk),
		.en0(tb_en0), .we0(tb_we0), .be0(4'hF), .addr0(tb_addr0), .wdata0(tb_wdata0), .rdata0(rdata0),
		.en1(mem_en), .addr1(mem_addr), .rdata1(mem_rdata)
	);

	skew_buffer #(.LANES(4), .WIDTH(8)) u_skew (
		.clk(clk), .rst_n(rst_n), .din(lanes), .dout(skewed)
	);

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

	always @(posedge clk) tcyc <= tcyc + 1;

	always @(negedge clk) begin
		if (mon_on) begin
			if (valid) begin
				words <= words + 1;
				if (q_head == q_tail) begin
					mon_err <= mon_err + 1;
					$display("FAIL t=%0t: valid with no expected word (extra output)", $time);
				end
				else if (lanes !== exp_q[q_head]) begin
					mon_err <= mon_err + 1;
					$display("FAIL t=%0t: lanes = %h, expected %h", $time, lanes, exp_q[q_head]);
				end
				q_head <= q_head + 1;
			end
			else if (lanes !== {WIDTH{1'b0}}) begin
				mon_err <= mon_err + 1;
				$display("FAIL t=%0t: lanes = %h while valid = 0 (must be zero)", $time, lanes);
			end
			if (valid && !valid_prev) rises <= rises + 1;
			valid_prev <= valid;
		end
	end

	always @(negedge clk) begin
		if (trace) begin
			$write("  %4d |   %b     %b  |    %b      %4d   |   %b   ", tcyc - t0, start, busy, mem_en, mem_addr, valid);
			if (valid) $display("%08h", lanes);
			else       $display("   --");
		end
		if (stair)
			$display("  %4d |   %b   | %4d %4d %4d %4d | %4d %4d %4d %4d", tcyc - t0, valid,
			         lanes[7:0], lanes[15:8], lanes[23:16], lanes[31:24],
			         skewed[7:0], skewed[15:8], skewed[23:16], skewed[31:24]);
	end

	task push_pass(input integer b, input integer mm);
		integer i;
		begin
			for (i = 0; i < mm; i = i + 1) begin
				exp_q[q_tail] = model[b + i];
				q_tail = q_tail + 1;
			end
		end
	endtask

	task pulse_start(input integer b, input integer mm);
		begin
			if (b < 0 || b >= DEPTH || mm < 0 || mm > DEPTH)
				$fatal(1, "pulse_start: argument out of range");
			start = 1'b1;
			t0    = tcyc;
			base  = b[ADDR-1:0];
			m     = mm[ADDR:0];
			@(negedge clk);
			start = 1'b0;
		end
	endtask

	task run(input integer b, input integer mm);
		begin
			if (b + mm > DEPTH) $fatal(1, "run: pass goes past the end of the RAM");
			push_pass(b, mm);
			@(negedge clk);
			pulse_start(b, mm);
			t = 1; first = -1; cnt = 0;
			while (!(cnt == mm && !valid)) begin
				if (valid) begin
					if (first < 0) first = t;
					cnt = cnt + 1;
				end
				@(negedge clk);
				t = t + 1;
				if (t > mm + 20) $fatal(1, "run: pass never finished");
			end
			#1;
			passes = passes + 1;
			checks = checks + 2;
			$write("  P%0d: base=%0d, m=%0d -> words %0d..%0d, first valid in cycle %0d, %0d valid cycles",
			       passes, b, mm, b, b + mm - 1, first, cnt);
			if (first != 3 || cnt != mm) begin
				errors = errors + 1;
				$display("   <- WRONG (expected cycle 3 and %0d cycles)", mm);
			end
			else
				$display("   ok");
		end
	endtask

	initial begin
		$dumpfile("wgt_feeder.vcd");
		$dumpvars(0, tb_wgt_feeder);

		errors = 0; checks = 0; passes = 0;
		q_head = 0; q_tail = 0; mon_err = 0; rises = 0; words = 0; tcyc = 0; t0 = 0;
		valid_prev = 1'b0; trace = 1'b0; stair = 1'b0; mon_on = 1'b0;
		start = 1'b0; base = 0; m = 0;
		tb_en0 = 1'b0; tb_we0 = 1'b0; tb_addr0 = 0; tb_wdata0 = 0;

`ifdef USE_SRAM_MACRO
		$display("wgt_feeder -> ram_1rw1r DEPTH=%0d (2 banks), mode: sky130 macro", DEPTH);
`else
		$display("wgt_feeder -> ram_1rw1r DEPTH=%0d (2 banks), mode: behavioral", DEPTH);
`endif

		rst_n = 1'b0;
		repeat (2) @(negedge clk);
		rst_n  = 1'b1;
		mon_on = 1'b1;

		for (a = 0; a < DEPTH; a = a + 1) begin
			if (a >= 1000 && a < 1008) model[a] = {4{8'(a - 999)}};
			else                       model[a] = $random;
			@(negedge clk);
			tb_en0 = 1'b1; tb_we0 = 1'b1; tb_addr0 = a[ADDR-1:0]; tb_wdata0 = model[a];
		end
		@(negedge clk);
		tb_we0 = 1'b0;
		for (a = 0; a < DEPTH; a = a + 1) begin
			tb_addr0 = a[ADDR-1:0];
			@(posedge clk);
			@(posedge clk);
			checks = checks + 1;
			if (rdata0 !== model[a]) begin
				errors = errors + 1;
				$display("FAIL preload: ram[%0d] = %h, expected %h", a, rdata0, model[a]);
			end
			@(negedge clk);
		end
		tb_en0 = 1'b0;
		$display("preloaded all %0d weight words through port 0 and read them back", DEPTH);

		$display("");
		$display("1) Trace of one pass, base=512, m=5:");
		$display("     words 512..516 = %08h %08h %08h %08h %08h", model[512], model[513], model[514], model[515], model[516]);
		$display("   cyc | start busy | mem_en mem_addr | valid  lanes");
		t0    = tcyc + 1;
		trace = 1'b1;
		run(512, 5);
		@(negedge clk);
		trace = 1'b0;
		$display("   one read per cycle while busy; each word appears on lanes 2 cycles after its read");

		$display("");
		$display("2) Pass sizes and positions:");
		run(0, 1);
		run(37, 9);
		run(0, 512);
		run(512, 512);
		run(0, 784);
		run(0, 1024);
		run(1023, 1);

		$display("");
		$display("3) Same pass twice, the second start in the first cycle busy is low:");
		r0 = rises; w0 = words;
		push_pass(100, 9);
		@(negedge clk);
		pulse_start(100, 9);
		while (busy) @(negedge clk);
		push_pass(100, 9);
		pulse_start(100, 9);
		repeat (16) @(negedge clk);
		passes = passes + 2;
		checks = checks + 1;
		$display("  valid rose %0d times for 2 passes, %0d words came out", rises - r0, words - w0);
		if (rises - r0 != 2) begin
			errors = errors + 1;
			$display("FAIL: the two passes merged (no valid = 0 cycle between them)");
		end
		else
			$display("  at least one valid = 0 cycle separated them, so the PEs see two separate tiles   ok");

		$display("");
		$display("4) start while busy: pass base=200 m=40, second start 10 cycles in (must be ignored)");
		r0 = rises; w0 = words;
		push_pass(200, 40);
		@(negedge clk);
		pulse_start(200, 40);
		repeat (9) @(negedge clk);
		pulse_start(700, 30);
		repeat (60) @(negedge clk);
		passes = passes + 1;
		checks = checks + 1;
		$display("  %0d words came out in %0d pass(es)", words - w0, rises - r0);
		if (words - w0 != 40 || rises - r0 != 1) begin
			errors = errors + 1;
			$display("FAIL: the second start was not ignored");
		end
		else
			$display("  only the first pass ran   ok");

		$display("");
		$display("5) Into the skew buffer: words 1000..1007 hold 1,1,1,1 / 2,2,2,2 / ... so the array inputs form a staircase");
		$display("   cyc | valid |   lanes L0..L3    |  to array L0..L3");
		push_pass(1000, 8);
		@(negedge clk);
		stair = 1'b1;
		pulse_start(1000, 8);
		repeat (13) @(negedge clk);
		stair = 1'b0;
		passes = passes + 1;
		$display("   lane j reaches the array j cycles late, exactly what column j of the systolic array needs");

		repeat (3) @(negedge clk);
		checks = checks + 1;
		$display("");
		$display("6) Monitor: %0d words checked against the RAM contents, %0d still expected, %0d errors",
		         words, q_tail - q_head, mon_err);
		if (q_head != q_tail) begin
			errors = errors + 1;
			$display("FAIL: %0d expected words never came out", q_tail - q_head);
		end
		errors = errors + mon_err;
		$display("");

		if (errors != 0) $fatal(1, "FAIL: %0d error(s)", errors);
		$display("PASS: %0d passes, %0d words streamed, %0d checks", passes, words, checks);
		$finish;
	end
endmodule
