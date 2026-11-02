`timescale 1ns/1ps

module tb_vector_unit;
	localparam LANES = 4;
	localparam ADDR  = 11;
	localparam NPKT  = 1024;
	localparam QMAX  = 4096;

	reg                    clk, rst_n;
	reg                    lut_we_tb = 1'b0;
	reg  [7:0]             lut_wa_tb = 8'd0;
	reg  [15:0]            lut_wd_tb = 16'd0;
	reg                    pm_we;
	reg  [5:0]             pm_waddr;
	reg  [31:0]            pm_wdata;
	reg  [5:0]             pro_start, body_start, epi_start;
	reg  [6:0]             pro_len, body_len, epi_len;
	reg                    layer_start, layer_end;
	wire                   busy, done;
	wire                   pkt_valid, pkt_ready;
	wire [LANES*32-1:0]    pkt_data;
	wire [ADDR-1:0]        pkt_addr;
	wire [LANES-1:0]       pkt_be;
	wire                   st_en;
	wire [ADDR-1:0]        st_addr;
	wire [LANES-1:0]       st_be;
	wire [LANES*8-1:0]     st_data;

	reg  [LANES*32-1:0]    p_data [0:NPKT-1];
	reg  [ADDR-1:0]        p_addr [0:NPKT-1];
	reg  [LANES-1:0]       p_be   [0:NPKT-1];
	reg  [7:0]             p_chan [0:NPKT-1];
	integer                p_idx, n_pkts, avail_pct;
	reg                    avail;

	reg  [ADDR-1:0]        e_addr [0:QMAX-1];
	reg  [LANES-1:0]       e_be   [0:QMAX-1];
	reg  [LANES*8-1:0]     e_data [0:QMAX-1];
	reg  [LANES*32-1:0]    e_in   [0:QMAX-1];
	reg  [LANES*32-1:0]    e_mid  [0:QMAX-1];
	integer                e_kind [0:QMAX-1];
	integer                e_pkt  [0:QMAX-1];
	integer                show_left, fdo;
	integer                e_head, e_tail, errors, stores, cyc, prog;

	reg  signed [31:0]     sum_r [0:LANES-1];
	reg  signed [31:0]     best_v, best_show;
	integer                q_m, q_s, q_mode, sweep_lo;
	real                   q_scale;
	integer                best_c, nshow4;
	integer                t_first, t_last;

	vector_unit #(.LANES(LANES), .ADDR(ADDR), .PM_AW(6)) dut (
		.clk(clk), .rst_n(rst_n),
		.pm_we(pm_we), .pm_waddr(pm_waddr), .pm_wdata(pm_wdata),
		.lut_we(lut_we_tb), .lut_waddr(lut_wa_tb), .lut_wdata(lut_wd_tb),
		.pro_start(pro_start), .pro_len(pro_len), .body_start(body_start), .body_len(body_len),
		.epi_start(epi_start), .epi_len(epi_len),
		.layer_start(layer_start), .layer_end(layer_end), .busy(busy), .done(done),
		.pkt_valid(pkt_valid), .pkt_ready(pkt_ready), .pkt_data(pkt_data), .pkt_addr(pkt_addr), .pkt_be(pkt_be),
		.pkt_row(8'd0), .pkt_col(8'd0), .pkt_chan(p_chan[(p_idx < NPKT) ? p_idx : 0]), .pkt_last(1'b0),
		.st_en(st_en), .st_addr(st_addr), .st_be(st_be), .st_data(st_data)
	);

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

	always @(posedge clk) cyc <= cyc + 1;

	// ---------------------------------------------------------------- assembler
	function [18:0] f19(input integer v);
		begin
			if (v < -262144 || v > 262143) $fatal(1, "assembler: immediate %0d does not fit 19 bits", v);
			f19 = v[18:0];
		end
	endfunction
	function [15:0] f16(input integer v);
		begin
			if (v < 0 || v > 65535) $fatal(1, "assembler: immediate %0d does not fit 16 bits", v);
			f16 = v[15:0];
		end
	endfunction
	function [14:0] f15(input integer v);
		begin
			if (v < -16384 || v > 32767) $fatal(1, "assembler: immediate %0d does not fit 15 bits", v);
			f15 = v[14:0];
		end
	endfunction
	function [10:0] f11(input integer v);
		begin
			if (v < 0 || v > 2047) $fatal(1, "assembler: field %0d does not fit 11 bits", v);
			f11 = v[10:0];
		end
	endfunction
	function [31:0] enc(input [5:0] op, input [3:0] d, input [3:0] a, input [3:0] b, input [10:0] x);
		enc = {op, 3'b000, d, a, b, x};
	endfunction
	function [31:0] LI(input [3:0] d, input integer imm);    LI    = {6'h01, 3'b000, d, f19(imm)};          endfunction
	function [31:0] LUI(input [3:0] d, input integer imm);   LUI   = {6'h02, 3'b000, d, 3'b000, f16(imm)};  endfunction
	function [31:0] ORI(input [3:0] d, input integer imm);   ORI   = {6'h03, 3'b000, d, 3'b000, f16(imm)};  endfunction
	function [31:0] TAG(input [3:0] d, input integer f);     TAG   = enc(6'h08, d, 4'd0, 4'd0, f11(f));     endfunction
	function [31:0] SETQ(input [3:0] q, input [3:0] a, input [3:0] b, input integer s); SETQ = enc(6'h09, q, a, b, f11(s)); endfunction
	function [31:0] SETC(input [3:0] c, input [3:0] a, input [3:0] b); SETC = enc(6'h0A, c, a, b, 11'd0); endfunction
	function [31:0] MOV(input [3:0] d, input [3:0] a);       MOV   = enc(6'h10, d, a, 4'd0, 11'd0);          endfunction
	function [31:0] VLI(input [3:0] d, input integer imm);   VLI   = {6'h11, 3'b000, d, 4'd0, f15(imm)};    endfunction
	function [31:0] BCAST(input [3:0] d, input [3:0] a);     BCAST = enc(6'h12, d, a, 4'd0, 11'd0);          endfunction
	function [31:0] ADD(input [3:0] d, input [3:0] a, input [3:0] b); ADD = enc(6'h18, d, a, b, 11'd0);     endfunction
	function [31:0] SUB(input [3:0] d, input [3:0] a, input [3:0] b); SUB = enc(6'h19, d, a, b, 11'd0);     endfunction
	function [31:0] ADDI(input [3:0] d, input [3:0] a, input integer imm); ADDI = {6'h1A, 3'b000, d, a, f15(imm)}; endfunction
	function [31:0] MAX(input [3:0] d, input [3:0] a, input [3:0] b); MAX = enc(6'h1B, d, a, b, 11'd0);     endfunction
	function [31:0] MIN(input [3:0] d, input [3:0] a, input [3:0] b); MIN = enc(6'h1C, d, a, b, 11'd0);     endfunction
	function [31:0] SHL(input [3:0] d, input [3:0] a, input integer n);  SHL  = enc(6'h1D, d, a, 4'd0, f11(n)); endfunction
	function [31:0] SHR(input [3:0] d, input [3:0] a, input integer n);  SHR  = enc(6'h1E, d, a, 4'd0, f11(n)); endfunction
	function [31:0] SHRR(input [3:0] d, input [3:0] a, input integer n); SHRR = enc(6'h1F, d, a, 4'd0, f11(n)); endfunction
	function [31:0] MUL(input [3:0] d, input [3:0] a, input [3:0] b); MUL = enc(6'h20, d, a, b, 11'd0);     endfunction
	function [31:0] REQ(input [3:0] d, input [3:0] a, input integer q);   REQ   = enc(6'h21, d, a, 4'd0, f11(q)); endfunction
	function [31:0] CLAMP(input [3:0] d, input [3:0] a, input integer c); CLAMP = enc(6'h22, d, a, 4'd0, f11(c)); endfunction
	function [31:0] ST8(input [3:0] a, input integer c);     ST8   = enc(6'h38, 4'd0, a, 4'd0, f11(c));     endfunction
	function [31:0] TAGF(input [3:0] d, input integer f);    TAGF  = enc(6'h08, d, 4'd0, 4'd0, f11(f));     endfunction
	function [31:0] CMPGT(input [3:0] a, input [3:0] b);     CMPGT = enc(6'h28, 4'd0, a, b, 11'd0);         endfunction
	function [31:0] P(input [2:0] p, input [31:0] w);
		begin
			if (w[25:23] != 3'd0) $fatal(1, "assembler: instruction already has a predicate");
			P = {w[31:26], p, w[22:0]};
		end
	endfunction

	// ---------------------------------------------------------------- reference arithmetic (the spec, in 64 bits)
	function signed [31:0] sat32(input signed [63:0] x);
		begin
			if (x > 64'sd2147483647)       sat32 = 32'sh7FFFFFFF;
			else if (x < -64'sd2147483648) sat32 = 32'sh80000000;
			else                           sat32 = x[31:0];
		end
	endfunction
	function signed [31:0] req(input signed [31:0] a, input signed [15:0] mp, input signed [15:0] mn, input integer s);
		reg signed [63:0] y;
		begin
			y = (a < 0) ? $signed(a) * mn : $signed(a) * mp;
			if (s != 0) y = (y >>> s) + ((y >>> (s - 1)) & 64'sd1);
			req = sat32(y);
		end
	endfunction
	function signed [31:0] clampv(input signed [31:0] a, input signed [31:0] l, input signed [31:0] h);
		reg signed [31:0] c;
		begin
			c = (a > l) ? a : l;
			clampv = (c < h) ? c : h;
		end
	endfunction
	function [7:0] st8b(input signed [31:0] a, input signed [31:0] l, input signed [31:0] h);
		reg signed [31:0] c;
		begin
			c = clampv(a, l, h);
			c = (c < -128) ? -32'sd128 : ((c > 127) ? 32'sd127 : c);
			st8b = c[7:0];
		end
	endfunction
	function signed [31:0] shrr(input signed [31:0] a, input integer n);
		reg signed [63:0] w;
		begin
			w = {{32{a[31]}}, a};
			if (n == 0) shrr = a;
			else begin
				w = (w >>> n) + ((w >>> (n - 1)) & 64'sd1);
				shrr = w[31:0];
			end
		end
	endfunction

	// ---------------------------------------------------------------- expected stores for each program
	localparam M1 = 15521, S1 = 22;

	task push_store(input [ADDR-1:0] ad, input [LANES-1:0] be, input [LANES*8-1:0] d,
	                input [LANES*32-1:0] din, input [LANES*32-1:0] mid, input integer kind, input integer pn);
		begin
			e_addr[e_tail] = ad;
			e_be[e_tail]   = be;
			e_data[e_tail] = d;
			e_in[e_tail]   = din;
			e_mid[e_tail]  = mid;
			e_kind[e_tail] = kind;
			e_pkt[e_tail]  = pn;
			e_tail = e_tail + 1;
		end
	endtask

	task expect_packet(input integer n);
		integer i;
		reg signed [31:0] x, v1, v2, v6;
		reg [LANES*8-1:0] w1, w2;
		reg [LANES*32-1:0] m1, m2;
		begin
			if (n < 0 || n >= NPKT) $fatal(1, "expect_packet: bad packet index");
			for (i = 0; i < LANES; i = i + 1) begin
				x = p_data[n][i*32 +: 32];
				case (prog)
					1: begin
						m1[i*32 +: 32] = req(x, M1, 0, S1);
						w1[i*8 +: 8]   = st8b(m1[i*32 +: 32], -128, 127);
					end
					2: begin
						m1[i*32 +: 32] = req(x, M1, M1 / 8, S1);
						w1[i*8 +: 8]   = st8b(m1[i*32 +: 32], -128, 50);
					end
					default: begin
						v1 = x + 5;
						v2 = v1 * 3;
						v2 = shrr(v2, 3);
						v2 = (v2 > -50) ? v2 : -50;
						v6 = v2 - x;
						v6 = (v6 < v2) ? v6 : v2;
						v6 = v6 <<< 1;
						v6 = v6 >>> 1;
						sum_r[i] = sum_r[i] + x;
						v6 = v6 + {21'd0, p_addr[n]};
						v6 = req(v6, 300, -200, 10);
						m1[i*32 +: 32] = v6;
						v6 = clampv(v6, -100, 100);
						w1[i*8 +: 8] = st8b(v6, -100, 100);
						m2[i*32 +: 32] = sum_r[i];
						w2[i*8 +: 8] = st8b(sum_r[i], 32'sh80000000, 32'sh7FFFFFFF);
					end
				endcase
			end
			if (prog == 5) begin
				for (i = 0; i < LANES; i = i + 1) begin
					x = p_data[n][i*32 +: 32];
					m1[i*32 +: 32] = req(x, 16'(q_m), 16'(q_m), q_s);
					w1[i*8 +: 8]   = st8b(m1[i*32 +: 32], -128, 127);
				end
				push_store(p_addr[n], p_be[n], w1, p_data[n], m1, (q_mode == 1) ? 8 : 7, n);
			end
			else if (prog == 4) begin
				x = p_data[n][31:0];
				if (n == 0 || x > best_v) begin
					best_v = x;
					best_c = n;
				end
			end
			else
			push_store(p_addr[n], p_be[n], w1, p_data[n], m1, (prog == 3) ? 3 : 1, n);
			if (prog == 3) push_store(p_addr[n], p_be[n], w2, p_data[n], m2, 4, n);
		end
	endtask

	// ---------------------------------------------------------------- packet source and store monitor
	assign pkt_valid = avail && (p_idx < n_pkts);
	assign pkt_data  = p_data[(p_idx < NPKT) ? p_idx : 0];
	assign pkt_addr  = p_addr[(p_idx < NPKT) ? p_idx : 0];
	assign pkt_be    = p_be[(p_idx < NPKT) ? p_idx : 0];

	reg took;

	initial begin
		took = 1'b0;
		forever begin
			@(posedge clk);
			took = pkt_valid && pkt_ready;
			if (took) begin
				if (p_idx == 0) t_first = cyc;
				expect_packet(p_idx);
			end
			@(negedge clk);
			if (took) p_idx = p_idx + 1;
			avail = ({$random} % 100) < avail_pct;
		end
	end

	initial begin
		forever begin
			@(negedge clk);
			if (st_en) begin
				stores = stores + 1;
				t_last = cyc;
				if (e_head == e_tail) begin
					errors = errors + 1;
					$display("FAIL t=%0t: unexpected store at %0d", $time, st_addr);
				end
				else begin
					if (st_addr !== e_addr[e_head] || st_be !== e_be[e_head] || st_data !== e_data[e_head]) begin
						errors = errors + 1;
						if (errors <= 10)
							$display("FAIL t=%0t: store addr=%0d be=%b data=%h, expected addr=%0d be=%b data=%h",
							         $time, st_addr, st_be, st_data, e_addr[e_head], e_be[e_head], e_data[e_head]);
					end
					show_store;
					e_head = e_head + 1;
				end
			end
		end
	end

	task show_store;
		integer i;
		reg signed [31:0] x, m, ai;
		reg signed [7:0]  hb, eb;
		reg [LANES*8-1:0] ed;
		begin
			ed = e_data[e_head];
			$fwrite(fdo, "prog %0d store %0d (packet %0d) addr %0d be %b: hw", prog, stores, e_pkt[e_head], st_addr, st_be);
			for (i = 0; i < LANES; i = i + 1) begin
				hb = st_data[i*8 +: 8];
				$fwrite(fdo, " %4d", hb);
			end
			$fwrite(fdo, "   expected");
			for (i = 0; i < LANES; i = i + 1) begin
				eb = ed[i*8 +: 8];
				$fwrite(fdo, " %4d", eb);
			end
			$fdisplay(fdo, "%0s", (st_data === e_data[e_head]) ? "" : "   MISMATCH");
			if (show_left > 0) begin
				show_left = show_left - 1;
				case (e_kind[e_head])
					1: $display("    packet %0d (addr %0d, be %b):", e_pkt[e_head], st_addr, st_be);
					3: $display("    packet %0d (addr %0d, be %b), first store (the computed chain, clamped to -100..100):",
					            e_pkt[e_head], st_addr, st_be);
					4: $display("    packet %0d, second store (running sum of all packets so far, saturated to int8):",
					            e_pkt[e_head]);
					6: begin
						hb = st_data[7:0];
						eb = ed[7:0];
						$display("    epilogue store: hw class %0d, expected %0d", hb, eb);
					end
					7: $display("    packet %0d:", e_pkt[e_head]);
					8: begin
						$write("      acc");
						for (i = 0; i < LANES; i = i + 1) begin
							ai = e_in[e_head][i*32 +: 32];
							$write(" %5d", ai);
						end
						$write("   exact");
						for (i = 0; i < LANES; i = i + 1) begin
							ai = e_in[e_head][i*32 +: 32];
							$write(" %7.3f", $itor(ai) * $itor(q_m) / (2.0 ** q_s));
						end
						$write("   ->  hw");
						for (i = 0; i < LANES; i = i + 1) begin
							hb = st_data[i*8 +: 8];
							$write(" %4d", hb);
						end
						$write("   expected");
						for (i = 0; i < LANES; i = i + 1) begin
							eb = ed[i*8 +: 8];
							$write(" %4d", eb);
						end
						$display("");
					end
					default: $display("    epilogue store (final running sum, clamped to -100..100):");
				endcase
				if (e_kind[e_head] != 6 && e_kind[e_head] != 8)
				for (i = 0; i < LANES; i = i + 1) begin
					x  = e_in[e_head][i*32 +: 32];
					m  = e_mid[e_head][i*32 +: 32];
					hb = st_data[i*8 +: 8];
					eb = ed[i*8 +: 8];
					case (e_kind[e_head])
						1: $display("      lane %0d: acc %9d  x M / 2^S = %10.3f  -> REQ %6d  -> clamp/int8: hw %4d, expected %4d",
						            i, x, $itor(x) * $itor((x < 0 && prog == 2) ? M1 / 8 : ((x < 0) ? 0 : M1)) / (2.0 ** S1) + 0.0,
						            m, hb, eb);
						3: $display("      lane %0d: input %9d  -> chain result %8d  -> hw %4d, expected %4d", i, x, m, hb, eb);
						7: $display("      lane %0d: acc %11d  x %0.6f = %12.3f  -> REQ %11d  -> int8: hw %4d, expected %4d",
						            i, x, q_scale, $itor(x) * q_scale, m, hb, eb);
						default: $display("      lane %0d: running sum %10d  -> hw %4d, expected %4d", i, m, hb, eb);
					endcase
				end
			end
		end
	endtask

	// ---------------------------------------------------------------- program loading and running
	reg [31:0] prg [0:63];
	integer    np;

	task load_program(input integer pro_n, input integer body_n, input integer epi_n);
		integer i;
		begin
			for (i = 0; i < pro_n + body_n + epi_n; i = i + 1) begin
				@(negedge clk);
				pm_we    = 1'b1;
				pm_waddr = i[5:0];
				pm_wdata = prg[i];
			end
			@(negedge clk);
			pm_we      = 1'b0;
			pro_start  = 6'd0;
			pro_len    = pro_n[6:0];
			body_start = pro_n[5:0];
			body_len   = body_n[6:0];
			epi_start  = 6'(pro_n + body_n);
			epi_len    = epi_n[6:0];
		end
	endtask

	task make_packets(input integer n, input integer range);
		integer i, j;
		begin
			for (i = 0; i < n; i = i + 1) begin
				for (j = 0; j < LANES; j = j + 1) p_data[i][j*32 +: 32] = $random % range;
				p_addr[i] = ADDR'($random);
				p_be[i]   = (({$random} % 4) == 0) ? LANES'($random) : {LANES{1'b1}};
				p_chan[i] = i[7:0];
				if (prog == 4) begin
					p_data[i] = {96'd0, 32'($random % range)};
					p_be[i]   = 4'b0001;
				end
				if (prog == 5 && q_mode == 1) begin
					for (j = 0; j < LANES; j = j + 1) p_data[i][j*32 +: 32] = sweep_lo + 4 * i + j;
					p_be[i] = {LANES{1'b1}};
				end
				if (prog == 5 && q_mode == 2) begin
					for (j = 0; j < LANES; j = j + 1)
						case ({$random} % 6)
							0:       p_data[i][j*32 +: 32] = 32'sh80000000;
							1:       p_data[i][j*32 +: 32] = 32'sh7FFFFFFF;
							2:       p_data[i][j*32 +: 32] = 0;
							3:       p_data[i][j*32 +: 32] = -1;
							4:       p_data[i][j*32 +: 32] = 1;
							default: p_data[i][j*32 +: 32] = $random;
						endcase
				end
			end
			n_pkts = n;
		end
	endtask

	task quant_program(input integer m, input integer sh);
		begin
			q_m = m;
			q_s = sh;
			prg[0] = LI(1, m); prg[1] = SETQ(0, 1, 1, sh);
			prg[2] = LI(3, -128); prg[3] = LI(4, 127); prg[4] = SETC(0, 3, 4);
			prg[5] = REQ(0, 7, 0); prg[6] = ST8(0, 0);
			load_program(5, 2, 0);
		end
	endtask

	task run_scale(input real scale, input integer show);
		integer m, sh, rng;
		real    approx;
		begin
			sh = 0;
			while ($rtoi(scale * (2.0 ** (sh + 1)) + 0.5) <= 32767 && sh < 47) sh = sh + 1;
			m = $rtoi(scale * (2.0 ** sh) + 0.5);
			approx  = $itor(m) / (2.0 ** sh);
			q_scale = scale;
			quant_program(m, sh);
			$display("  scale %0.7f  ->  M = %5d, S = %2d   (M / 2^S = %0.9f, relative error %0.5f%%)",
			         scale, m, sh, approx, 100.0 * (approx - scale) / scale);
			rng = $rtoi(200.0 / scale);
			if (rng < 2) rng = 2;
			show_left = show;
			q_mode = 0;
			run_layer("    200 packets of random accumulators", 200, rng, 100);
		end
	endtask

	task run_layer(input [8*56:1] name, input integer n, input integer range, input integer pct);
		integer t0, e0, i;
		begin
			if (e_head != e_tail) begin
				errors = errors + 1;
				$display("FAIL: %0d expected stores from the previous run never happened", e_tail - e_head);
			end
			e_head = 0;
			e_tail = 0;
			make_packets(n, range);
			for (i = 0; i < LANES; i = i + 1) sum_r[i] = 0;
			p_idx = 0;
			avail_pct = pct;
			e0 = errors;
			t0 = stores;
			@(negedge clk);
			layer_start = 1'b1;
			@(negedge clk);
			layer_start = 1'b0;
			if (!busy) begin
				errors = errors + 1;
				$display("FAIL: busy not high after layer_start");
			end
			while (p_idx < n_pkts) @(negedge clk);
			if (prog == 3) begin
				for (i = 0; i < LANES; i = i + 1) begin
					e_data[e_tail][i*8 +: 8]  = st8b(sum_r[i], -100, 100);
					e_mid[e_tail][i*32 +: 32] = sum_r[i];
				end
				e_in[e_tail]   = {(LANES*32){1'b0}};
				e_kind[e_tail] = 5;
				e_pkt[e_tail]  = n;
				e_addr[e_tail] = p_addr[n - 1];
				e_be[e_tail]   = p_be[n - 1];
				e_tail = e_tail + 1;
			end
			if (prog == 4) begin
				e_data[e_tail] = {24'd0, 8'(best_c)};
				e_mid[e_tail]  = {(LANES*32){1'b0}};
				e_in[e_tail]   = {(LANES*32){1'b0}};
				e_kind[e_tail] = 6;
				e_pkt[e_tail]  = n;
				e_addr[e_tail] = p_addr[n - 1];
				e_be[e_tail]   = p_be[n - 1];
				e_tail = e_tail + 1;
				if (nshow4 > 0) begin
					nshow4 = nshow4 - 1;
					$write("    logits (class 0..%0d):", n - 1);
					for (i = 0; i < n; i = i + 1) begin
						best_show = p_data[i][31:0];
						$write(" %0d", best_show);
					end
					$display("");
					$display("    largest logit %0d at class %0d", best_v, best_c);
				end
			end
			layer_end = 1'b1;
			@(negedge clk);
			layer_end = 1'b0;
			i = 0;
			while (!done) begin
				@(negedge clk);
				i = i + 1;
				if (i > 100000) $fatal(1, "done never arrived");
			end
			repeat (3) @(negedge clk);
			if (busy) begin
				errors = errors + 1;
				$display("FAIL: busy still high after done");
			end
			$display("  %0s: %0d packets, %0d stores, %0d errors%0s", name, n, stores - t0, errors - e0,
			         (pct == 100) ? "" : " (packets arrive irregularly)");
		end
	endtask

	initial begin
		if ($test$plusargs("vcd")) begin
			$dumpfile("waveforms/vector_unit.vcd");
			$dumpvars(0, tb_vector_unit);
		end

		fdo = $fopen("outputs/vector_unit_outputs.txt", "w");
		show_left = 0;
		errors = 0; stores = 0; cyc = 0; e_head = 0; e_tail = 0; p_idx = 0; n_pkts = 0; avail_pct = 100; avail = 1'b1;
		prog = 0; t_first = 0; t_last = 0; best_v = 0; best_show = 0; best_c = 0; nshow4 = 0;
		q_m = 0; q_s = 0; q_mode = 0; sweep_lo = 0; q_scale = 0.0;
		pm_we = 1'b0; pm_waddr = 0; pm_wdata = 0;
		pro_start = 0; pro_len = 0; body_start = 0; body_len = 0; epi_start = 0; epi_len = 0;
		layer_start = 1'b0; layer_end = 1'b0;
		for (np = 0; np < NPKT; np = np + 1) begin
			p_data[np] = 0; p_addr[np] = 0; p_be[np] = 0; p_chan[np] = 0;
		end

		rst_n = 1'b0;
		repeat (2) @(negedge clk);
		rst_n = 1'b1;

		$display("");
		$display("vector_unit: LANES=%0d, programs assembled in the testbench, every store checked", LANES);

		$display("");
		$display("1) Requantize + ReLU (M = %0d, S = %0d, i.e. scale 0.0037):", M1, S1);
		$display("     prologue: LI s1,M  LI s2,0  SETQ q0,s1,s2,S  LI s3,-128  LI s4,127  SETC c0,s3,s4");
		$display("     body:     REQ v0,v7,q0   ST8 v0,c0");
		prog = 1;
		prg[0] = LI(1, M1); prg[1] = LI(2, 0); prg[2] = SETQ(0, 1, 2, S1);
		prg[3] = LI(3, -128); prg[4] = LI(4, 127); prg[5] = SETC(0, 3, 4);
		prg[6] = REQ(0, 7, 0); prg[7] = ST8(0, 0);
		load_program(6, 2, 0);
		show_left = 3;
		run_layer("ReLU, packets always ready        ", 400, 100000, 100);
		$display("     %0d cycles for %0d packets = %0.2f cycles per packet (2 instructions + 1 wait for REQ)",
		         t_last - t_first, 400, $itor(t_last - t_first) / 400);
		run_layer("ReLU                              ", 400, 100000, 30);

		$display("");
		$display("2) Leaky ReLU (M_neg = M/8) with a low clamp (hi = 50, like ReLU6 in the output scale):");
		prog = 2;
		prg[1] = LI(2, M1 / 8); prg[4] = LI(4, 50);
		load_program(6, 2, 0);
		show_left = 3;
		run_layer("Leaky + clamp                     ", 400, 100000, 100);
		run_layer("Leaky + clamp                     ", 400, 100000, 40);

		$display("");
		$display("3) Every phase-2 instruction, chained dependencies, a running sum kept across packets,");
		$display("   two stores per packet, and an epilogue store of the final sum:");
		prog = 3;
		np = 0;
		prg[np] = VLI(3, 3);            np = np + 1;
		prg[np] = VLI(4, -50);          np = np + 1;
		prg[np] = VLI(5, 0);            np = np + 1;
		prg[np] = LUI(2, 1);            np = np + 1;
		prg[np] = ORI(2, 5);            np = np + 1;
		prg[np] = LUI(8, 32768);     np = np + 1;
		prg[np] = LUI(9, 32767);     np = np + 1;
		prg[np] = ORI(9, 65535);     np = np + 1;
		prg[np] = SETC(0, 8, 9);        np = np + 1;
		prg[np] = LI(3, -100);          np = np + 1;
		prg[np] = LI(4, 100);           np = np + 1;
		prg[np] = SETC(1, 3, 4);        np = np + 1;
		prg[np] = LI(5, 300);           np = np + 1;
		prg[np] = LI(6, -200);          np = np + 1;
		prg[np] = SETQ(1, 5, 6, 10);    np = np + 1;
		prg[np] = ADDI(1, 7, 5);        np = np + 1;
		prg[np] = MUL(2, 1, 3);         np = np + 1;
		prg[np] = SHRR(2, 2, 3);        np = np + 1;
		prg[np] = MAX(2, 2, 4);         np = np + 1;
		prg[np] = SUB(6, 2, 7);         np = np + 1;
		prg[np] = MIN(6, 6, 2);         np = np + 1;
		prg[np] = SHL(6, 6, 1);         np = np + 1;
		prg[np] = SHR(6, 6, 1);         np = np + 1;
		prg[np] = ADD(5, 5, 7);         np = np + 1;
		prg[np] = TAG(7, 0);            np = np + 1;
		prg[np] = BCAST(1, 7);          np = np + 1;
		prg[np] = ADD(6, 6, 1);         np = np + 1;
		prg[np] = REQ(6, 6, 1);         np = np + 1;
		prg[np] = CLAMP(6, 6, 1);       np = np + 1;
		prg[np] = MOV(2, 6);            np = np + 1;
		prg[np] = ST8(2, 1);            np = np + 1;
		prg[np] = ST8(5, 0);            np = np + 1;
		prg[np] = ST8(5, 1);            np = np + 1;
		load_program(15, 17, 1);
		show_left = 4;
		run_layer("all instructions                  ", 120, 3000, 100);
		run_layer("all instructions                  ", 120, 3000, 50);

		$display("");
		$display("4) Argmax over classes: each class is one packet (value in lane 0, class number in the chan tag).");
		$display("     prologue: LUI s1,0x8000  BCAST v0,s1  VLI v1,0  LI s3,0  LI s4,127  SETC c1,s3,s4");
		$display("     body:     TAG s2,chan  BCAST v2,s2  CMPGT v7,v0  [p1] MOV v0,v7  [p1] MOV v1,v2");
		$display("     epilogue: ST8 v1,c1      ([p1] = only lanes where the mask is set, i.e. where the new value is bigger)");
		prog = 4;
		np = 0;
		prg[np] = LUI(1, 32768);        np = np + 1;
		prg[np] = BCAST(0, 1);          np = np + 1;
		prg[np] = VLI(1, 0);            np = np + 1;
		prg[np] = LI(3, 0);             np = np + 1;
		prg[np] = LI(4, 127);           np = np + 1;
		prg[np] = SETC(1, 3, 4);        np = np + 1;
		prg[np] = TAGF(2, 4);           np = np + 1;
		prg[np] = BCAST(2, 2);          np = np + 1;
		prg[np] = CMPGT(7, 0);          np = np + 1;
		prg[np] = P(3'd1, MOV(0, 7));   np = np + 1;
		prg[np] = P(3'd1, MOV(1, 2));   np = np + 1;
		prg[np] = ST8(1, 1);            np = np + 1;
		load_program(6, 5, 1);
		nshow4 = 3;
		show_left = 3;
		run_layer("argmax, 10 classes                ", 10, 1000000, 100);
		run_layer("argmax, 10 classes                ", 10, 1000000, 100);
		run_layer("argmax, 10 classes                ", 10, 1000000, 60);
		for (np = 0; np < 30; np = np + 1)
			run_layer("argmax, random number of classes  ", 2 + {$random} % 60, 50, 70);

		$display("");
		$display("5) Requantize only (no activation: M_neg = M_pos), int8 clamp -128..127.");
		$display("   M and S are computed from each scale the way the Python flow will: the largest S that keeps M <= 32767.");
		$display("     body:     REQ v0,v7,q0   ST8 v0,c0");
		prog = 5;
		run_scale(1.0, 1);
		run_scale(0.5, 0);
		run_scale(0.1, 0);
		run_scale(0.0123, 0);
		run_scale(0.0037037, 1);
		run_scale(0.000613, 0);
		run_scale(0.0000473, 1);
		run_scale(2.5, 1);
		run_scale(0.9999, 0);
		for (np = 0; np < 20; np = np + 1)
			run_scale(0.00001 + $itor({$random} % 100000) / 100000.0, 0);

		$display("");
		$display("   Rounding sweeps: every accumulator in a range, consecutively (4 per packet):");
		q_mode = 1;
		q_scale = 0.5;
		$display("   scale 0.5 (M = 1, S = 1): halves round up, also for negative numbers (-2.5 -> -2, -1.5 -> -1, -0.5 -> 0)");
		quant_program(1, 1);
		sweep_lo = -8;
		show_left = 4;
		run_layer("      sweep -8..7                                ", 4, 1, 100);
		$display("   scale 0.25 (M = 1, S = 2): only exact .5 values round up (-0.75 -> -1, -0.5 -> 0, -0.25 -> 0)");
		quant_program(1, 2);
		sweep_lo = -8;
		show_left = 4;
		run_layer("      sweep -8..7                                ", 4, 1, 100);
		$display("   scale 0.75 (M = 3, S = 2), near the int8 limits: saturation at 127 and -128");
		quant_program(3, 2);
		sweep_lo = 164;
		show_left = 2;
		run_layer("      sweep 164..171                             ", 2, 1, 100);
		sweep_lo = -176;
		show_left = 2;
		run_layer("      sweep -176..-169                           ", 2, 1, 100);
		quant_program(1, 3);
		sweep_lo = -2000;
		run_layer("      scale 1/8, sweep -2000..1999 (not printed)", 1000, 1, 100);
		quant_program(15521, 22);
		sweep_lo = -2000;
		run_layer("      scale 0.0037, sweep -2000..1999 (not printed)", 1000, 1, 100);

		$display("");
		$display("   Extreme accumulators (int32 min/max, 0, +-1) with large and small scales:");
		q_mode = 2;
		quant_program(32767, 0);
		run_layer("      M = 32767, S = 0  (int32 overflow -> saturates)", 200, 1, 100);
		quant_program(32767, 47);
		run_layer("      M = 32767, S = 47 (tiny scale)              ", 200, 1, 100);
		quant_program(1, 0);
		run_layer("      M = 1, S = 0      (scale exactly 1)         ", 200, 1, 100);
		quant_program(-32768, 15);
		run_layer("      M = -32768, S = 15 (negative scale = -1)    ", 200, 1, 60);

		repeat (5) @(negedge clk);
		$display("");
		$fclose(fdo);
		$display("   every store (hardware and expected bytes) is listed in outputs/vector_unit_outputs.txt");
		$display("6) Totals: %0d stores checked, %0d expected stores never happened, %0d errors", stores, e_tail - e_head, errors);
		$display("");
		if (e_head != e_tail) errors = errors + 1;
		if (errors != 0) $fatal(1, "FAIL: %0d error(s)", errors);
		$display("PASS: every store matches the reference");
		$finish;
	end
endmodule
