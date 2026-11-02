`timescale 1ns/1ps

// Softmax over classes and global average pooling on the vector_unit RTL, using repeated sections:
// the body stores per-class / per-channel values in local memory, epilogue loops (TAG iter) go over them.
module tb_vu_post;
	localparam LANES = 4;
	localparam ADDR  = 11;
	localparam W     = LANES * 32;
	localparam NPMAX = 32768;
	localparam OMAX  = 2048;

	reg                 clk, rst_n;
	reg                 pm_we;
	reg  [5:0]          pm_waddr;
	reg  [31:0]         pm_wdata;
	reg                 lut_we;
	reg  [7:0]          lut_waddr;
	reg  [15:0]         lut_wdata;
	reg  [5:0]          sec_start [0:5];
	reg  [6:0]          sec_len   [0:5];
	reg  [8:0]          sec_cnt   [0:5];
	// the ports are driven from plain registers (copied from the tables before each run), as a controller would
	reg  [5:0]          ps0, ps1, ps2, ps3, ps4, ps5;
	reg  [6:0]          pl0, pl1, pl2, pl3, pl4, pl5;
	reg  [8:0]          pc0, pc2, pc3, pc4, pc5;
	reg                 layer_start, layer_end;
	wire                unused_busy, done;
	wire                pkt_valid, pkt_ready;
	wire                st_en;
	wire [ADDR-1:0]     st_addr;
	wire [LANES-1:0]    st_be;
	wire [LANES*8-1:0]  st_data;

	reg  [W-1:0]        p_data [0:NPMAX-1];
	reg  [LANES-1:0]    p_be   [0:NPMAX-1];
	reg  [7:0]          p_row  [0:NPMAX-1];
	reg  [7:0]          p_col  [0:NPMAX-1];
	reg  [7:0]          p_chan [0:NPMAX-1];
	integer             p_idx, n_pkts, avail_pct;
	reg                 avail;
	wire [31:0]         pi = (p_idx < NPMAX) ? p_idx : 0;

	// sections: 0 prologue, 1 body, 2..5 epilogue 0..3
	vector_unit #(.LANES(LANES), .ADDR(ADDR), .PM_AW(6)) dut (
		.clk(clk), .rst_n(rst_n),
		.pm_we(pm_we), .pm_waddr(pm_waddr), .pm_wdata(pm_wdata),
		.lut_we(lut_we), .lut_waddr(lut_waddr), .lut_wdata(lut_wdata),
		.pro_start(ps0), .pro_len(pl0), .body_start(ps1), .body_len(pl1),
		.epi_start(ps2), .epi_len(pl2),
		.pro_cnt(pc0), .epi_cnt(pc2),
		.epi1_start(ps3), .epi1_len(pl3), .epi1_cnt(pc3),
		.epi2_start(ps4), .epi2_len(pl4), .epi2_cnt(pc4),
		.epi3_start(ps5), .epi3_len(pl5), .epi3_cnt(pc5),
		.layer_start(layer_start), .layer_end(layer_end), .busy(unused_busy), .done(done),
		.pkt_valid(pkt_valid), .pkt_ready(pkt_ready),
		.pkt_data(p_data[pi]), .pkt_addr(11'd0), .pkt_be(p_be[pi]),
		.pkt_row(p_row[pi]), .pkt_col(p_col[pi]), .pkt_chan(p_chan[pi]), .pkt_last(1'b0),
		.st_en(st_en), .st_addr(st_addr), .st_be(st_be), .st_data(st_data)
	);

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

	// ================================================================ assembler
	reg  [31:0] prg [0:63];
	integer     np, cur_sec;

	function [31:0] enc(input [5:0] op, input [3:0] d, input [3:0] a, input [3:0] b, input [10:0] x);
		enc = {op, 3'b000, d, a, b, x};
	endfunction
	function [31:0] LI(input [3:0] d, input integer v);  LI = {6'h01, 3'b000, d, v[18:0]}; endfunction
	function [31:0] ADDS(input [3:0] d, input [3:0] a, input [3:0] b); ADDS = enc(6'h04, d, a, b, 11'd0); endfunction
	function [31:0] TAG(input [3:0] d, input integer f); TAG = enc(6'h08, d, 4'd0, 4'd0, f[10:0]); endfunction
	function [31:0] SETQ(input [3:0] q, input [3:0] a, input [3:0] b, input integer s); SETQ = enc(6'h09, q, a, b, s[10:0]); endfunction
	function [31:0] SETC(input [3:0] c, input [3:0] a, input [3:0] b); SETC = enc(6'h0A, c, a, b, 11'd0); endfunction
	function [31:0] RCP(input [3:0] d, input [3:0] a, input integer n); RCP = enc(6'h0B, d, a, 4'd0, n[10:0]); endfunction
	function [31:0] VLI(input [3:0] d, input integer v); VLI = {6'h11, 3'b000, d, 4'd0, v[14:0]}; endfunction
	function [31:0] BCAST(input [3:0] d, input [3:0] a); BCAST = enc(6'h12, d, a, 4'd0, 11'd0); endfunction
	function [31:0] ADD(input [3:0] d, input [3:0] a, input [3:0] b); ADD = enc(6'h18, d, a, b, 11'd0); endfunction
	function [31:0] SUB(input [3:0] d, input [3:0] a, input [3:0] b); SUB = enc(6'h19, d, a, b, 11'd0); endfunction
	function [31:0] MAX(input [3:0] d, input [3:0] a, input [3:0] b); MAX = enc(6'h1B, d, a, b, 11'd0); endfunction
	function [31:0] SHRR(input [3:0] d, input [3:0] a, input integer n); SHRR = enc(6'h1F, d, a, 4'd0, n[10:0]); endfunction
	function [31:0] MUL(input [3:0] d, input [3:0] a, input [3:0] b); MUL = enc(6'h20, d, a, b, 11'd0); endfunction
	function [31:0] REQ(input [3:0] d, input [3:0] a, input integer q); REQ = enc(6'h21, d, a, 4'd0, q[10:0]); endfunction
	function [31:0] CLAMP(input [3:0] d, input [3:0] a, input integer c); CLAMP = enc(6'h22, d, a, 4'd0, c[10:0]); endfunction
	function [31:0] LUT(input [3:0] d, input [3:0] a); LUT = enc(6'h23, d, a, 4'd0, 11'd0); endfunction
	function [31:0] RADD(input [3:0] d, input [3:0] a); RADD = enc(6'h33, d, a, 4'd0, 11'd0); endfunction
	function [31:0] ST8A(input [3:0] a, input [3:0] sad, input [3:0] smask, input integer c); ST8A = enc(6'h39, smask, a, sad, c[10:0]); endfunction
	function [31:0] LDS(input [3:0] d, input [3:0] sa); LDS = enc(6'h3B, d, sa, 4'd0, 11'd0); endfunction
	function [31:0] STS(input [3:0] a, input [3:0] sb); STS = enc(6'h3C, 4'd0, a, sb, 11'd0); endfunction

	localparam T_CHAN = 4, T_ITER = 9;

	task emit(input [31:0] w);
		begin
			if (np >= 64) $fatal(1, "program longer than 64 instructions");
			prg[np] = w;
			np = np + 1;
			sec_len[cur_sec] = sec_len[cur_sec] + 7'd1;
		end
	endtask
	task section(input integer k, input integer cnt);
		begin
			cur_sec = k;
			sec_start[k] = np[5:0];
			sec_len[k]   = 7'd0;
			sec_cnt[k]   = cnt[8:0];
		end
	endtask
	task clear_sections;
		integer k;
		begin
			np = 0;
			for (k = 0; k < 6; k = k + 1) begin sec_start[k] = 6'd0; sec_len[k] = 7'd0; sec_cnt[k] = 9'd0; end
		end
	endtask

	// ================================================================ reference arithmetic
	function signed [31:0] sat32(input signed [63:0] x);
		begin
			if (x > 64'sd2147483647)       sat32 = 32'sh7FFFFFFF;
			else if (x < -64'sd2147483648) sat32 = 32'sh80000000;
			else                           sat32 = x[31:0];
		end
	endfunction
	function signed [31:0] f_req(input signed [31:0] a, input signed [15:0] mp, input signed [15:0] mn, input [5:0] s);
		reg signed [63:0] y;
		begin
			y = (a < 0) ? $signed(a) * mn : $signed(a) * mp;
			if (s != 6'd0) y = (y >>> s) + ((y >>> (s - 6'd1)) & 64'sd1);
			f_req = sat32(y);
		end
	endfunction
	function signed [31:0] f_clamp(input signed [31:0] a, input signed [31:0] l, input signed [31:0] h);
		reg signed [31:0] c;
		begin
			c = (a > l) ? a : l;
			f_clamp = (c < h) ? c : h;
		end
	endfunction
	function signed [31:0] f_shrr(input signed [31:0] a, input [4:0] n);
		reg signed [63:0] w;
		begin
			w = {{32{a[31]}}, a};
			if (n == 5'd0) f_shrr = a;
			else begin
				w = (w >>> n) + ((w >>> (n - 5'd1)) & 64'sd1);
				f_shrr = w[31:0];
			end
		end
	endfunction

	// ================================================================ harness
	reg  [7:0]  omem [0:OMAX*4-1];
	integer     owr  [0:OMAX*4-1];
	reg         took;

	initial begin : collect
		integer i;
		forever begin
			@(negedge clk);
			if (st_en && st_addr < OMAX)
				for (i = 0; i < LANES; i = i + 1)
					if (st_be[i]) begin
						omem[st_addr*4 + i] = st_data[i*8 +: 8];
						owr[st_addr*4 + i]  = owr[st_addr*4 + i] + 1;
					end
		end
	end

	initial begin
		took = 1'b0;
		forever begin
			@(posedge clk);
			took = pkt_valid && pkt_ready;
			@(negedge clk);
			if (took) p_idx = p_idx + 1;
			avail = ({$random} % 100) < avail_pct;
		end
	end
	assign pkt_valid = avail && (p_idx < n_pkts);

	integer t0, cycles;

	task run_program(input integer pct);
		integer i;
		begin
			for (i = 0; i < np; i = i + 1) begin
				@(negedge clk);
				pm_we    = 1'b1;
				pm_waddr = i[5:0];
				pm_wdata = prg[i];
			end
			@(negedge clk);
			pm_we = 1'b0;
			ps0 = sec_start[0]; pl0 = sec_len[0]; pc0 = sec_cnt[0];
			ps1 = sec_start[1]; pl1 = sec_len[1];
			ps2 = sec_start[2]; pl2 = sec_len[2]; pc2 = sec_cnt[2];
			ps3 = sec_start[3]; pl3 = sec_len[3]; pc3 = sec_cnt[3];
			ps4 = sec_start[4]; pl4 = sec_len[4]; pc4 = sec_cnt[4];
			ps5 = sec_start[5]; pl5 = sec_len[5]; pc5 = sec_cnt[5];
			for (i = 0; i < OMAX * 4; i = i + 1) begin omem[i] = 8'hAA; owr[i] = 0; end
			p_idx = 0;
			avail_pct = pct;
			t0 = $time;
			@(negedge clk);
			layer_start = 1'b1;
			@(negedge clk);
			layer_start = 1'b0;
			while (p_idx < n_pkts) @(negedge clk);
			layer_end = 1'b1;
			@(negedge clk);
			layer_end = 1'b0;
			i = 0;
			while (!done) begin
				@(negedge clk);
				i = i + 1;
				if (i > 400000) $fatal(1, "done never arrived");
			end
			cycles = ($time - t0) / 10;
			repeat (2) @(negedge clk);
		end
	endtask

	integer errors, runs, show;
	real    max_err_all;

	// ================================================================ softmax over C classes
	localparam real S_IN = 0.1;     // real value of one int8 logit step

	reg  [15:0]       table_exp [0:255];
	reg signed [31:0] lg  [0:255];
	reg signed [31:0] ex  [0:255];

	task load_exp_table;
		integer b, d;
		begin
			for (b = 0; b < 256; b = b + 1) begin
				d = (b < 128) ? 0 : b - 256;                     // only d <= 0 is ever looked up
				table_exp[b] = 16'($rtoi(32767.0 * $exp(d * S_IN) + 0.5));
				@(negedge clk);
				lut_we = 1'b1; lut_waddr = b[7:0]; lut_wdata = table_exp[b];
			end
			@(negedge clk);
			lut_we = 1'b0;
		end
	endtask

	task softmax(input integer c, input integer pct);
		integer i, m, e0, best, hwbest;
		reg signed [31:0] r, sum, rr, q;
		reg signed [7:0]  hv;
		real fsum, fp, err, maxerr;
		begin
			e0 = errors;
			// classifier output: one packet per class, value in lane 0, class in the chan tag
			for (i = 0; i < c; i = i + 1) begin
				p_data[i] = {96'd0, 32'($random % 40000)};
				p_be[i]   = 4'b0001;
				p_row[i]  = 8'd0; p_col[i] = 8'd0; p_chan[i] = i[7:0];
			end
			n_pkts = c;

			clear_sections;
			section(0, 1);
			emit(LI(1, 15521)); emit(SETQ(0, 1, 1, 22));                 // logits to int8, linear
			emit(LI(3, -128)); emit(LI(4, 127)); emit(SETC(0, 3, 4));    // c0 = int8
			emit(LI(4, 0));    emit(SETC(2, 3, 4));                      // c2 = -128..0 (exp table range)
			emit(LI(3, 0));    emit(LI(4, 127)); emit(SETC(1, 3, 4));    // c1 = 0..127 (probability output)
			emit(VLI(6, -128)); emit(VLI(5, 0));                         // running max, running sum
			emit(LI(10, 1)); emit(LI(11, 1));                            // output base word, byte mask
			section(1, 0);                                               // body: one class
			emit(REQ(0, 7, 0)); emit(CLAMP(0, 0, 0));
			emit(TAG(1, T_CHAN)); emit(STS(0, 1));                       // logit -> local memory entry = class
			emit(MAX(6, 6, 0));
			section(2, c);                                               // epilogue 0, once per class
			emit(TAG(1, T_ITER)); emit(LDS(1, 1));
			emit(SUB(1, 1, 6)); emit(CLAMP(1, 1, 2)); emit(LUT(1, 1));   // e = exp(logit - max), Q15
			emit(STS(1, 1)); emit(ADD(5, 5, 1));
			section(3, 1);                                               // epilogue 1, once
			emit(RADD(2, 5)); emit(RCP(3, 2, 30)); emit(BCAST(4, 3));    // R = 2^30 / sum
			section(4, c);                                               // epilogue 2, once per class
			emit(TAG(1, T_ITER)); emit(LDS(1, 1));
			emit(MUL(2, 4, 1)); emit(SHRR(2, 2, 23));                    // p * 128 = e * R / 2^23
			emit(ADDS(5, 10, 1)); emit(ST8A(2, 5, 11, 1));

			run_program(pct);

			// bit-exact reference, and floating-point softmax for the accuracy
			m = -128;
			for (i = 0; i < c; i = i + 1) begin
				r = f_clamp(f_req(p_data[i][31:0], 15521, 15521, 22), -128, 127);
				lg[i] = r;
				if (r > m) m = r;
			end
			sum = 0;
			for (i = 0; i < c; i = i + 1) begin
				r = f_clamp(lg[i] - m, -128, 0);
				ex[i] = {{16{table_exp[r[7:0]][15]}}, table_exp[r[7:0]]};
				sum = sum + ex[i];
			end
			rr = (sum == 0) ? 32'hFFFFFFFF : 32'((64'd1 << 30) / {32'd0, sum});
			fsum = 0.0;
			for (i = 0; i < c; i = i + 1) fsum = fsum + $exp(lg[i] * S_IN);
			maxerr = 0.0; best = 0; hwbest = 0;
			for (i = 0; i < c; i = i + 1) begin
				q  = f_clamp(f_shrr(rr * ex[i], 23), 0, 127);
				hv = omem[(1 + i) * 4];
				if (owr[(1 + i) * 4] != 1 || hv != q) begin
					errors = errors + 1;
					if (errors - e0 <= 5) $display("    FAIL class %0d: got %0d (written %0d times), expected %0d", i, hv, owr[(1 + i) * 4], q);
				end
				fp  = $exp(lg[i] * S_IN) / fsum;
				err = (hv / 128.0) - fp;
				if (err < 0.0) err = -err;
				if (err > maxerr) maxerr = err;
				if (lg[i] > lg[best]) best = i;
				if (omem[(1 + i) * 4] > omem[(1 + hwbest) * 4]) hwbest = i;
			end
			if (maxerr > max_err_all) max_err_all = maxerr;
			if (show != 0) begin
				$display("    class:        %0s", "   0     1     2     3     4     5     6     7     8     9");
				$write("    logit (int8):");
				for (i = 0; i < c; i = i + 1) $write(" %5d", lg[i]);
				$display("");
				$write("    softmax (float):");
				for (i = 0; i < c; i = i + 1) $write(" %5.3f", $exp(lg[i] * S_IN) / fsum);
				$display("");
				$write("    hardware (q/128):");
				for (i = 0; i < c; i = i + 1) begin
					hv = omem[(1 + i) * 4];
					$write(" %5.3f", hv / 128.0);
				end
				$display("");
				$write("    hardware (raw q):");
				for (i = 0; i < c; i = i + 1) begin
					hv = omem[(1 + i) * 4];
					$write(" %5d", hv);
				end
				$display("");
				$display("    winner: class %0d (largest logit %0d), hardware's largest probability: class %0d", best, lg[best], hwbest);
			end
			runs = runs + 1;
			$display("  softmax, %3d classes: %5d cycles, largest difference from float softmax %0.4f, %0d errors%0s",
			         c, cycles, maxerr, errors - e0, (pct == 100) ? "" : "  (packets arrive irregularly)");
		end
	endtask

	// ================================================================ global average pooling
	reg signed [31:0] gsum [0:255];

	task gap(input integer h, input integer wd, input integer c, input integer pct);
		integer g, oh, ow, j, i, n, cc, e0, mg, sg, hw;
		reg signed [31:0] r, q;
		reg signed [7:0]  hv;
		real fmean, err, maxerr;
		begin
			e0 = errors;
			hw = h * wd;
			while (c > 1 && c * h * ((wd + 3) / 4) > NPMAX) c = c - 1;      // the packet list must fit the array
			sg = 0;
			while ($rtoi((1.0 / hw) * (2.0 ** (sg + 1)) + 0.5) <= 32767 && sg < 47) sg = sg + 1;
			mg = $rtoi((1.0 / hw) * (2.0 ** sg) + 0.5);

			for (cc = 0; cc < c; cc = cc + 1) gsum[cc] = 0;
			n = 0;
			for (g = 0; g < (c + 3) / 4; g = g + 1)
				for (oh = 0; oh < h; oh = oh + 1)
					for (ow = 0; ow < wd; ow = ow + 4)
						for (j = 0; j < 4; j = j + 1)
							if (4 * g + j < c) begin
								cc = 4 * g + j;
								for (i = 0; i < LANES; i = i + 1) begin
									p_data[n][i*32 +: 32] = (ow + i < wd) ? 32'($random % 40000) : 32'd0;
									p_be[n][i] = (ow + i < wd);
									if (ow + i < wd) begin
										r = f_clamp(f_req(p_data[n][i*32 +: 32], 15521, 0, 22), -128, 127);
										gsum[cc] = gsum[cc] + r;
									end
								end
								p_row[n] = oh[7:0]; p_col[n] = ow[7:0]; p_chan[n] = cc[7:0];
								n = n + 1;
							end
			n_pkts = n;

			clear_sections;
			section(0, c);                                               // prologue, once per channel: clear its sum
			emit(LI(1, 15521)); emit(LI(2, 0)); emit(SETQ(0, 1, 2, 22)); // q0: requantize + ReLU
			emit(LI(1, mg)); emit(SETQ(1, 1, 1, sg));                    // q1: x 1/(H*W)
			emit(LI(3, -128)); emit(LI(4, 127)); emit(SETC(0, 3, 4));
			emit(LI(10, 1)); emit(LI(11, 1));
			emit(TAG(1, T_ITER)); emit(VLI(1, 0)); emit(STS(1, 1));
			section(1, 0);                                               // body: add this packet's pixels to its channel
			emit(REQ(0, 7, 0)); emit(CLAMP(0, 0, 0));
			emit(TAG(1, T_CHAN)); emit(LDS(1, 1));
			emit(RADD(2, 0)); emit(BCAST(2, 2)); emit(ADD(1, 1, 2)); emit(STS(1, 1));
			section(2, c);                                               // epilogue, once per channel: divide, store
			emit(TAG(1, T_ITER)); emit(LDS(1, 1)); emit(REQ(1, 1, 1));
			emit(ADDS(5, 10, 1)); emit(ST8A(1, 5, 11, 0));

			run_program(pct);

			maxerr = 0.0;
			for (cc = 0; cc < c; cc = cc + 1) begin
				q  = f_clamp(f_req(gsum[cc], mg[15:0], mg[15:0], sg[5:0]), -128, 127);
				hv = omem[(1 + cc) * 4];
				if (owr[(1 + cc) * 4] != 1 || hv != q) begin
					errors = errors + 1;
					if (errors - e0 <= 5) $display("    FAIL channel %0d: got %0d (written %0d times), expected %0d", cc, hv, owr[(1 + cc) * 4], q);
				end
				fmean = $itor(gsum[cc]) / hw;
				err   = hv - fmean;
				if (err < 0.0) err = -err;
				if (err > maxerr) maxerr = err;
				if (show != 0 && cc < 8)
					$display("    channel %0d: sum of %0d int8 values = %0d, exact mean %8.3f, hardware %4d", cc, hw, gsum[cc], fmean, hv);
			end
			runs = runs + 1;
			$display("  global average pooling %2dx%-2d x%3d (1/(H*W) = %0d / 2^%0d): %6d packets, %7d cycles, max |hw - mean| %0.3f, %0d errors%0s",
			         h, wd, c, mg, sg, n, cycles, maxerr, errors - e0, (pct == 100) ? "" : "  (packets arrive irregularly)");
		end
	endtask

	integer t;

	initial begin
		if ($test$plusargs("vcd")) begin
			$dumpfile("waveforms/vu_post.vcd");
			$dumpvars(0, tb_vu_post);
		end
		errors = 0; runs = 0; show = 0; max_err_all = 0.0; cycles = 0; t0 = 0; cur_sec = 0;
		p_idx = 0; n_pkts = 0; avail_pct = 100; avail = 1'b1;
		pm_we = 1'b0; pm_waddr = 0; pm_wdata = 0; lut_we = 1'b0; lut_waddr = 0; lut_wdata = 0;
		layer_start = 1'b0; layer_end = 1'b0;
		clear_sections;
		ps0 = 0; ps1 = 0; ps2 = 0; ps3 = 0; ps4 = 0; ps5 = 0; pl0 = 0; pl1 = 0; pl2 = 0; pl3 = 0; pl4 = 0; pl5 = 0;
		pc0 = 0; pc2 = 0; pc3 = 0; pc4 = 0; pc5 = 0;
		for (t = 0; t < NPMAX; t = t + 1) begin
			p_data[t] = {W{1'b0}}; p_be[t] = 0; p_row[t] = 0; p_col[t] = 0; p_chan[t] = 0;
		end
		rst_n = 1'b0;
		repeat (2) @(negedge clk);
		rst_n = 1'b1;

		$display("");
		$display("Softmax and global average pooling on the vector_unit RTL, with repeated sections (TAG iter).");
		$display("");
		$display("1) Softmax over the classes. One int8 logit step = 0.1; the lookup table holds exp(d * 0.1) in Q15.");
		$display("   body:      REQ, CLAMP, TAG chan, STS (logit -> local memory), MAX (running max)");
		$display("   epilogue0: x classes: LDS, SUB max, CLAMP -128..0, LUT (exp), STS, ADD (running sum)");
		$display("   epilogue1: once: RADD (sum), RCP 2^30/sum, BCAST");
		$display("   epilogue2: x classes: LDS, MUL by 2^30/sum, SHRR 23 (= probability x 128), ST8A");
		load_exp_table;
		show = 1;
		softmax(10, 100);
		show = 0;
		softmax(10, 100);
		softmax(2, 100);
		softmax(1, 100);
		softmax(100, 70);
		softmax(256, 100);
		for (t = 0; t < 15; t = t + 1) softmax(1 + {$random} % 256, 40 + {$random} % 61);

		$display("");
		$display("2) Global average pooling: one int8 average per channel of a feature map (after requantize + ReLU).");
		$display("   prologue:  x channels: clear that channel's sum in local memory (TAG iter, STS)");
		$display("   body:      REQ, CLAMP, LDS sum[chan], RADD (this packet's pixels), ADD, STS");
		$display("   epilogue:  x channels: LDS, REQ with 1/(H*W), ST8A");
		show = 1;
		gap(7, 7, 4, 100);
		show = 0;
		gap(14, 14, 16, 100);
		gap(1, 1, 3, 100);
		gap(5, 13, 10, 60);
		gap(32, 32, 64, 100);
		for (t = 0; t < 12; t = t + 1) gap(1 + {$random} % 32, 1 + {$random} % 32, 1 + {$random} % 128, 40 + {$random} % 61);

		$display("");
		$display("Totals: %0d runs, %0d errors; largest difference of a softmax probability from float: %0.4f",
		         runs, errors, max_err_all);
		$display("");
		if (errors != 0) $fatal(1, "FAIL");
		$display("PASS: every softmax probability and channel average matches the bit-exact reference");
		$finish;
	end
endmodule
