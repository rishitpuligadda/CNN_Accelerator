`timescale 1ns/1ps

module tb_vu_xlane;
	parameter LANES = 4;

	localparam ADDR = 11;
	localparam W    = LANES * 32;
	localparam NPKT = 1024;

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

	reg  [W-1:0]        p_data [0:NPKT-1];
	reg  [LANES-1:0]    p_be   [0:NPKT-1];
	reg  [7:0]          p_row  [0:NPKT-1];
	reg  [7:0]          p_col  [0:NPKT-1];
	reg  [7:0]          p_chan [0:NPKT-1];
	integer             p_idx, n_pkts, avail_pct;
	reg                 avail;

	vector_unit #(.LANES(LANES), .ADDR(ADDR), .PM_AW(6)) dut (
		.clk(clk), .rst_n(rst_n),
		.pm_we(pm_we), .pm_waddr(pm_waddr), .pm_wdata(pm_wdata),
		.lut_we(lut_we_tb), .lut_waddr(lut_wa_tb), .lut_wdata(lut_wd_tb),
		.pro_start(pro_start), .pro_len(pro_len), .body_start(body_start), .body_len(body_len),
		.epi_start(epi_start), .epi_len(epi_len),
		.layer_start(layer_start), .layer_end(layer_end), .busy(unused_busy), .done(done),
		.pkt_valid(pkt_valid), .pkt_ready(pkt_ready),
		.pkt_data(p_data[(p_idx < NPKT) ? p_idx : 0]), .pkt_addr(ADDR'(p_idx)), .pkt_be(p_be[(p_idx < NPKT) ? p_idx : 0]),
		.pkt_row(p_row[(p_idx < NPKT) ? p_idx : 0]), .pkt_col(p_col[(p_idx < NPKT) ? p_idx : 0]),
		.pkt_chan(p_chan[(p_idx < NPKT) ? p_idx : 0]), .pkt_last(1'b0),
		.st_en(st_en), .st_addr(st_addr), .st_be(st_be), .st_data(st_data)
	);

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

	// ---------------------------------------------------------------- assembler (subset)
	function [14:0] f15(input integer v);
		begin
			if (v < -16384 || v > 32767) $fatal(1, "assembler: immediate %0d does not fit 15 bits", v);
			f15 = v[14:0];
		end
	endfunction
	function [18:0] f19(input integer v);
		begin
			if (v < -262144 || v > 262143) $fatal(1, "assembler: immediate %0d does not fit 19 bits", v);
			f19 = v[18:0];
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
	function [31:0] P(input [2:0] p, input [31:0] w);
		begin
			if (w[25:23] != 3'd0) $fatal(1, "assembler: instruction already has a predicate");
			P = {w[31:26], p, w[22:0]};
		end
	endfunction
	function [31:0] LI(input [3:0] d, input integer imm);    LI    = {6'h01, 3'b000, d, f19(imm)};         endfunction
	function [31:0] SETQ(input [3:0] q, input [3:0] a, input [3:0] b, input integer s); SETQ = enc(6'h09, q, a, b, f11(s)); endfunction
	function [31:0] SETC(input [3:0] c, input [3:0] a, input [3:0] b); SETC = enc(6'h0A, c, a, b, 11'd0); endfunction
	function [31:0] SETP(input [3:0] p, input integer tag, input integer op, input integer val);
		SETP = enc(6'h0C, p, 4'd0, 4'(val >> 6), f11(((val & 63) << 5) | (op << 3) | tag));
	endfunction
	function [31:0] MOV(input [3:0] d, input [3:0] a);       MOV   = enc(6'h10, d, a, 4'd0, 11'd0);        endfunction
	function [31:0] VLI(input [3:0] d, input integer imm);   VLI   = {6'h11, 3'b000, d, 4'd0, f15(imm)};   endfunction
	function [31:0] SHL(input [3:0] d, input [3:0] a, input integer n);  SHL = enc(6'h1D, d, a, 4'd0, f11(n)); endfunction
	function [31:0] SHR(input [3:0] d, input [3:0] a, input integer n);  SHR = enc(6'h1E, d, a, 4'd0, f11(n)); endfunction
	function [31:0] REQ(input [3:0] d, input [3:0] a, input integer q);  REQ = enc(6'h21, d, a, 4'd0, f11(q)); endfunction
	function [31:0] MBE(input integer unused);               MBE   = enc(6'h2B, 4'd0, 4'd0, 4'd0, f11(unused)); endfunction
	function [31:0] MAXP(input [3:0] d, input [3:0] a);      MAXP  = enc(6'h30, d, a, 4'd0, 11'd0);        endfunction
	function [31:0] ADDP(input [3:0] d, input [3:0] a);      ADDP  = enc(6'h31, d, a, 4'd0, 11'd0);        endfunction
	function [31:0] PERM(input [3:0] d, input [3:0] a, input integer pat); PERM = enc(6'h34, d, a, 4'd0, f11(pat)); endfunction
	function [31:0] PERMS(input [3:0] d, input [3:0] a, input [3:0] sb); PERMS = enc(6'h35, d, a, sb, 11'd0); endfunction
	function [31:0] RMAX(input [3:0] d, input [3:0] a);      RMAX  = enc(6'h32, d, a, 4'd0, 11'd0);        endfunction
	function [31:0] RADD(input [3:0] d, input [3:0] a);      RADD  = enc(6'h33, d, a, 4'd0, 11'd0);        endfunction
	function [31:0] LUT(input [3:0] d, input [3:0] a);       LUT   = enc(6'h23, d, a, 4'd0, 11'd0);        endfunction
	function [31:0] LUTW(input [3:0] a, input [3:0] b);      LUTW  = enc(6'h3D, 4'd0, a, b, 11'd0);        endfunction
	function [31:0] RCP(input [3:0] d, input [3:0] a, input integer n); RCP = enc(6'h0B, d, a, 4'd0, f11(n)); endfunction
	function [31:0] BCAST(input [3:0] d, input [3:0] a);     BCAST = enc(6'h12, d, a, 4'd0, 11'd0);        endfunction
	function [31:0] TAG(input [3:0] d, input integer f);     TAG   = enc(6'h08, d, 4'd0, 4'd0, f11(f));    endfunction
	function [31:0] SHLS(input [3:0] d, input [3:0] a, input integer n); SHLS = enc(6'h06, d, a, 4'd0, f11(n)); endfunction
	function [31:0] ADDS(input [3:0] d, input [3:0] a, input [3:0] b); ADDS = enc(6'h04, d, a, b, 11'd0); endfunction
	function [31:0] ST8(input [3:0] a, input integer c);     ST8   = enc(6'h38, 4'd0, a, 4'd0, f11(c));    endfunction

	// ---------------------------------------------------------------- program building
	reg  [31:0] prg [0:63];
	integer     np, n_pro, n_body;

	task emit(input [31:0] w);
		begin
			prg[np] = w;
			np = np + 1;
		end
	endtask

	// Prologue common to every test: c0 = -128..127 (for the dump), q0 = identity (M = 1, S = 0).
	task begin_program;
		begin
			np = 0;
			emit(LI(3, -128)); emit(LI(4, 127)); emit(SETC(0, 3, 4));
			emit(LI(5, 1));    emit(SETQ(0, 5, 5, 0));
		end
	endtask

	task begin_body;
		n_pro = np;
	endtask

	// Dump v0: four stores, one byte of every lane each, most significant first.
	task emit_dump;
		begin
			emit(SHR(1, 0, 24));                     emit(ST8(1, 0));
			emit(SHL(1, 0, 8));  emit(SHR(1, 1, 24)); emit(ST8(1, 0));
			emit(SHL(1, 0, 16)); emit(SHR(1, 1, 24)); emit(ST8(1, 0));
			emit(SHL(1, 0, 24)); emit(SHR(1, 1, 24)); emit(ST8(1, 0));
		end
	endtask

	task load_program;
		integer i;
		begin
			n_body = np - n_pro;
			if (np > 64 || n_body < 1) $fatal(1, "program does not fit");
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
			body_len   = n_body[6:0];
			epi_start  = 6'd0;
			epi_len    = 7'd0;
		end
	endtask

	// ---------------------------------------------------------------- expected results (the spec)
	integer test;

	function signed [31:0] lane(input [W-1:0] v, input integer i);
		lane = v[i*32 +: 32];
	endfunction

	integer xop;   // instruction under test: 0 = MAXP, 1 = ADDP

	// MAXP / ADDP per the spec: pair (2i, 2i+1) into lane i, other lanes 0; ADDP wraps on overflow.
	function [W-1:0] f_pair(input [W-1:0] v);
		integer i;
		reg signed [31:0] x, y;
		begin
			f_pair = {W{1'b0}};
			for (i = 0; 2 * i + 1 < LANES; i = i + 1) begin
				x = v[(2*i)*32 +: 32];
				y = v[(2*i+1)*32 +: 32];
				f_pair[i*32 +: 32] = (xop == 0) ? ((x > y) ? x : y) : x + y;
			end
		end
	endfunction

	localparam PB = (LANES <= 2) ? 1 : ((LANES <= 4) ? 2 : 3);
	integer    pat_imm;    // pattern of the PERM-immediate program currently loaded

	function [W-1:0] f_perm(input [W-1:0] v, input [31:0] pat);
		integer i, k;
		begin
			for (i = 0; i < LANES; i = i + 1) begin
				k = (pat >> (i * PB)) & ((1 << PB) - 1);
				f_perm[i*32 +: 32] = v[k*32 +: 32];
			end
		end
	endfunction

	reg  [15:0] tlut [0:255];
	integer     rcp_n;

	function [W-1:0] bcast(input [31:0] v);
		bcast = {LANES{v}};
	endfunction
	function [31:0] f_rmax(input integer n);
		integer i;
		reg signed [31:0] m;
		begin
			if (n < 0 || n >= NPKT) $fatal(1, "bad packet index");
			m = 32'sh80000000;
			for (i = 0; i < LANES; i = i + 1)
				if (p_be[n][i] && $signed(p_data[n][i*32 +: 32]) > m) m = p_data[n][i*32 +: 32];
			f_rmax = m;
		end
	endfunction
	function [31:0] f_radd(input integer n);
		integer i;
		begin
			if (n < 0 || n >= NPKT) $fatal(1, "bad packet index");
			f_radd = 32'd0;
			for (i = 0; i < LANES; i = i + 1) if (p_be[n][i]) f_radd = f_radd + p_data[n][i*32 +: 32];
		end
	endfunction
	function [W-1:0] f_lut(input [W-1:0] v);
		integer i;
		for (i = 0; i < LANES; i = i + 1)
			f_lut[i*32 +: 32] = {{16{tlut[v[i*32 +: 8]][15]}}, tlut[v[i*32 +: 8]]};
	endfunction
	function [31:0] f_rcp(input [31:0] d);
		reg [63:0] q;
		begin
			q = (64'd1 << rcp_n) / {32'd0, d};
			if (q[63:32] != 32'd0) $fatal(1, "RCP reference: quotient wider than 32 bits");
			f_rcp = (d == 32'd0) ? 32'hFFFFFFFF : q[31:0];
		end
	endfunction

	// PERMS pattern built by the test program from the tags: row | col << 8 | chan << 16
	function [31:0] tag_pat(input integer n);
		begin
			if (n < 0 || n >= NPKT) $fatal(1, "bad packet index");
			tag_pat = {8'd0, p_chan[n], p_col[n], p_row[n]};
		end
	endfunction

	function [31:0] PAIR(input [3:0] d, input [3:0] a);
		PAIR = (xop == 0) ? MAXP(d, a) : ADDP(d, a);
	endfunction

	// What v0 should hold after the body ran on packet n, for the current test.
	function [W-1:0] expected(input integer n);
		reg [W-1:0] r, pre;
		integer i;
		begin
			if (n < 0 || n >= NPKT) $fatal(1, "bad packet index");
			case (test)
				2:       r = f_pair(f_pair(p_data[n]));
				4: begin
					pre = {LANES{32'd77}};
					r   = f_pair(p_data[n]);
					for (i = 0; i < LANES; i = i + 1)
						if (!p_be[n][i]) r[i*32 +: 32] = pre[i*32 +: 32];
				end
				5:       r = (p_row[n][0] == 1'b0) ? f_pair(p_data[n]) : {LANES{-32'sd5}};
				21:      r = (LANES * PB <= 11) ? f_perm(p_data[n], pat_imm) : {LANES{32'd77}};
				22:      r = f_perm(p_data[n], tag_pat(n));
				23:      r = f_perm(f_perm(p_data[n], tag_pat(n)), tag_pat(n));
				24: begin
					pre = {LANES{32'd77}};
					r   = f_perm(p_data[n], tag_pat(n));
					for (i = 0; i < LANES; i = i + 1)
						if (!p_be[n][i]) r[i*32 +: 32] = pre[i*32 +: 32];
				end
				25:      r = (p_row[n][0] == 1'b0) ? f_perm(p_data[n], tag_pat(n)) : {LANES{-32'sd5}};
				31:      r = bcast(f_rmax(n));
				32:      r = bcast(f_radd(n));
				33:      r = f_lut(p_data[n]);
				34:      r = f_lut(p_data[n]);
				35:      r = bcast(f_rcp(p_data[n][31:0]));
				default: r = f_pair(p_data[n]);
			endcase
			expected = r;
		end
	endfunction

	// ---------------------------------------------------------------- packet source and store collector
	integer       errors, checked, show_left, nst, pk_done, mj;
	reg [W-1:0]   got;
	reg           took;

	assign pkt_valid = avail && (p_idx < n_pkts);

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

	task show_packet(input integer n, input [W-1:0] e);
		integer i;
		reg signed [31:0] a, h, x;
		reg [23:0] tp;
		begin
			if (n < 0 || n >= NPKT) $fatal(1, "bad packet index");
			$write("    in :");
			for (i = 0; i < LANES; i = i + 1) begin
				a = lane(p_data[n], i);
				$write(" %12d", a);
			end
			if (test == 4 || test == 24 || test == 31 || test == 32) $write("   be %b", p_be[n]);
			if (test == 34) $write("   LUTW table[%0d] = %0d", p_row[n], $signed({p_chan[n], p_col[n]}));
			if (test == 35) $write("   2^%0d / lane0 (unsigned)", rcp_n);
			if (test == 5) $write("   row %0d", p_row[n]);
			if (test == 21) $write("   pattern %b", pat_imm[7:0]);
			if (test >= 22 && test <= 25) begin
				tp = 24'(tag_pat(n));
				if (LANES * PB <= 8) $write("   pattern %b", tp[7:0]);
				else                 $write("   pattern %b", tp);
			end
			$display("");
			$write("    out:");
			for (i = 0; i < LANES; i = i + 1) begin
				h = lane(got, i);
				$write(" %12d", h);
			end
			$write("   expected");
			for (i = 0; i < LANES; i = i + 1) begin
				x = lane(e, i);
				$write(" %0d", x);
			end
			$display("%0s", (got === e) ? "" : "   MISMATCH");
		end
	endtask

	initial begin
		nst = 0;
		pk_done = 0;
		got = {W{1'b0}};
		forever begin
			@(negedge clk);
			if (st_en) begin
				for (mj = 0; mj < LANES; mj = mj + 1) got[mj*32 + (3 - nst) * 8 +: 8] = st_data[mj*8 +: 8];
				if (st_addr !== ADDR'(pk_done) || st_be !== p_be[pk_done]) begin
					errors = errors + 1;
					if (errors <= 10) $display("FAIL: store address/byte enables do not belong to packet %0d", pk_done);
				end
				nst = nst + 1;
				if (nst == 4) begin
					if (test == 34) tlut[p_row[pk_done]] = {p_chan[pk_done], p_col[pk_done]};
					checked = checked + 1;
					if (got !== expected(pk_done)) begin
						errors = errors + 1;
						if (errors <= 10) begin
							$display("FAIL section %0d packet %0d:", sec, pk_done);
							show_packet(pk_done, expected(pk_done));
						end
					end
					else if (show_left > 0) begin
						show_left = show_left - 1;
						show_packet(pk_done, expected(pk_done));
					end
					nst = 0;
					pk_done = pk_done + 1;
				end
			end
		end
	end

	task run(input [8*60:1] name, input integer n, input integer pct, input integer show);
		integer i, e0, c0;
		begin
			e0 = errors;
			c0 = checked;
			n_pkts    = n;
			p_idx     = 0;
			pk_done   = 0;
			nst       = 0;
			avail_pct = pct;
			show_left = show;
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
				if (i > 200000) $fatal(1, "done never arrived");
			end
			repeat (3) @(negedge clk);
			if (pk_done != n) begin
				errors = errors + 1;
				$display("FAIL: %0d packets produced results, expected %0d", pk_done, n);
			end
			$display("  %0s %0d packets checked, %0d errors", name, checked - c0, errors - e0);
		end
	endtask

	// ---------------------------------------------------------------- packet sets
	reg signed [31:0] special [0:11];

	task packets_special_pairs;
		integer a, b, k, i, n;
		begin
			n = 0;
			k = 0;
			for (a = 0; a < 12; a = a + 1)
				for (b = 0; b < 12; b = b + 1) begin
					i = (k % (LANES / 2)) * 2;
					p_data[n][i*32 +: 32]     = special[a];
					p_data[n][(i+1)*32 +: 32] = special[b];
					k = k + 1;
					if (k % (LANES / 2) == 0) begin
						for (i = LANES - (LANES % 2); i < LANES; i = i + 1) p_data[n][i*32 +: 32] = $random;
						p_be[n]  = {LANES{1'b1}};
						p_row[n] = 8'd0;
						n = n + 1;
					end
				end
			n_pkts = n;
		end
	endtask

	task packets_random(input integer n, input integer kind);
		integer i, j;
		begin
			for (i = 0; i < n; i = i + 1) begin
				for (j = 0; j < LANES; j = j + 1)
					case (kind)
						0:       p_data[i][j*32 +: 32] = $random;
						1:       p_data[i][j*32 +: 32] = $random % 200;
						2:       p_data[i][j*32 +: 32] = (j % 2 == 0) ? $random : p_data[i][(j-1)*32 +: 32];
						default: p_data[i][j*32 +: 32] = special[{$random} % 12];
					endcase
				p_be[i]  = LANES'($random);
				p_row[i] = 8'($random);
			end
		end
	endtask

	integer sec, pt;

	// s1 = row | col << 8 | chan << 16  (only row for 4 lanes, which is all 8 pattern bits)
	task emit_tag_pattern;
		begin
			emit(TAG(1, 2));
			if (LANES * PB > 8) begin
				emit(TAG(2, 3)); emit(SHLS(2, 2, 8));  emit(ADDS(1, 1, 2));
				emit(TAG(2, 4)); emit(SHLS(2, 2, 16)); emit(ADDS(1, 1, 2));
			end
		end
	endtask

	// packet n gets lanes 100, 200, 300, ... so every lane's origin is visible
	task packets_distinct(input integer n);
		integer j;
		begin
			if (n < 0 || n >= NPKT) $fatal(1, "bad packet index");
			for (j = 0; j < LANES; j = j + 1) p_data[n][j*32 +: 32] = 100 * (j + 1);
		end
	endtask

	// Patterns through the tags: 4 lanes -> row = 0..255 (every pattern); 8 lanes -> structured, then random.
	task packets_patterns(input integer n, input integer kind);
		integer i, j;
		reg [23:0] q;
		begin
			packets_random(n, kind);
			for (i = 0; i < n; i = i + 1) begin
				if (LANES * PB <= 8) begin
					p_row[i] = i[7:0];
					p_col[i] = 8'($random); p_chan[i] = 8'($random);
				end
				else begin
					q = 24'($random);
					case (i)
						0: for (j = 0; j < 8; j = j + 1) q[j*3 +: 3] = 3'(j);
						1: for (j = 0; j < 8; j = j + 1) q[j*3 +: 3] = 3'(7 - j);
						2: q = 24'd0;
						3: for (j = 0; j < 8; j = j + 1) q[j*3 +: 3] = 3'd7;
						4: for (j = 0; j < 8; j = j + 1) q[j*3 +: 3] = 3'((j + 1) % 8);
						5: for (j = 0; j < 8; j = j + 1) q[j*3 +: 3] = 3'(j % 4);
						default: begin end
					endcase
					if (i >= 6 && i < 14) for (j = 0; j < 8; j = j + 1) q[j*3 +: 3] = 3'(i - 6);
					p_row[i] = q[7:0]; p_col[i] = q[15:8]; p_chan[i] = q[23:16];
				end
				if (i < 2) packets_distinct(i);
			end
			n_pkts = n;
		end
	endtask

	task load_lut_random;
		integer i;
		begin
			for (i = 0; i < 256; i = i + 1) begin
				case (i)
					0: tlut[i] = 16'h8000;  1: tlut[i] = 16'h7FFF;  255: tlut[i] = 16'hFFFF;  128: tlut[i] = 16'h0001;
					default: tlut[i] = 16'($random);
				endcase
				@(negedge clk);
				lut_we_tb = 1'b1;
				lut_wa_tb = i[7:0];
				lut_wd_tb = tlut[i];
			end
			@(negedge clk);
			lut_we_tb = 1'b0;
		end
	endtask

	task run_timed(input integer n, input integer show);
		time t0;
		integer cyc;
		begin
			t0 = $time;
			run_quiet(n, show);
			cyc = 32'(($time - t0) / 10);
			$display("    n = %2d: %0d packets checked, %0d cycles for %0d packets (%0.1f per packet), %0d errors so far",
			         rcp_n, n, cyc, n, $itor(cyc) / n, errors);
		end
	endtask

	// like run, without the summary line
	task run_quiet(input integer n, input integer show);
		integer i;
		begin
			n_pkts    = n;
			p_idx     = 0;
			pk_done   = 0;
			nst       = 0;
			avail_pct = 100;
			show_left = show;
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
				if (i > 200000) $fatal(1, "done never arrived");
			end
			repeat (3) @(negedge clk);
			if (pk_done != n) begin
				errors = errors + 1;
				$display("FAIL: %0d packets produced results, expected %0d", pk_done, n);
			end
		end
	endtask

	task pair_suite(input integer base);
		begin

			$display("");
			$display("%0d) ", base + 1, "Every ordered pair of 12 special values (int32 min/max and neighbours, -2..2, byte patterns):");
			test = 1; sec = base + 1;
			begin_program; begin_body;
			emit(PAIR(0, 7));
			emit_dump;
			load_program;
			packets_special_pairs;
			run("    all 144 pairs:                       ", n_pkts, 100, 4);
			packets_random(400, 0);
			run("    random 32-bit values:                ", 400, 100, 2);
			packets_random(400, 1);
			run("    small values -199..199:              ", 400, 60, 0);
			packets_random(400, 2);
			run("    equal pairs:                         ", 400, 100, 2);
			packets_random(400, 3);
			run("    random mixes of the special values:  ", 400, 40, 0);

			$display("");
			$display("%0d) ", base + 2, "Result used immediately (forwarding) and in place: PAIR v0,v7 then PAIR v0,v0");
			$display("   -> lane 0 combines all 4 inputs, lane 1 combines (0, 0) = 0  (PAIR = the instruction under test):");
			test = 2; sec = base + 2;
			begin_program; begin_body;
			emit(PAIR(0, 7));
			emit(PAIR(0, 0));
			emit_dump;
			load_program;
			packets_random(300, 3);
			run("    special values:                      ", 300, 100, 3);
			packets_random(300, 0);
			run("    random values:                       ", 300, 70, 0);

			$display("");
			$display("%0d) ", base + 3, "Source from a 2-cycle instruction (interlock): REQ v2,v7,q0 (identity) then PAIR v0,v2:");
			test = 3; sec = base + 3;
			begin_program; begin_body;
			emit(REQ(2, 7, 0));
			emit(PAIR(0, 2));
			emit_dump;
			load_program;
			packets_random(300, 3);
			run("    special values:                      ", 300, 100, 2);
			packets_random(300, 0);
			run("    random values:                       ", 300, 50, 0);

			$display("");
			$display("%0d) ", base + 4, "Lane-mask predication: VLI v0,77  MBE  [p1] PAIR v0,v7 -> only lanes with be = 1 change:");
			test = 4; sec = base + 4;
			begin_program; begin_body;
			emit(VLI(0, 77));
			emit(MBE(0));
			emit(P(3'd1, PAIR(0, 7)));
			emit_dump;
			load_program;
			packets_random(300, 3);
			run("    special values, random be:           ", 300, 100, 4);
			packets_random(300, 0);
			run("    random values, random be:            ", 300, 80, 0);

			$display("");
			$display("%0d) ", base + 5, "Packet predicate: P2 = (row is even); VLI v0,-5  [p2] PAIR v0,v7 -> odd rows keep -5:");
			test = 5; sec = base + 5;
			begin_program;
			emit(SETP(2, 2, 2, (1 << 6) | 0));               // row, low 1 bit == 0
			begin_body;
			emit(VLI(0, -5));
			emit(P(3'd2, PAIR(0, 7)));
			emit_dump;
			load_program;
			packets_random(300, 3);
			run("    special values, random rows:         ", 300, 100, 4);
			packets_random(300, 0);
			run("    random values, random rows:          ", 300, 60, 0);
		end
	endtask

	initial begin
		if ($test$plusargs("vcd")) begin
			$dumpfile("waveforms/vu_xlane.vcd");
			$dumpvars(0, tb_vu_xlane);
		end

		special[0]  = 32'sh80000000;
		special[1]  = 32'sh80000001;
		special[2]  = -32'sd2;
		special[3]  = -32'sd1;
		special[4]  = 32'sd0;
		special[5]  = 32'sd1;
		special[6]  = 32'sd2;
		special[7]  = 32'sh7FFFFFFE;
		special[8]  = 32'sh7FFFFFFF;
		special[9]  = 32'sh00FF00FF;
		special[10] = -32'sh00FF0100;
		special[11] = 32'sh00008000;

		errors = 0; checked = 0; show_left = 0; test = 0; sec = 0; xop = 0; pt = 0; pat_imm = 0; rcp_n = 0;
		p_idx = 0; n_pkts = 0; avail_pct = 100; avail = 1'b1;
		pm_we = 1'b0; pm_waddr = 0; pm_wdata = 0;
		pro_start = 0; pro_len = 0; body_start = 0; body_len = 0; epi_start = 0; epi_len = 0;
		layer_start = 1'b0; layer_end = 1'b0;
		for (np = 0; np < NPKT; np = np + 1) begin
			p_data[np] = {W{1'b0}}; p_be[np] = {LANES{1'b1}}; p_row[np] = 8'd0; p_col[np] = 8'd0; p_chan[np] = 8'd0;
		end

		rst_n = 1'b0;
		repeat (2) @(negedge clk);
		rst_n = 1'b1;

		$display("");
		$display("Cross-lane instructions, LANES = %0d. Every result is dumped byte by byte (4 stores per packet)", LANES);
		$display("and reassembled, so the full 32-bit value of every lane is checked against the spec.");

		xop = 0;
		$display("");
		$display("MAXP vd, va:  vd[i] = max(va[2i], va[2i+1]) for i < LANES/2, all other lanes 0");
		pair_suite(0);

		xop = 1;
		$display("");
		$display("ADDP vd, va:  vd[i] = va[2i] + va[2i+1] (wrapping, like ADD) for i < LANES/2, all other lanes 0");
		pair_suite(10);

		$display("");
		sec = 16;
		$display("16) ADDP overflow: sums beyond the int32 range wrap around (2147483647 + 1 = -2147483648):");
		test = 1;
		begin_program; begin_body;
		emit(ADDP(0, 7));
		emit_dump;
		load_program;
		for (np = 0; np < 200; np = np + 1) begin
			for (sec = 0; sec < LANES; sec = sec + 2) begin
				case ({$random} % 4)
					0: begin p_data[np][sec*32 +: 32] = 32'sh7FFFFFFF; p_data[np][(sec+1)*32 +: 32] = 1 + {$random} % 100; end
					1: begin p_data[np][sec*32 +: 32] = 32'sh80000000; p_data[np][(sec+1)*32 +: 32] = -1 - {$random} % 100; end
					2: begin p_data[np][sec*32 +: 32] = 32'sh40000000 + {$random} % 1000; p_data[np][(sec+1)*32 +: 32] = 32'sh40000000; end
					default: begin p_data[np][sec*32 +: 32] = 32'sh80000000; p_data[np][(sec+1)*32 +: 32] = 32'sh80000000; end
				endcase
			end
			p_be[np] = {LANES{1'b1}};
			p_row[np] = 8'd0;
		end
		run("    overflowing pairs:                   ", 200, 100, 4);

		$display("");
		$display("PERM vd, va, pattern:  vd[i] = va[pattern bits (2i+1:2i)]   (pattern in the instruction, 2 and 4 lanes)");
		$display("PERMS vd, va, sb:      vd[i] = va[sb bits (PB*i+PB-1 : PB*i)] (pattern in a scalar, PB = 2 bits for 4 lanes, 3 for 8)");
		$display("");
		test = 21; sec = 21;
		if (LANES * PB <= 11) begin
			$display("21) PERM with every one of the 256 patterns (one program per pattern), named ones shown:");
			for (pt = 0; pt < 262; pt = pt + 1) begin
				case (pt)
					0: pat_imm = 32'b11_10_01_00;
					1: pat_imm = 32'b00_01_10_11;
					2: pat_imm = 32'b00_00_00_00;
					3: pat_imm = 32'b11_11_11_11;
					4: pat_imm = 32'b01_00_01_00;
					5: pat_imm = 32'b10_11_00_01;
					default: pat_imm = pt - 6;
				endcase
				if (pt < 6)
					case (pt)
						0: $display("    identity (11 10 01 00):");
						1: $display("    reverse (00 01 10 11):");
						2: $display("    broadcast lane 0 (00 00 00 00):");
						3: $display("    broadcast lane 3 (11 11 11 11):");
						4: $display("    lanes 0,1 copied to 2,3 (01 00 01 00), as in 2x2 pooling:");
						default: $display("    swap neighbours (10 11 00 01):");
					endcase
				begin_program; begin_body;
				emit(PERM(0, 7, pat_imm));
				emit_dump;
				load_program;
				packets_random(4, 3);
				for (np = 0; np < 4; np = np + 1) if (np == 1) packets_distinct(np);
				run_quiet(4, (pt < 6) ? 1 : 0);
			end
			$display("      all 256 patterns: %0d packets checked so far, %0d errors", checked, errors);
		end
		else begin
			$display("21) PERM with an immediate pattern does not exist for %0d lanes: it must leave vd unchanged.", LANES);
			pat_imm = 0;
			begin_program; begin_body;
			emit(VLI(0, 77));
			emit(PERM(0, 7, 32'b00_01_10_11));
			emit_dump;
			load_program;
			packets_random(50, 0);
			run("    VLI v0,77  PERM v0,v7,pattern  ->  v0 stays 77:", 50, 100, 1);
		end

		$display("");
		$display("22) PERMS with the pattern built from the tags every packet (scalar ops right before PERMS):");
		test = 22; sec = 22;
		begin_program; begin_body;
		emit_tag_pattern;
		emit(PERMS(0, 7, 1));
		emit_dump;
		load_program;
		packets_patterns(NPKT, 3);
		run("    patterns via tags, special values:   ", n_pkts, 100, 5);
		packets_patterns(NPKT, 0);
		run("    same with random 32-bit values:      ", n_pkts, 60, 0);

		$display("");
		$display("23) Result used immediately and in place: PERMS v0,v7,s1 then PERMS v0,v0,s1 (pattern applied twice):");
		test = 23; sec = 23;
		begin_program; begin_body;
		emit_tag_pattern;
		emit(PERMS(0, 7, 1));
		emit(PERMS(0, 0, 1));
		emit_dump;
		load_program;
		packets_patterns(NPKT, 0);
		run("    random values, all patterns:         ", n_pkts, 100, 2);

		$display("");
		$display("24) Interlock (REQ v2,v7,q0 then PERMS v0,v2,s1) together with lane-mask predication:");
		test = 24; sec = 24;
		begin_program; begin_body;
		emit_tag_pattern;
		emit(VLI(0, 77));
		emit(MBE(0));
		emit(REQ(2, 7, 0));
		emit(P(3'd1, PERMS(0, 2, 1)));
		emit_dump;
		load_program;
		packets_patterns(NPKT, 3);
		for (np = 0; np < n_pkts; np = np + 1) p_be[np] = LANES'($random);
		run("    special values, random be:           ", n_pkts, 80, 3);

		$display("");
		$display("25) Packet predicate P2 = (row is even); VLI v0,-5  [p2] PERMS v0,v7,s1:");
		test = 25; sec = 25;
		begin_program;
		emit(SETP(2, 2, 2, (1 << 6) | 0));
		begin_body;
		emit_tag_pattern;
		emit(VLI(0, -5));
		emit(P(3'd2, PERMS(0, 7, 1)));
		emit_dump;
		load_program;
		packets_patterns(NPKT, 0);
		run("    random values:                       ", n_pkts, 70, 3);

		$display("");
		$display("RMAX sd, va / RADD sd, va: maximum / wrapping sum over the lanes with be = 1 (empty: int32 min / 0)");
		$display("");
		$display("31) RMAX s1,v7  BCAST v0,s1  (the scalar result is broadcast so the dump shows it):");
		test = 31; sec = 31;
		begin_program; begin_body;
		emit(RMAX(1, 7)); emit(BCAST(0, 1));
		emit_dump;
		load_program;
		packets_random(400, 3);
		for (np = 0; np < 6; np = np + 1) p_be[np] = (np == 0) ? {LANES{1'b0}} : ((np == 1) ? {{(LANES-1){1'b0}}, 1'b1} : p_be[np]);
		run("    special values, random be (incl. 0):", 400, 100, 4);
		packets_random(400, 0);
		run("    random values, random be:           ", 400, 60, 0);

		$display("");
		$display("32) RADD s1,v7  BCAST v0,s1  (sums wrap around like ADD):");
		test = 32; sec = 32;
		begin_program; begin_body;
		emit(RADD(1, 7)); emit(BCAST(0, 1));
		emit_dump;
		load_program;
		packets_random(400, 3);
		for (np = 0; np < 3; np = np + 1) p_be[np] = (np == 0) ? {LANES{1'b0}} : {LANES{1'b1}};
		run("    special values, random be (incl. 0):", 400, 100, 3);
		packets_random(400, 0);
		run("    random values, random be:           ", 400, 70, 0);

		$display("");
		$display("LUT vd, va: vd[i] = sign_extend(table[va[i] bits 7:0]) - the index is the low byte, unsigned");
		$display("LUTW sa, sb: table[sa bits 7:0] = sb bits 15:0");
		$display("");
		$display("33) LUT v0,v7 with a random table (loaded through the table port), every index 0..255:");
		test = 33; sec = 33;
		load_lut_random;
		begin_program; begin_body;
		emit(LUT(0, 7));
		emit_dump;
		load_program;
		for (np = 0; np < 256; np = np + 1) begin
			for (pt = 0; pt < LANES; pt = pt + 1)
				p_data[np][pt*32 +: 32] = {24'($random), 8'((np * LANES + pt) % 256)};
			p_be[np] = {LANES{1'b1}};
		end
		for (pt = 0; pt < LANES; pt = pt + 1) p_data[0][pt*32 +: 32] = (pt == 0) ? -32'sd1 : ((pt == 1) ? 32'sd255 : ((pt == 2) ? -32'sd128 : 32'sd256));
		run("    all indices, random upper bits:     ", 256, 100, 3);

		$display("");
		$display("34) LUTW then LUT in the very next instruction: TAG s1,row  TAG s2,col  TAG s3,chan  (s2 |= s3<<8)");
		$display("    LUTW s1,s2  LUT v0,v7  - lane values index the entry just written, among others:");
		test = 34; sec = 34;
		begin_program; begin_body;
		emit(TAG(1, 2)); emit(TAG(2, 3)); emit(TAG(3, 4)); emit(SHLS(3, 3, 8)); emit(ADDS(2, 2, 3));
		emit(LUTW(1, 2));
		emit(LUT(0, 7));
		emit_dump;
		load_program;
		for (np = 0; np < 300; np = np + 1) begin
			p_row[np] = 8'($random); p_col[np] = 8'($random); p_chan[np] = 8'($random);
			for (pt = 0; pt < LANES; pt = pt + 1)
				p_data[np][pt*32 +: 32] = (pt == 0) ? {24'($random), p_row[np]} : 32'($random);
			p_be[np] = {LANES{1'b1}};
		end
		run("    write-then-read, 300 packets:       ", 300, 100, 3);

		$display("");
		$display("RCP sd, sa, n: sd = floor(2^n / sa), unsigned; sa = 0 gives 0xFFFFFFFF; stalls ~32 cycles");
		$display("");
		$display("35) RADD s1,v7 (be = 0001: s1 = lane 0)  RCP s2,s1,n  BCAST v0,s2  - result used right after the stall:");
		test = 35; sec = 35;
		for (pt = 0; pt < 6; pt = pt + 1) begin
			case (pt)
				0: rcp_n = 31; 1: rcp_n = 30; 2: rcp_n = 16; 3: rcp_n = 8; 4: rcp_n = 1; default: rcp_n = 0;
			endcase
			begin_program; begin_body;
			emit(RADD(1, 7)); emit(RCP(2, 1, rcp_n)); emit(BCAST(0, 2));
			emit_dump;
			load_program;
			for (np = 0; np < 120; np = np + 1) begin
				for (sec = 0; sec < LANES; sec = sec + 1) p_data[np][sec*32 +: 32] = $random;
				case (np)
					0: p_data[np][31:0] = 32'd0;          1: p_data[np][31:0] = 32'd1;
					2: p_data[np][31:0] = 32'd2;          3: p_data[np][31:0] = 32'd3;
					4: p_data[np][31:0] = 32'd7;          5: p_data[np][31:0] = 32'd65535;
					6: p_data[np][31:0] = 32'd65536;      7: p_data[np][31:0] = 32'h7FFFFFFF;
					8: p_data[np][31:0] = 32'h80000000;   9: p_data[np][31:0] = 32'hFFFFFFFF;
					10: p_data[np][31:0] = 32'hFFFFFFFE;  11: p_data[np][31:0] = 32'd100000;
					default: p_data[np][31:0] = (np % 2 == 0) ? 32'($random % 70000) : 32'($random);
				endcase
				p_be[np] = {{(LANES-1){1'b0}}, 1'b1};
			end
			sec = 35;
			run_timed(120, (pt == 0) ? 6 : ((pt == 2) ? 3 : 0));
		end

		$display("");
		$display("Totals: %0d packets checked (4 stores each), %0d errors", checked, errors);
		$display("");
		if (errors != 0) $fatal(1, "FAIL");
		$display("PASS: every MAXP, ADDP, PERM, PERMS, RMAX, RADD, LUT, LUTW and RCP result matches the spec");
		$finish;
	end
endmodule
