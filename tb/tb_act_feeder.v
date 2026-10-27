`timescale 1ns/1ps

module tb_act_feeder;
	localparam ADDR   = 11;
	localparam DEPTH  = 1536;
	localparam NBYTES = DEPTH * 4;
	localparam DIMW   = 8;
	localparam KW_W   = 3;
	localparam CW     = 8;
	localparam QMAX   = 65536;
	localparam BASE   = 4;

	reg                     clk, rst_n, start;
	reg  signed [ADDR+2:0]  tile_addr, step_kh, step_c;
	reg  signed [DIMW+1:0]  y0, x0;
	reg         [3:0]       lane_on;
	reg         [DIMW-1:0]  in_h, in_w;
	reg         [KW_W-1:0]  kh_max, kw_max;
	reg         [CW-1:0]    c_max;
	wire                    busy, mem_en, valid;
	wire        [ADDR-1:0]  mem_addr0, mem_addr1;
	wire        [31:0]      mem_rdata0, mem_rdata1, lanes;

	reg                     pre_en;
	reg         [ADDR-1:0]  pre_addr;
	reg         [31:0]      pre_data;
	wire                    en0;
	wire        [ADDR-1:0]  addr0;

	reg         [7:0]       mem_b [0:NBYTES-1];
	reg         [31:0]      exp_q [0:QMAX-1];
	integer                 q_head, q_tail, mon_err, rises, words;
	reg                     valid_prev, mon_on;
	integer                 errors, checks, tiles, a, t, first, cnt, r0, w0;

	integer L_H, L_W, L_KH, L_KW, L_PAD, L_RP, L_CH, L_OH, L_OW, L_M;

	act_feeder #(.ADDR(ADDR), .DIMW(DIMW), .KW_W(KW_W), .CW(CW)) dut (
		.clk(clk), .rst_n(rst_n), .start(start),
		.tile_addr(tile_addr), .y0(y0), .x0(x0), .lane_on(lane_on),
		.in_h(in_h), .in_w(in_w), .kh_max(kh_max), .kw_max(kw_max), .c_max(c_max),
		.step_kh(step_kh), .step_c(step_c),
		.mem_rdata0(mem_rdata0), .mem_rdata1(mem_rdata1),
		.busy(busy), .mem_en(mem_en), .mem_addr0(mem_addr0), .mem_addr1(mem_addr1),
		.lanes(lanes), .valid(valid)
	);

	assign en0   = pre_en | mem_en;
	assign addr0 = pre_en ? pre_addr : mem_addr0;

	ram_1rw1r #(.DEPTH(DEPTH)) u_ram (
		.clk(clk),
		.en0(en0), .we0(pre_en), .be0(4'hF), .addr0(addr0), .wdata0(pre_data), .rdata0(mem_rdata0),
		.en1(mem_en), .addr1(mem_addr1), .rdata1(mem_rdata1)
	);

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

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
					if (mon_err < 10)
						$display("FAIL t=%0t: lanes = %h, expected %h", $time, lanes, exp_q[q_head]);
				end
				q_head <= q_head + 1;
			end
			else if (lanes !== 32'h0) begin
				mon_err <= mon_err + 1;
				$display("FAIL t=%0t: lanes = %h while valid = 0 (must be zero)", $time, lanes);
			end
			if (valid && !valid_prev) rises <= rises + 1;
			valid_prev <= valid;
		end
	end

	function integer pix(input integer c, input integer y, input integer x);
		begin
			if (y < 0 || y >= L_H || x < 0 || x >= L_W) pix = 0;
			else pix = {24'h0, mem_b[BASE + c * L_CH + y * L_RP + x]};
		end
	endfunction

	function integer ref_word(input integer oh, input integer ow, input integer k);
		integer c, kh, kw, i, v;
		begin
			c  = k / (L_KH * L_KW);
			kh = (k / L_KW) % L_KH;
			kw = k % L_KW;
			ref_word = 0;
			for (i = 0; i < 4; i = i + 1) begin
				if (ow + i < L_OW) v = pix(c, oh + kh - L_PAD, ow + kw - L_PAD + i);
				else               v = 0;
				ref_word = ref_word | (v << (8 * i));
			end
		end
	endfunction

	task layer(input integer h, input integer w, input integer ch, input integer kh, input integer kw,
	           input integer pad, input integer pattern);
		integer b, cc, yy, xx;
		begin
			L_H = h; L_W = w; L_KH = kh; L_KW = kw; L_PAD = pad;
			L_RP = ((w + 3) / 4) * 4;
			L_CH = h * L_RP;
			L_OH = h + 2 * pad - kh + 1;
			L_OW = w + 2 * pad - kw + 1;
			L_M  = ch * kh * kw;
			if (BASE + ch * L_CH > NBYTES) $fatal(1, "layer: map does not fit the buffer");

			for (b = 0; b < NBYTES; b = b + 1) mem_b[b] = 8'(1 + {$random} % 255);
			for (cc = 0; cc < ch; cc = cc + 1)
				for (yy = 0; yy < h; yy = yy + 1)
					for (xx = 0; xx < w; xx = xx + 1)
						if (pattern != 0) mem_b[BASE + cc * L_CH + yy * L_RP + xx] = 8'(10 * (yy + 1) + xx + 1);

			for (a = 0; a < DEPTH; a = a + 1) begin
				@(negedge clk);
				pre_en   = 1'b1;
				pre_addr = a[ADDR-1:0];
				pre_data = {mem_b[4*a+3], mem_b[4*a+2], mem_b[4*a+1], mem_b[4*a]};
			end
			@(negedge clk);
			pre_en = 1'b0;

			in_h    = h[DIMW-1:0];
			in_w    = w[DIMW-1:0];
			kh_max  = KW_W'(kh - 1);
			kw_max  = KW_W'(kw - 1);
			c_max   = CW'(ch - 1);
			step_kh = (ADDR+3)'(L_RP - (kw - 1));
			step_c  = (ADDR+3)'(L_CH - (kh - 1) * L_RP - (kw - 1));

			$display("");
			$display("  layer: %0dx%0dx%0d input, %0dx%0d kernel, pad %0d -> %0dx%0d output, M = %0d, row pitch %0d bytes",
			         h, w, ch, kh, kw, pad, L_OH, L_OW, L_M, L_RP);
		end
	endtask

	task push_tile(input integer oh, input integer ow);
		integer k;
		begin
			for (k = 0; k < L_M; k = k + 1) begin
				exp_q[q_tail] = ref_word(oh, ow, k);
				q_tail = q_tail + 1;
			end
		end
	endtask

	task pulse_tile(input integer oh, input integer ow);
		integer i;
		begin
			start     = 1'b1;
			tile_addr = (ADDR+3)'(BASE + (oh - L_PAD) * L_RP + (ow - L_PAD));
			y0        = (DIMW+2)'(oh - L_PAD);
			x0        = (DIMW+2)'(ow - L_PAD);
			for (i = 0; i < 4; i = i + 1) lane_on[i] = (ow + i < L_OW);
			@(negedge clk);
			start = 1'b0;
		end
	endtask

	task run_tile(input integer oh, input integer ow, input integer loud);
		begin
			push_tile(oh, ow);
			@(negedge clk);
			pulse_tile(oh, ow);
			t = 1; first = -1; cnt = 0;
			while (!(cnt == L_M && !valid)) begin
				if (valid) begin
					if (first < 0) first = t;
					cnt = cnt + 1;
				end
				@(negedge clk);
				t = t + 1;
				if (t > L_M + 20) $fatal(1, "run_tile: pass never finished");
			end
			#1;
			tiles  = tiles + 1;
			checks = checks + 2;
			if (first != 3 || cnt != L_M) begin
				errors = errors + 1;
				$display("FAIL tile (%0d,%0d): first valid in cycle %0d, %0d valid cycles (expected 3 and %0d)",
				         oh, ow, first, cnt, L_M);
			end
			else if (loud != 0)
				$display("    tile oh=%0d ow=%0d lane_on=%b: first valid in cycle 3, %0d valid cycles   ok",
				         oh, ow, lane_on, cnt);
		end
	endtask

	task all_tiles;
		integer oh, ow, n0, e0;
		begin
			n0 = tiles;
			e0 = mon_err + errors;
			for (oh = 0; oh < L_OH; oh = oh + 1)
				for (ow = 0; ow < L_OW; ow = ow + 4)
					run_tile(oh, ow, 0);
			repeat (3) @(negedge clk);
			$display("    all %0d tiles streamed (%0d words), %0d errors", tiles - n0, (tiles - n0) * L_M,
			         mon_err + errors - e0);
		end
	endtask

	task show_tile(input integer oh, input integer ow);
		integer k, c, kh, kw, i, wv;
		begin
			$display("    im2col for tile oh=%0d ow=%0d (lane i = output pixel (%0d, %0d+i)); pixel value = 10*(row+1) + (col+1):",
			         oh, ow, oh, ow);
			$display("       k | c kh kw | lane0 lane1 lane2 lane3");
			for (k = 0; k < L_M; k = k + 1) begin
				c  = k / (L_KH * L_KW);
				kh = (k / L_KW) % L_KH;
				kw = k % L_KW;
				wv = ref_word(oh, ow, k);
				$write("    %4d | %0d  %0d  %0d  |", k, c, kh, kw);
				for (i = 0; i < 4; i = i + 1) $write("  %4d", (wv >> (8 * i)) & 255);
				$display("");
			end
			run_tile(oh, ow, 1);
		end
	endtask

	initial begin
		$dumpfile("act_feeder.vcd");
		$dumpvars(0, tb_act_feeder);

		errors = 0; checks = 0; tiles = 0;
		q_head = 0; q_tail = 0; mon_err = 0; rises = 0; words = 0;
		valid_prev = 1'b0; mon_on = 1'b0;
		start = 1'b0; tile_addr = 0; y0 = 0; x0 = 0; lane_on = 4'b0;
		in_h = 0; in_w = 0; kh_max = 0; kw_max = 0; c_max = 0; step_kh = 0; step_c = 0;
		pre_en = 1'b0; pre_addr = 0; pre_data = 0;
		L_H = 1; L_W = 1; L_KH = 1; L_KW = 1; L_PAD = 0; L_RP = 4; L_CH = 4; L_OH = 1; L_OW = 1; L_M = 1;

`ifdef USE_SRAM_MACRO
		$display("act_feeder -> ram_1rw1r DEPTH=%0d (both ports), mode: sky130 macro", DEPTH);
