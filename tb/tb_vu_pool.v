`timescale 1ns/1ps

// The pooling programs (2x2 max, 4x4 max, 2x2 average) running on the real vector_unit RTL.
// Packets come in the array's exact order with real tags; every ST8A lands in an output memory model;
// the pooled maps are compared with a reference pooling of the requantized feature map.
module tb_vu_pool;
	localparam LANES = 4;
	localparam ADDR  = 11;
	localparam W     = LANES * 32;
	localparam MAXC  = 16;
	localparam MAXHW = 64;
	localparam NPMAX = MAXC * MAXHW * (MAXHW / 4);
	localparam OMAX  = 2048;

	reg                 clk, rst_n;
	reg                 lut_we_tb = 1'b0;
	reg  [7:0]          lut_wa_tb = 8'd0;
	reg  [15:0]         lut_wd_tb = 16'd0;
	reg                 pm_we;
	reg  [5:0]          pm_waddr;
	reg  [31:0]         pm_wdata;
	reg  [5:0]          pro_start, body_start, epi_start;
	reg  [6:0]          pro_len, body_len, epi_len;
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
	reg                 p_last [0:NPMAX-1];
	integer             p_idx, n_pkts, avail_pct;
	reg                 avail;
	wire [31:0]         pi = (p_idx < NPMAX) ? p_idx : 0;

	vector_unit #(.LANES(LANES), .ADDR(ADDR), .PM_AW(6)) dut (
		.clk(clk), .rst_n(rst_n),
		.pm_we(pm_we), .pm_waddr(pm_waddr), .pm_wdata(pm_wdata),
		.lut_we(lut_we_tb), .lut_waddr(lut_wa_tb), .lut_wdata(lut_wd_tb),
		.pro_start(pro_start), .pro_len(pro_len), .body_start(body_start), .body_len(body_len),
		.epi_start(epi_start), .epi_len(epi_len),
		.layer_start(layer_start), .layer_end(layer_end), .busy(unused_busy), .done(done),
		.pkt_valid(pkt_valid), .pkt_ready(pkt_ready),
		.pkt_data(p_data[pi]), .pkt_addr(11'd0), .pkt_be(p_be[pi]),
		.pkt_row(p_row[pi]), .pkt_col(p_col[pi]), .pkt_chan(p_chan[pi]), .pkt_last(p_last[pi]),
		.st_en(st_en), .st_addr(st_addr), .st_be(st_be), .st_data(st_data)
	);

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

	reg  [31:0] prg [0:63];

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

	// ================================================================ assembler
	integer np, n_pro;

	function [31:0] enc(input [5:0] op, input [3:0] d, input [3:0] a, input [3:0] b, input [10:0] x);
		enc = {op, 3'b000, d, a, b, x};
	endfunction
	task emit(input [31:0] w);
		begin
			if (np >= 64) $fatal(1, "program longer than 64 instructions");
			prg[np] = w;
			np = np + 1;
		end
	endtask
	task emitp(input [2:0] p, input [31:0] w);
		emit({w[31:26], p, w[22:0]});
	endtask
	function [31:0] LI(input [3:0] d, input integer v);  LI = {6'h01, 3'b000, d, v[18:0]}; endfunction
	function [31:0] ADDS(input [3:0] d, input [3:0] a, input [3:0] b); ADDS = enc(6'h04, d, a, b, 11'd0); endfunction
	function [31:0] ADDIS(input [3:0] d, input [3:0] a, input integer v); ADDIS = {6'h05, 3'b000, d, a, v[14:0]}; endfunction
	function [31:0] SHLS(input [3:0] d, input [3:0] a, input integer n); SHLS = enc(6'h06, d, a, 4'd0, n[10:0]); endfunction
	function [31:0] SHRS(input [3:0] d, input [3:0] a, input integer n); SHRS = enc(6'h07, d, a, 4'd0, n[10:0]); endfunction
	function [31:0] TAG(input [3:0] d, input integer f); TAG = enc(6'h08, d, 4'd0, 4'd0, f[10:0]); endfunction
	function [31:0] SETQ(input [3:0] q, input [3:0] a, input [3:0] b, input integer s); SETQ = enc(6'h09, q, a, b, s[10:0]); endfunction
	function [31:0] SETC(input [3:0] c, input [3:0] a, input [3:0] b); SETC = enc(6'h0A, c, a, b, 11'd0); endfunction
	function [31:0] SETP(input [3:0] p, input integer tag, input integer op, input integer k, input integer v);
		reg [9:0] val;
		begin
			val  = {k[3:0], v[5:0]};
			SETP = enc(6'h0C, p, 4'd0, val[9:6], {val[5:0], op[1:0], tag[2:0]});
		end
	endfunction
	function [31:0] ANDIS(input [3:0] d, input [3:0] a, input integer v); ANDIS = {6'h0D, 3'b000, d, a, v[14:0]}; endfunction
	function [31:0] MULS(input [3:0] d, input [3:0] a, input [3:0] b); MULS = enc(6'h0E, d, a, b, 11'd0); endfunction
	function [31:0] SLLV(input [3:0] d, input [3:0] a, input [3:0] b); SLLV = enc(6'h0F, d, a, b, 11'd0); endfunction
	function [31:0] SETR(input integer r, input [3:0] a); SETR = enc(6'h14, 4'd0, a, 4'd0, r[10:0]); endfunction
	function [31:0] ADD(input [3:0] d, input [3:0] a, input [3:0] b); ADD = enc(6'h18, d, a, b, 11'd0); endfunction
	function [31:0] MAX(input [3:0] d, input [3:0] a, input [3:0] b); MAX = enc(6'h1B, d, a, b, 11'd0); endfunction
	function [31:0] SHRR(input [3:0] d, input [3:0] a, input integer n); SHRR = enc(6'h1F, d, a, 4'd0, n[10:0]); endfunction
	function [31:0] REQ(input [3:0] d, input [3:0] a, input integer q); REQ = enc(6'h21, d, a, 4'd0, q[10:0]); endfunction
	function [31:0] CLAMP(input [3:0] d, input [3:0] a, input integer c); CLAMP = enc(6'h22, d, a, 4'd0, c[10:0]); endfunction
	function [31:0] MAXP(input [3:0] d, input [3:0] a); MAXP = enc(6'h30, d, a, 4'd0, 11'd0); endfunction
	function [31:0] ADDP(input [3:0] d, input [3:0] a); ADDP = enc(6'h31, d, a, 4'd0, 11'd0); endfunction
	function [31:0] PERM(input [3:0] d, input [3:0] a, input integer p); PERM = enc(6'h34, d, a, 4'd0, p[10:0]); endfunction
	function [31:0] ST8A(input [3:0] a, input [3:0] sad, input [3:0] smask, input integer c); ST8A = enc(6'h39, smask, a, sad, c[10:0]); endfunction
	function [31:0] LDS(input [3:0] d, input [3:0] sa); LDS = enc(6'h3B, d, sa, 4'd0, 11'd0); endfunction
	function [31:0] STS(input [3:0] a, input [3:0] sb); STS = enc(6'h3C, 4'd0, a, sb, 11'd0); endfunction

	localparam T_ROW = 2, T_PADDR = 6, T_PBE = 7, T_LMIDX = 8;
	localparam OP_LOWEQ = 2, OP_LOWNE = 3;

	// ================================================================ the pooling programs
	// Registers fixed by the prologue:  s10 = output base word, s11 = output channel pitch, s12 = output row pitch.
	// Packets carry raw accumulators; every program first requantizes (q0) and clamps to int8 (c0).
	integer pool_k, pool_avg, out_h, out_w, out_rp, out_ch, out_base;
	integer q_m, q_mn, q_s;

	// ---------------------------------------------------------------- the same programs with the address unit
	task prologue_fast(input integer l);
		begin
			np = 0;
			emit(LI(1, q_m)); emit(LI(2, q_mn)); emit(SETQ(0, 1, 2, q_s));
			emit(LI(3, -128)); emit(LI(4, 127)); emit(SETC(0, 3, 4));
			emit(LI(1, out_base)); emit(SETR(0, 1));
			emit(LI(1, out_ch));   emit(SETR(1, 1));
			emit(LI(1, out_rp));   emit(SETR(2, 1));
			emit(LI(1, l));        emit(SETR(3, 1));
		end
	endtask

	task program_2x2_fast(input integer avg);
		begin
			prologue_fast(1);
			emit(SETP(2, T_ROW, OP_LOWEQ, 1, 0));
			emit(SETP(3, T_ROW, OP_LOWEQ, 1, 1));
			n_pro = np;
			emit(REQ(0, 7, 0)); emit(CLAMP(0, 0, 0));
			if (avg != 0) emit(ADDP(1, 0)); else emit(MAXP(1, 0));
			emit(TAG(6, T_LMIDX));
			emitp(3'd2, STS(1, 6));
			emitp(3'd3, LDS(2, 6));
			if (avg != 0) begin
				emitp(3'd3, ADD(1, 1, 2));
				emitp(3'd3, SHRR(1, 1, 2));
			end
			else emitp(3'd3, MAX(1, 1, 2));
			emit(PERM(1, 1, 8'b01_00_01_00));
			emit(TAG(9, T_PADDR)); emit(TAG(5, T_PBE));
			emitp(3'd3, ST8A(1, 9, 5, 0));
		end
	endtask

	task program_4x4_fast;
		begin
			prologue_fast(2);
			emit(SETP(2, T_ROW, OP_LOWNE, 2, 0));
			emit(SETP(3, T_ROW, OP_LOWNE, 2, 3));
			emit(SETP(4, T_ROW, OP_LOWEQ, 2, 3));
			n_pro = np;
			emit(REQ(0, 7, 0)); emit(CLAMP(0, 0, 0));
			emit(MAXP(1, 0)); emit(MAXP(1, 1));
			emit(TAG(6, T_LMIDX));
			emitp(3'd2, LDS(2, 6));
			emitp(3'd2, MAX(1, 1, 2));
			emitp(3'd3, STS(1, 6));
			emit(PERM(1, 1, 8'b00_00_00_00));
			emit(TAG(9, T_PADDR)); emit(TAG(5, T_PBE));
			emitp(3'd4, ST8A(1, 9, 5, 0));
		end
	endtask


	// ================================================================ output memory model
	reg  [7:0]  omem [0:OMAX*4-1];
	integer     owr  [0:OMAX*4-1];
	integer     bad_st;

	initial begin : collect
		integer i;
		forever begin
			@(negedge clk);
			if (st_en) begin
				if (st_addr >= OMAX) bad_st = bad_st + 1;
				else
					for (i = 0; i < LANES; i = i + 1)
						if (st_be[i]) begin
							omem[st_addr*4 + i] = st_data[i*8 +: 8];
							owr[st_addr*4 + i]  = owr[st_addr*4 + i] + 1;
						end
			end
		end
	end

	reg took;
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

	// ================================================================ layers
	integer fh, fw, fc;
	reg signed [31:0] acc [0:MAXC*MAXHW*MAXHW-1];
	reg signed [7:0]  q8  [0:MAXC*MAXHW*MAXHW-1];
	integer           errors, layers, pkts_total, show, cyc_total;

	function integer fi(input integer c, input integer y, input integer x);
		fi = (c * MAXHW + y) * MAXHW + x;
	endfunction

	task run_layer(input integer h, input integer wd, input integer c, input integer k, input integer avg, input integer pct);
		integer g, oh, ow, j, i, y, x, cc, e0, oy, ox, dy, dx, best, sum, idx, written, extra, n, t0;
		reg signed [31:0] r;
		reg signed [7:0]  hv;
		begin
			out_h  = h / k;
			out_w  = wd / k;
			out_rp = (out_w + 3) / 4;
			out_ch = out_h * out_rp;
			// the pooled map must fit the 11-bit store address (2048 words), like a real output buffer
			while (c > 1 && 1 + c * out_ch > OMAX) c = c - 1;
			fh = h; fw = wd; fc = c; pool_k = k; pool_avg = avg;
			out_base = 1;
			q_m = 15521; q_s = 22; q_mn = (avg != 0) ? q_m : 0;
			e0 = errors;

			for (cc = 0; cc < c; cc = cc + 1)
				for (y = 0; y < h; y = y + 1)
					for (x = 0; x < wd; x = x + 1) begin
						acc[fi(cc, y, x)] = $random % 40000;
						r = f_clamp(f_req(acc[fi(cc, y, x)], q_m, q_mn, q_s), -128, 127);
						q8[fi(cc, y, x)] = r[7:0];
					end

			n = 0;
			for (g = 0; g < (c + 3) / 4; g = g + 1)
				for (oh = 0; oh < h; oh = oh + 1)
					for (ow = 0; ow < wd; ow = ow + 4)
						for (j = 0; j < 4; j = j + 1)
							if (4 * g + j < c) begin
								cc = 4 * g + j;
								for (i = 0; i < LANES; i = i + 1) begin
									p_data[n][i*32 +: 32] = (ow + i < wd) ? acc[fi(cc, oh, ow + i)] : 32'sd0;
									p_be[n][i] = (ow + i < wd);
								end
								p_row[n] = oh[7:0]; p_col[n] = ow[7:0]; p_chan[n] = cc[7:0]; p_last[n] = (j == 3);
								n = n + 1;
							end
			n_pkts = n;
			pkts_total = pkts_total + n;

			if (k == 4) program_4x4_fast; else program_2x2_fast(avg);
			for (i = 0; i < np; i = i + 1) begin
				@(negedge clk);
				pm_we    = 1'b1;
				pm_waddr = i[5:0];
				pm_wdata = prg[i];
			end
			@(negedge clk);
			pm_we      = 1'b0;
			pro_start  = 6'd0;
			pro_len    = n_pro[6:0];
			body_start = n_pro[5:0];
			body_len   = 7'(np - n_pro);
			epi_start  = 6'd0;
			epi_len    = 7'd0;

			for (i = 0; i < OMAX * 4; i = i + 1) begin omem[i] = 8'hAA; owr[i] = 0; end
			bad_st = 0;
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
			repeat (3) @(negedge clk);
			cyc_total = cyc_total + ($time - t0) / 10;

			written = 0;
			for (cc = 0; cc < c; cc = cc + 1)
				for (oy = 0; oy < out_h; oy = oy + 1)
					for (ox = 0; ox < out_w; ox = ox + 1) begin
						best = -1000; sum = 0;
						for (dy = 0; dy < k; dy = dy + 1)
							for (dx = 0; dx < k; dx = dx + 1) begin
								x = q8[fi(cc, oy * k + dy, ox * k + dx)];
								if (x > best) best = x;
								sum = sum + x;
							end
						if (avg != 0) best = (sum + 2) >>> 2;
						idx = (out_base + cc * out_ch + oy * out_rp + ox / 4) * 4 + ox % 4;
						hv  = omem[idx];
						written = written + 1;
						if (owr[idx] != 1 || hv != best) begin
							errors = errors + 1;
							if (errors - e0 <= 5)
								$display("    FAIL ch %0d out (%0d,%0d): got %0d (written %0d times), expected %0d",
								         cc, oy, ox, hv, owr[idx], best);
						end
					end
			extra = 0;
			for (i = 0; i < OMAX * 4; i = i + 1) extra = extra + owr[i];
			if (extra != written || bad_st != 0) begin
				errors = errors + 1;
				$display("    FAIL: %0d bytes written, %0d expected (%0d stores outside the memory)", extra, written, bad_st);
			end
			layers = layers + 1;
			if (show != 0) show_layer;
			$display("  %2dx%-2d x%2d  %0s %0dx%0d -> %2dx%-2d: %5d packets, %6d cycles (%0.1f per packet), %0d errors%0s",
			         h, wd, c, (avg != 0) ? "avg" : "max", k, k, out_h, out_w, n, ($time - t0) / 10,
			         $itor(($time - t0) / 10) / n, errors - e0, (pct == 100) ? "" : "  (packets arrive irregularly)");
		end
	endtask

	task show_layer;
		integer y, x, idx;
		reg signed [7:0] v;
		begin
			$display("    channel 0 after requantization (int8), the input to the pooling:");
			for (y = 0; y < fh; y = y + 1) begin
				$write("     ");
				for (x = 0; x < fw; x = x + 1) begin
					v = q8[fi(0, y, x)];
					$write(" %4d", v);
					if (x % pool_k == pool_k - 1 && x != fw - 1) $write(" |");
				end
				$display("");
				if (y % pool_k == pool_k - 1 && y != fh - 1) $display("");
			end
			$display("    channel 0 pooled by the hardware, read back from the output memory:");
			for (y = 0; y < out_h; y = y + 1) begin
				$write("     ");
				for (x = 0; x < out_w; x = x + 1) begin
					idx = (out_base + y * out_rp + x / 4) * 4 + x % 4;
					v = omem[idx];
					$write(" %4d", v);
				end
				$display("");
			end
		end
	endtask

	integer t;

	initial begin
		if ($test$plusargs("vcd")) begin
			$dumpfile("waveforms/vu_pool.vcd");
			$dumpvars(0, tb_vu_pool);
		end
		errors = 0; layers = 0; pkts_total = 0; show = 0; cyc_total = 0; bad_st = 0;
		p_idx = 0; n_pkts = 0; avail_pct = 100; avail = 1'b1;
		pm_we = 1'b0; pm_waddr = 0; pm_wdata = 0;
		pro_start = 0; pro_len = 0; body_start = 0; body_len = 0; epi_start = 0; epi_len = 0;
		layer_start = 1'b0; layer_end = 1'b0;
		for (t = 0; t < NPMAX; t = t + 1) begin
			p_data[t] = {W{1'b0}}; p_be[t] = 0; p_row[t] = 0; p_col[t] = 0; p_chan[t] = 0; p_last[t] = 0;
		end
		rst_n = 1'b0;
		repeat (2) @(negedge clk);
		rst_n = 1'b1;

		$display("");
		$display("Pooling on the vector_unit RTL: the same programs that were proven on the model,");
		$display("feature maps fed as packets in the array's order, every ST8A collected in an output memory.");

		$display("");
		$display("1) 2x2 max pooling, stride 2 (after requantize + ReLU):");
		show = 1;
		run_layer(6, 10, 2, 2, 0, 100);
		show = 0;
		run_layer(28, 28, 8, 2, 0, 100);
		run_layer(2, 2, 1, 2, 0, 100);
		run_layer(3, 3, 1, 2, 0, 100);
		run_layer(7, 13, 5, 2, 0, 60);
		run_layer(9, 61, 4, 2, 0, 100);
		run_layer(64, 64, 2, 2, 0, 100);

		$display("");
		$display("2) 4x4 max pooling, stride 4:");
		show = 1;
		run_layer(8, 12, 1, 4, 0, 100);
		show = 0;
		run_layer(16, 16, 6, 4, 0, 100);
		run_layer(4, 4, 1, 4, 0, 100);
		run_layer(7, 7, 2, 4, 0, 50);
		run_layer(13, 30, 5, 4, 0, 100);

		$display("");
		$display("3) 2x2 average pooling, stride 2 (requantize without ReLU, so negative values too):");
		show = 1;
		run_layer(4, 8, 1, 2, 1, 100);
		show = 0;
		run_layer(14, 14, 8, 2, 1, 100);
		run_layer(5, 9, 3, 2, 1, 70);
		run_layer(32, 40, 4, 2, 1, 100);

		$display("");
		$display("4) 30 random shapes (height and width 2..64, 1..16 channels, all three kinds, irregular packets;");
		$display("   channels reduced where the pooled map would not fit the 2048-word store address range):");
		for (t = 0; t < 30; t = t + 1)
			case (t % 3)
				0: run_layer(2 + {$random} % 63, 2 + {$random} % 63, 1 + {$random} % 16, 2, 0, 40 + {$random} % 61);
				1: run_layer(4 + {$random} % 61, 4 + {$random} % 61, 1 + {$random} % 16, 4, 0, 40 + {$random} % 61);
				default: run_layer(2 + {$random} % 63, 2 + {$random} % 63, 1 + {$random} % 16, 2, 1, 40 + {$random} % 61);
			endcase

		$display("");
		$display("Totals: %0d layers, %0d packets, %0d cycles, %0d errors", layers, pkts_total, cyc_total, errors);
		$display("");
		if (errors != 0) $fatal(1, "FAIL");
		$display("PASS: every pooled value from the hardware matches the reference, written exactly once");
		$finish;
	end
endmodule
