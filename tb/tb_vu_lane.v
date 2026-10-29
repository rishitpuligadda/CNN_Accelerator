`timescale 1ns/1ps

module tb_vu_lane;
	parameter NRAND = 60000;

	localparam L_PASS   = 4'd0;
	localparam L_ADD    = 4'd1;
	localparam L_SUB    = 4'd2;
	localparam L_MAX    = 4'd3;
	localparam L_MIN    = 4'd4;
	localparam L_SHL    = 4'd5;
	localparam L_SHR    = 4'd6;
	localparam L_SHRR   = 4'd7;
	localparam L_CLAMP  = 4'd8;
	localparam L_CLAMP8 = 4'd9;
	localparam L_MUL    = 4'd10;
	localparam L_REQ    = 4'd11;

	reg                clk, rst_n, issue;
	reg         [3:0]  lop;
	reg  signed [31:0] a, b, lo, hi;
	reg         [4:0]  sh;
	reg  signed [15:0] mpos, mneg;
	reg         [5:0]  s;
	wire signed [31:0] r1, r2;
	wire               v1, v2;

	reg  signed [31:0] e1, e2, e2n;
	reg                h1, h2, h2n;
	reg         [3:0]  o1, o2, o2n;
	integer            errors, t, i;
	integer            cnt [0:11];
	integer            bad [0:11];

	vu_lane dut (
		.clk(clk), .rst_n(rst_n), .lop(lop), .issue(issue),
		.a(a), .b(b), .sh(sh), .mpos(mpos), .mneg(mneg), .s(s), .lo(lo), .hi(hi),
		.r1(r1), .v1(v1), .r2(r2), .v2(v2)
	);

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

	function signed [31:0] sat32(input signed [63:0] x);
		begin
			if (x > 64'sd2147483647)       sat32 = 32'sh7FFFFFFF;
			else if (x < -64'sd2147483648) sat32 = 32'sh80000000;
			else                           sat32 = x[31:0];
		end
	endfunction

	function signed [31:0] ref_fast(input [3:0] op, input signed [31:0] x, input signed [31:0] y,
	                                input [4:0] n, input signed [31:0] l, input signed [31:0] h);
		reg signed [63:0] w;
		reg signed [31:0] c;
		begin
			c = (x > l) ? x : l;
			c = (c < h) ? c : h;
			case (op)
				L_ADD:    ref_fast = x + y;
				L_SUB:    ref_fast = x - y;
				L_MAX:    ref_fast = (x > y) ? x : y;
				L_MIN:    ref_fast = (x < y) ? x : y;
				L_SHL:    ref_fast = x <<< n;
				L_SHR:    ref_fast = x >>> n;
				L_SHRR: begin
					w = {{32{x[31]}}, x};
					if (n == 0) ref_fast = x;
					else begin
						w = (w >>> n) + ((w >>> (n - 1)) & 64'sd1);
						ref_fast = w[31:0];
					end
				end
				L_CLAMP:  ref_fast = c;
				L_CLAMP8: ref_fast = (c < -128) ? -32'sd128 : ((c > 127) ? 32'sd127 : c);
				default:  ref_fast = x;
			endcase
		end
	endfunction

	function signed [31:0] ref_slow(input [3:0] op, input signed [31:0] x, input signed [15:0] y,
	                                input signed [15:0] mp, input signed [15:0] mn, input [5:0] n);
		reg signed [63:0] p, r;
		begin
			if (op == L_MUL) begin
				p = $signed(x) * y;
				ref_slow = p[31:0];
			end
			else begin
				p = (x < 0) ? $signed(x) * mn : $signed(x) * mp;
				if (n == 0) r = p;
				else        r = (p >>> n) + ((p >>> (n - 1)) & 64'sd1);
				ref_slow = sat32(r);
			end
		end
	endfunction

	function signed [31:0] rand32(input integer kind);
		integer k;
		begin
			k = {$random} % 16;
			if (kind == 0 && k == 0)      rand32 = 32'sh80000000;
			else if (kind == 0 && k == 1) rand32 = 32'sh7FFFFFFF;
			else if (k == 2)              rand32 = 0;
			else if (k == 3)              rand32 = -1;
			else if (k < 8)               rand32 = $random % 300;
			else if (k < 11)              rand32 = $random % 20000000;
			else                          rand32 = $random;
		end
	endfunction

	function signed [15:0] rand16(input integer unused);
		integer k;
		begin
			k = {$random} % 10;
			if (unused != 0)  rand16 = 16'sd0;
			else if (k == 0)  rand16 = -16'sd32768;
			else if (k == 1)  rand16 = 16'sd32767;
			else if (k == 2)  rand16 = 16'sd0;
			else              rand16 = 16'($random);
		end
	endfunction

	task step(input [3:0] op, input signed [31:0] x, input signed [31:0] y, input [4:0] n,
	          input signed [15:0] mp, input signed [15:0] mn, input [5:0] sv,
	          input signed [31:0] l, input signed [31:0] h);
		begin
			@(negedge clk);
			if (h1) begin
				cnt[o1] = cnt[o1] + 1;
				if (!v1 || r1 !== e1) begin
					bad[o1] = bad[o1] + 1;
					errors  = errors + 1;
					if (errors <= 10) $display("FAIL op %0d: fast result %0d (valid %b), expected %0d", o1, r1, v1, e1);
				end
			end
			else if (v1) begin
				errors = errors + 1;
				$display("FAIL: v1 high with no fast op issued");
			end
			if (h2) begin
				cnt[o2] = cnt[o2] + 1;
				if (!v2 || r2 !== e2) begin
					bad[o2] = bad[o2] + 1;
					errors  = errors + 1;
					if (errors <= 10) $display("FAIL op %0d: slow result %0d (valid %b), expected %0d", o2, r2, v2, e2);
				end
			end
			else if (v2) begin
				errors = errors + 1;
				$display("FAIL: v2 high with no slow op two cycles ago");
			end

			lop = op; a = x; b = y; sh = n; mpos = mp; mneg = mn; s = sv; lo = l; hi = h;
			issue = 1'b1;
			e2 = e2n; h2 = h2n; o2 = o2n;
			h1  = (op != L_MUL && op != L_REQ);
			o1  = op;
			e1  = ref_fast(op, x, y, n, l, h);
			h2n = (op == L_MUL || op == L_REQ);
			o2n = op;
			e2n = ref_slow(op, x, y[15:0], mp, mn, sv);
		end
	endtask

	task show_req(input signed [31:0] x, input signed [15:0] m, input [5:0] sv);
		begin
			step(L_REQ, x, 0, 0, m, m, sv, 0, 0);
			step(L_PASS, 0, 0, 0, 0, 0, 0, 0, 0);
			step(L_PASS, 0, 0, 0, 0, 0, 0, 0, 0);
			$display("    REQ  a = %6d, M = %5d, S = %2d   ->  exact %9.4f  ->  %0d", x, m, sv,
			         $itor(x) * $itor(m) / (2.0 ** sv), r2);
		end
	endtask

	integer lo_r, hi_r;
	reg [3:0] op_r;

	initial begin
		$dumpfile("waveforms/vu_lane.vcd");
		$dumpvars(0, tb_vu_lane);

		errors = 0;
		h1 = 1'b0; h2 = 1'b0; h2n = 1'b0; o1 = 0; o2 = 0; o2n = 0; e1 = 0; e2 = 0; e2n = 0;
		for (i = 0; i < 12; i = i + 1) begin
			cnt[i] = 0;
			bad[i] = 0;
		end
		issue = 1'b0; lop = 0; a = 0; b = 0; sh = 0; mpos = 0; mneg = 0; s = 0; lo = 0; hi = 0;
		rst_n = 1'b0;
		repeat (2) @(negedge clk);
		rst_n = 1'b1;

		$display("");
		$display("vu_lane: one lane of the vector unit");
		$display("");
		$display("1) REQ rounding (round half up) on small numbers:");
		show_req(3, 1, 1);
		show_req(-3, 1, 1);
		show_req(-5, 1, 1);
		show_req(5, 1, 1);
		show_req(7, 1, 2);
		show_req(-7, 1, 2);
		show_req(1000, 15521, 22);
		show_req(-1000, 15521, 22);
		show_req(2147483647, 32767, 0);

		$display("");
		$display("2) Random operations, issued back to back (fast and 2-cycle ops interleaved):");
		for (t = 0; t < NRAND; t = t + 1) begin
			op_r = 4'({$random} % 12);
			lo_r = rand32(1);
			hi_r = rand32(1);
			if (({$random} % 4) != 0 && lo_r > hi_r) begin
				i = lo_r; lo_r = hi_r; hi_r = i;
			end
			if (({$random} % 3) == 0) begin
				lo_r = -128;
				hi_r = 127;
			end
			step(op_r, rand32(0), rand32(0), 5'({$random}), rand16(0), rand16((({$random} % 4) == 0) ? 1 : 0),
			     6'({$random} % 48), lo_r, hi_r);
		end
		step(L_PASS, 0, 0, 0, 0, 0, 0, 0, 0);
		step(L_PASS, 0, 0, 0, 0, 0, 0, 0, 0);
		step(L_PASS, 0, 0, 0, 0, 0, 0, 0, 0);

		$display("     op       checks   errors");
		$display("    PASS    %8d   %6d", cnt[0], bad[0]);
		$display("    ADD     %8d   %6d", cnt[1], bad[1]);
		$display("    SUB     %8d   %6d", cnt[2], bad[2]);
		$display("    MAX     %8d   %6d", cnt[3], bad[3]);
		$display("    MIN     %8d   %6d", cnt[4], bad[4]);
		$display("    SHL     %8d   %6d", cnt[5], bad[5]);
		$display("    SHR     %8d   %6d", cnt[6], bad[6]);
		$display("    SHRR    %8d   %6d", cnt[7], bad[7]);
		$display("    CLAMP   %8d   %6d", cnt[8], bad[8]);
		$display("    CLAMP8  %8d   %6d", cnt[9], bad[9]);
		$display("    MUL     %8d   %6d", cnt[10], bad[10]);
		$display("    REQ     %8d   %6d", cnt[11], bad[11]);
		$display("");

		if (errors != 0) $fatal(1, "FAIL: %0d error(s)", errors);
		$display("PASS: every result matches the 64-bit reference");
		$finish;
	end
endmodule