`else
		$display("act_feeder -> ram_1rw1r DEPTH=%0d (both ports), mode: behavioral", DEPTH);
`endif
		$display("feature maps start at byte %0d (word 1); everything else in the buffer is random garbage", BASE);

		rst_n = 1'b0;
		repeat (2) @(negedge clk);
		rst_n  = 1'b1;
		mon_on = 1'b1;

		$display("");
		$display("1) A small 6x6 image so the patches are readable:");
		layer(6, 6, 1, 3, 3, 1, 1);
		show_tile(0, 0);
		$display("    k=0..2 are the padding row above the image; lane 0 at kw=0 is the padding column");
		show_tile(5, 4);
		$display("    output width 6: only lanes 0-1 exist in this last tile, lanes 2-3 stay 0");

		$display("");
		$display("2) Every tile of each layer shape, checked against a reference im2col:");
		layer(28, 28, 1, 3, 3, 1, 0);
		all_tiles;
		layer(14, 14, 8, 3, 3, 1, 0);
		all_tiles;
		layer(10, 10, 3, 3, 3, 0, 0);
		all_tiles;
		layer(12, 12, 2, 5, 5, 2, 0);
		all_tiles;
		layer(8, 8, 4, 1, 1, 0, 0);
		all_tiles;
		layer(7, 7, 16, 7, 7, 0, 0);
		all_tiles;
		layer(32, 32, 5, 3, 3, 1, 0);
		all_tiles;

		$display("");
		$display("3) Back-to-back tiles (next start in the first cycle busy is low):");
		layer(14, 14, 8, 3, 3, 1, 0);
		r0 = rises; w0 = words;
		push_tile(3, 0);
		@(negedge clk);
		pulse_tile(3, 0);
		while (busy) @(negedge clk);
		push_tile(3, 4);
		pulse_tile(3, 4);
		while (busy) @(negedge clk);
		push_tile(3, 8);
		pulse_tile(3, 8);
		repeat (L_M + 10) @(negedge clk);
		tiles  = tiles + 3;
		checks = checks + 1;
		$display("    3 tiles: valid rose %0d times, %0d words", rises - r0, words - w0);
		if (rises - r0 != 3) begin
			errors = errors + 1;
			$display("FAIL: tiles merged (no valid = 0 cycle between them)");
		end
		else
			$display("    each tile separated by a valid = 0 cycle   ok");

		repeat (3) @(negedge clk);
		checks = checks + 1;
		$display("");
		$display("4) Monitor: %0d lane words compared with the reference, %0d still expected, %0d errors",
		         words, q_tail - q_head, mon_err);
		if (q_head != q_tail) begin
			errors = errors + 1;
			$display("FAIL: %0d expected words never came out", q_tail - q_head);
		end
		errors = errors + mon_err;
		$display("");

		if (errors != 0) $fatal(1, "FAIL: %0d error(s)", errors);
		$display("PASS: %0d tiles, %0d words streamed, %0d checks", tiles, words, checks);
		$finish;
	end
endmodule
