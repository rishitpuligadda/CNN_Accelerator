`timescale 1ns/1ps

// Runs vector-unit programs on the instruction-set interpreter only (no RTL), to prove that the
// instruction set can express real CNN operations before the hardware for them is built.
module tb_vu_model;
	localparam LANES = 4;
	localparam W     = LANES * 32;
	localparam OMAX  = 8192;
	localparam MAXC  = 16;
	localparam MAXHW = 64;

	// ================================================================ interpreter state
	reg  [W-1:0]        iv  [0:6];
	reg  [31:0]         is  [0:15];
	reg  [15:0]         iqp [0:3];
	reg  [15:0]         iqn [0:3];
	reg  [5:0]          iqs [0:3];
	reg  [31:0]         icl [0:3];
	reg  [31:0]         ich [0:3];
	reg  [LANES-1:0]    imask;
	reg  [2:0]          ipt_tag [2:7];
	reg  [1:0]          ipt_op  [2:7];
	reg  [9:0]          ipt_val [2:7];
	reg  [W-1:0]        lm  [0:255];
	reg  [31:0]         ia_base, ia_chp, ia_rp;
	reg  [1:0]          ia_l;
	reg  [W-1:0]        ipkt;
	reg  [10:0]         iaddr;
	reg  [LANES-1:0]    ibe;
	reg  [7:0]          irow, icol, ichan;
	reg                 ilast;
	reg  [31:0]         prog_mem [0:63];

	reg  [7:0]          omem  [0:OMAX*4-1];
	integer             owr   [0:OMAX*4-1];
	integer             n_st8a, bad_addr;

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
	function signed [31:0] f_clamp(input signed [31:0] a, input signed [31:0] l, input signed [31:0] h);
		reg signed [31:0] c;
		begin
			c = (a > l) ? a : l;
			f_clamp = (c < h) ? c : h;
		end
	endfunction
	function signed [31:0] f_sat8(input signed [31:0] a);
		f_sat8 = (a < -128) ? -32'sd128 : ((a > 127) ? 32'sd127 : a);
	endfunction

	// Address unit (spec v0.6): derived tags computed from row/col/chan/be and the SETR settings.
	function [31:0] paddr(input integer unused);
		paddr = ia_base + ichan * ia_chp[15:0] + (irow >> ia_l) * ia_rp[15:0] + (icol >> (ia_l + 2));
	endfunction
	function [31:0] pbe(input integer unused);
		integer j, n;
		reg [LANES-1:0] v;
		begin
			v = {LANES{1'b0}};
			n = LANES >> ia_l;
			for (j = 0; j < n; j = j + 1) v[j] = ibe[((j + 1) << ia_l) - 1];
			pbe = {28'd0, v} << ((icol >> ia_l) & 3);
			pbe = pbe & {{(32-LANES){1'b0}}, {LANES{1'b1}}};
		end
	endfunction
	function [31:0] lmidx(input integer unused);
		lmidx = {24'd0, 1'b0, ichan[1:0], 5'd0} + {26'd0, icol[7:2]};
	endfunction

	function [31:0] tagv(input [3:0] t);
		case (t)
			4'd6:    tagv = paddr(0);
			4'd7:    tagv = pbe(0);
			4'd8:    tagv = lmidx(0);
			default: tagv = {21'd0, itag(t[2:0])};
		endcase
	endfunction

	function [10:0] itag(input [2:0] t);
		case (t)
			3'd0:    itag = iaddr;
			3'd1:    itag = {7'd0, ibe};
			3'd2:    itag = {3'd0, irow};
			3'd3:    itag = {3'd0, icol};
			3'd4:    itag = {3'd0, ichan};
			3'd5:    itag = {10'd0, ilast};
			default: itag = 11'd0;
		endcase
	endfunction

	// Predicates (spec v0.5): op 0: tag == val, op 1: tag != val,
	// op 2: low k bits of tag == v, op 3: low k bits of tag != v, with val = {k[3:0], v[5:0]}.
	function ipred(input [2:0] p);
		reg [10:0] t, kmask;
		reg [3:0]  k;
		reg [5:0]  v;
		begin
			if (p == 3'd0 || p == 3'd1) ipred = 1'b1;
			else begin
				t     = itag(ipt_tag[p]);
				k     = ipt_val[p][9:6];
				v     = ipt_val[p][5:0];
				kmask = (11'd1 << k) - 11'd1;
				case (ipt_op[p])
					2'd0:    ipred = (t == {1'b0, ipt_val[p]});
					2'd1:    ipred = (t != {1'b0, ipt_val[p]});
					2'd2:    ipred = ((t & kmask) == ({5'd0, v} & kmask));
					default: ipred = ((t & kmask) != ({5'd0, v} & kmask));
				endcase
			end
		end
	endfunction

	function [W-1:0] vget(input [2:0] r);
		vget = (r == 3'd7) ? ipkt : iv[r];
	endfunction

	task iss_exec(input [31:0] w);
		reg [5:0]  op;
		reg [3:0]  d, a, b;
		reg [10:0] x;
		reg [2:0]  pr;
		reg [31:0] simm15, simm19, ad;
		reg [W-1:0] va, vb, vr, old;
		reg [LANES-1:0] wl, bm;
		reg signed [31:0] la, lb, c;
		integer i, e, sl;
		begin
			op = w[31:26]; pr = w[25:23]; d = w[22:19]; a = w[18:15]; b = w[14:11]; x = w[10:0];
			simm15 = {{17{b[3]}}, b, x};
			simm19 = {{13{a[3]}}, a, b, x};
			va = vget(a[2:0]);
			vb = vget(b[2:0]);
			vr = {W{1'b0}};
			wl = (pr == 3'd1) ? imask : {LANES{1'b1}};
			if (!ipred(pr)) op = 6'h00;
			case (op)
				6'h01: if (d != 0) is[d] = simm19;
				6'h02: if (d != 0) is[d] = {w[15:0], 16'd0};
				6'h03: if (d != 0) is[d] = is[d] | {16'd0, w[15:0]};
				6'h04: if (d != 0) is[d] = is[a] + is[b];
				6'h05: if (d != 0) is[d] = is[a] + simm15;
				6'h06: if (d != 0) is[d] = is[a] << x[4:0];
				6'h07: if (d != 0) is[d] = $signed(is[a]) >>> x[4:0];
				6'h08: if (d != 0) is[d] = (x[3:0] > 4'd8) ? 32'd0 : tagv(x[3:0]);
				6'h14: case (x[1:0])
					2'd0: ia_base = is[a];
					2'd1: ia_chp  = is[a];
					2'd2: ia_rp   = is[a];
					default: ia_l = is[a][1:0];
				endcase
				6'h09: begin iqp[d[1:0]] = is[a][15:0]; iqn[d[1:0]] = is[b][15:0]; iqs[d[1:0]] = x[5:0]; end
				6'h0A: begin icl[d[1:0]] = is[a]; ich[d[1:0]] = is[b]; end
				6'h0C: if (d[2:1] != 2'b00) begin ipt_tag[d[2:0]] = x[2:0]; ipt_op[d[2:0]] = x[4:3]; ipt_val[d[2:0]] = {b, x[10:5]}; end
				6'h0D: if (d != 0) is[d] = is[a] & {17'd0, b, x};
				6'h0E: if (d != 0) is[d] = $signed(is[a]) * $signed(is[b][15:0]);
				6'h0F: if (d != 0) is[d] = is[a] << is[b][4:0];
				6'h28: for (i = 0; i < LANES; i = i + 1) imask[i] = $signed(va[i*32 +: 32]) > $signed(vb[i*32 +: 32]);
				6'h29: for (i = 0; i < LANES; i = i + 1) imask[i] = va[i*32 +: 32] == vb[i*32 +: 32];
				6'h2B: imask = ibe;
				6'h3B: if (d[2:0] != 3'd7) begin
					old = iv[d[2:0]];
					vr  = lm[is[a][7:0]];
					for (i = 0; i < LANES; i = i + 1) if (!wl[i]) vr[i*32 +: 32] = old[i*32 +: 32];
					iv[d[2:0]] = vr;
				end
				6'h3C: begin
					e = is[b][7:0];
					old = lm[e];
					for (i = 0; i < LANES; i = i + 1) if (wl[i]) old[i*32 +: 32] = va[i*32 +: 32];
					lm[e] = old;
				end
				6'h3E: if (d[2:0] != 3'd7) begin
					old = iv[d[2:0]];
					e  = is[a][9:2];
					sl = is[a][1:0];
					for (i = 0; i < LANES; i = i + 1) begin
						c = {{24{lm[e][i*32 + sl*8 + 7]}}, lm[e][i*32 + sl*8 +: 8]};
						vr[i*32 +: 32] = wl[i] ? c : old[i*32 +: 32];
					end
					iv[d[2:0]] = vr;
				end
				6'h3F: begin
					e  = is[b][9:2];
					sl = is[b][1:0];
					old = lm[e];
					for (i = 0; i < LANES; i = i + 1)
						if (wl[i]) begin
							c = f_sat8(va[i*32 +: 32]);
							old[i*32 + sl*8 +: 8] = c[7:0];
						end
					lm[e] = old;
				end
				6'h39: begin
					ad = is[b];
					bm = is[d][LANES-1:0] & wl;
					n_st8a = n_st8a + 1;
					if (ad >= OMAX) bad_addr = bad_addr + 1;
					else
						for (i = 0; i < LANES; i = i + 1)
							if (bm[i]) begin
								c = f_sat8(f_clamp(va[i*32 +: 32], icl[x[1:0]], ich[x[1:0]]));
								omem[ad*4 + i] = c[7:0];
								owr[ad*4 + i]  = owr[ad*4 + i] + 1;
							end
				end
				6'h10, 6'h11, 6'h12, 6'h13, 6'h2A, 6'h18, 6'h19, 6'h1A, 6'h1B, 6'h1C, 6'h1D, 6'h1E, 6'h1F,
				6'h20, 6'h21, 6'h22, 6'h30, 6'h31, 6'h34: begin
					for (i = 0; i < LANES; i = i + 1) begin
						la = va[i*32 +: 32];
						lb = vb[i*32 +: 32];
						case (op)
							6'h10: c = la;
							6'h11: c = simm15;
							6'h12: c = is[a];
							6'h13: c = i;
							6'h2A: c = imask[i] ? la : lb;
							6'h18: c = la + lb;
							6'h19: c = la - lb;
							6'h1A: c = la + simm15;
							6'h1B: c = (la > lb) ? la : lb;
							6'h1C: c = (la < lb) ? la : lb;
							6'h1D: c = la <<< x[4:0];
							6'h1E: c = la >>> x[4:0];
							6'h1F: c = f_shrr(la, x[4:0]);
							6'h20: c = la * $signed(lb[15:0]);
							6'h21: c = f_req(la, iqp[x[1:0]], iqn[x[1:0]], iqs[x[1:0]]);
							6'h22: c = f_clamp(la, icl[x[1:0]], ich[x[1:0]]);
							6'h30, 6'h31: begin
								if (2 * i + 1 < LANES) begin
									la = va[(2*i)*32 +: 32];
									lb = va[(2*i+1)*32 +: 32];
									c  = (op == 6'h30) ? ((la > lb) ? la : lb) : la + lb;
								end
								else c = 0;
							end
							default: c = va[x[2*i +: 2]*32 +: 32];
						endcase
						vr[i*32 +: 32] = c;
					end
					if (d[2:0] != 3'd7) begin
						old = iv[d[2:0]];
						for (i = 0; i < LANES; i = i + 1) if (!wl[i]) vr[i*32 +: 32] = old[i*32 +: 32];
						iv[d[2:0]] = vr;
					end
				end
				default: begin end
			endcase
		end
	endtask

	task iss_reset;
		integer i;
		begin
			for (i = 0; i < 7; i = i + 1)  iv[i] = {W{1'b0}};
			for (i = 0; i < 16; i = i + 1) is[i] = 32'd0;
			for (i = 0; i < 4; i = i + 1) begin
				iqp[i] = 16'd0; iqn[i] = 16'd0; iqs[i] = 6'd0;
				icl[i] = 32'h80000000; ich[i] = 32'h7FFFFFFF;
			end
			for (i = 2; i < 8; i = i + 1) begin ipt_tag[i] = 3'd0; ipt_op[i] = 2'd0; ipt_val[i] = 10'd0; end
			for (i = 0; i < 256; i = i + 1) lm[i] = {W{1'b0}};
			imask = {LANES{1'b0}};
			ia_base = 32'd0; ia_chp = 32'd0; ia_rp = 32'd0; ia_l = 2'd0;
			ipkt = {W{1'b0}}; iaddr = 11'd0; ibe = {LANES{1'b0}};
			irow = 8'd0; icol = 8'd0; ichan = 8'd0; ilast = 1'b0;
		end
	endtask

	// ================================================================ assembler
	integer np, n_pro;

	function [31:0] enc(input [5:0] op, input [3:0] d, input [3:0] a, input [3:0] b, input [10:0] x);
		enc = {op, 3'b000, d, a, b, x};
	endfunction
	task emit(input [31:0] w);
		begin
			if (np >= 64) $fatal(1, "program longer than 64 instructions");
			prog_mem[np] = w;
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

	localparam T_BE = 1, T_ROW = 2, T_COL = 3, T_CHAN = 4, T_PADDR = 6, T_PBE = 7, T_LMIDX = 8;
	localparam OP_LOWEQ = 2, OP_LOWNE = 3;

	// ================================================================ the pooling programs
	// Registers fixed by the prologue:  s10 = output base word, s11 = output channel pitch, s12 = output row pitch.
	// Packets carry raw accumulators; every program first requantizes (q0) and clamps to int8 (c0).
	integer pool_k, pool_avg, out_h, out_w, out_rp, out_ch, out_base;
	integer q_m, q_mn, q_s;

	task prologue;
		begin
			np = 0;
			emit(LI(1, q_m)); emit(LI(2, q_mn)); emit(SETQ(0, 1, 2, q_s));
			emit(LI(3, -128)); emit(LI(4, 127)); emit(SETC(0, 3, 4));
			emit(LI(10, out_base)); emit(LI(11, out_ch)); emit(LI(12, out_rp));
		end
	endtask

	// local-memory entry for this packet: (chan mod 4) * 32 + col / 4   -> s6
	task emit_lm_index;
		begin
			emit(TAG(5, T_CHAN)); emit(ANDIS(6, 5, 3)); emit(SHLS(6, 6, 5));
			emit(TAG(7, T_COL));  emit(SHRS(8, 7, 2));  emit(ADDS(6, 6, 8));
		end
	endtask

	// output word: base + chan * ch_pitch + (row >> rs) * row_pitch + (col >> cs)   -> s9   (needs s5 = chan, s7 = col)
	task emit_out_addr(input integer rs, input integer cs);
		begin
			emit(MULS(9, 5, 11));
			emit(TAG(13, T_ROW)); emit(SHRS(13, 13, rs)); emit(MULS(13, 13, 12)); emit(ADDS(9, 9, 13));
			emit(SHRS(14, 7, cs)); emit(ADDS(9, 9, 14)); emit(ADDS(9, 9, 10));
		end
	endtask

	task program_2x2(input integer avg);
		begin
			prologue;
			emit(SETP(2, T_ROW, OP_LOWEQ, 1, 0));           // P2: even row
			emit(SETP(3, T_ROW, OP_LOWEQ, 1, 1));           // P3: odd row
			n_pro = np;
			emit(REQ(0, 7, 0)); emit(CLAMP(0, 0, 0));
			if (avg != 0) emit(ADDP(1, 0)); else emit(MAXP(1, 0));     // lanes 0,1 = horizontal pairs
			emit_lm_index;
			emitp(3'd2, STS(1, 6));                         // even row: park the pair results
			emitp(3'd3, LDS(2, 6));                         // odd row: fetch them
			if (avg != 0) begin
				emitp(3'd3, ADD(1, 1, 2));
				emitp(3'd3, SHRR(1, 1, 2));                 // sum of 4, divided by 4, rounded half up
			end
			else emitp(3'd3, MAX(1, 1, 2));
			emit(PERM(1, 1, 8'b01_00_01_00));               // copy lanes 0,1 to lanes 2,3
			emit_out_addr(1, 3);
			// byte mask: pooled pixel 0 exists if be[1], pixel 1 if be[3]; shifted to byte (col/2) mod 4
			emit(TAG(15, T_BE)); emit(SHRS(1, 15, 1)); emit(ANDIS(1, 1, 1));
			emit(SHRS(2, 15, 2)); emit(ANDIS(2, 2, 2)); emit(ADDS(1, 1, 2));
			emit(SHRS(2, 7, 1)); emit(ANDIS(2, 2, 3)); emit(SLLV(1, 1, 2));
			emitp(3'd3, ST8A(1, 9, 1, 0));
		end
	endtask

	task program_4x4;
		begin
			prologue;
			emit(SETP(2, T_ROW, OP_LOWNE, 2, 0));           // P2: row mod 4 != 0
			emit(SETP(3, T_ROW, OP_LOWNE, 2, 3));           // P3: row mod 4 != 3
			emit(SETP(4, T_ROW, OP_LOWEQ, 2, 3));           // P4: row mod 4 == 3
			n_pro = np;
			emit(REQ(0, 7, 0)); emit(CLAMP(0, 0, 0));
			emit(MAXP(1, 0)); emit(MAXP(1, 1));             // lane 0 = max of the 4 pixels
			emit_lm_index;
			emitp(3'd2, LDS(2, 6));
			emitp(3'd2, MAX(1, 1, 2));                      // rows 1..3: combine with the rows above
			emitp(3'd3, STS(1, 6));                         // rows 0..2: park the running max
			emit(PERM(1, 1, 8'b00_00_00_00));               // lane 0 to every lane
			emit_out_addr(2, 4);
			// byte mask: the pooled pixel exists only if all 4 columns do (be = 1111); byte (col/4) mod 4
			emit(TAG(15, T_BE)); emit(ADDIS(1, 15, 1)); emit(SHRS(1, 1, 4));
			emit(SHRS(2, 7, 2)); emit(ANDIS(2, 2, 3)); emit(SLLV(1, 1, 2));
			emitp(3'd4, ST8A(1, 9, 1, 0));
		end
	endtask

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

	// ================================================================ feature map, packets, reference
	integer fh, fw, fc;
	reg signed [31:0] acc [0:MAXC*MAXHW*MAXHW-1];
	reg signed [7:0]  q8  [0:MAXC*MAXHW*MAXHW-1];
	integer           errors, layers, pkts_total, show, fast;

	function integer fi(input integer c, input integer y, input integer x);
		fi = (c * MAXHW + y) * MAXHW + x;
	endfunction

	task run_layer(input integer h, input integer wd, input integer c, input integer k, input integer avg);
		integer g, oh, ow, j, i, y, x, cc, e0, oy, ox, dy, dx, best, sum, idx, written, extra, n;
		reg signed [31:0] r;
		reg signed [7:0]  hv;
		begin
			fh = h; fw = wd; fc = c; pool_k = k; pool_avg = avg;
			out_h  = h / k;
			out_w  = wd / k;
			out_rp = (out_w + 3) / 4;
			out_ch = out_h * out_rp;
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

			if (fast != 0) begin
				if (k == 4) program_4x4_fast; else program_2x2_fast(avg);
			end
			else begin
				if (k == 4) program_4x4; else program_2x2(avg);
			end
			iss_reset;
			for (i = 0; i < OMAX * 4; i = i + 1) begin omem[i] = 8'hAA; owr[i] = 0; end
			n_st8a = 0; bad_addr = 0; n = 0;

			for (i = 0; i < n_pro; i = i + 1) iss_exec(prog_mem[i]);

			// packets in the array's order: filter groups, output rows, 4-pixel steps, columns (channels) of the group
			for (g = 0; g < (c + 3) / 4; g = g + 1)
				for (oh = 0; oh < h; oh = oh + 1)
					for (ow = 0; ow < wd; ow = ow + 4)
						for (j = 0; j < 4; j = j + 1)
							if (4 * g + j < c) begin
								cc = 4 * g + j;
								for (i = 0; i < LANES; i = i + 1)
									ipkt[i*32 +: 32] = (ow + i < wd) ? acc[fi(cc, oh, ow + i)] : 32'sd0;
								for (i = 0; i < LANES; i = i + 1) ibe[i] = (ow + i < wd);
								irow = oh[7:0]; icol = ow[7:0]; ichan = cc[7:0]; ilast = (j == 3);
								iaddr = 11'd0;
								for (i = n_pro; i < np; i = i + 1) iss_exec(prog_mem[i]);
								n = n + 1;
							end
			pkts_total = pkts_total + n;

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
			if (extra != written || bad_addr != 0) begin
				errors = errors + 1;
				$display("    FAIL: %0d bytes written, %0d expected (%0d stores to bad addresses)", extra, written, bad_addr);
			end
			layers = layers + 1;
			if (show != 0) show_layer;
			$display("  %2dx%-2d x%2d  %0s %0dx%0d -> %2dx%-2d: %4d packets, body %2d instr, %4d pooled values, %0d errors",
			         h, wd, c, (avg != 0) ? "avg" : "max", k, k, out_h, out_w, n, np - n_pro, written, errors - e0);
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
			$display("    channel 0 pooled, read back from the output memory:");
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
		errors = 0; layers = 0; pkts_total = 0; show = 0; fast = 0;
		iss_reset;

		$display("");
		$display("Pooling programs on the instruction-set model (no RTL yet).");
		$display("Packets come in the array's order with real tags; every ST8A lands in an output memory model,");
		$display("and the pooled maps are compared with a reference pooling of the requantized feature map.");

		$display("");
		$display("1) 2x2 max pooling, stride 2 (after requantize + ReLU):");
		show = 1;
		run_layer(6, 10, 2, 2, 0);
		show = 0;
		run_layer(28, 28, 8, 2, 0);
		run_layer(2, 2, 1, 2, 0);
		run_layer(3, 3, 1, 2, 0);
		run_layer(7, 13, 5, 2, 0);
		run_layer(16, 6, 3, 2, 0);
		run_layer(9, 1 + 4 * 15, 4, 2, 0);
		run_layer(64, 64, 2, 2, 0);

		$display("");
		$display("2) 4x4 max pooling, stride 4:");
		show = 1;
		run_layer(8, 12, 1, 4, 0);
		show = 0;
		run_layer(16, 16, 6, 4, 0);
		run_layer(4, 4, 1, 4, 0);
		run_layer(7, 7, 2, 4, 0);
		run_layer(13, 30, 5, 4, 0);
		run_layer(64, 64, 3, 4, 0);

		$display("");
		$display("3) 2x2 average pooling, stride 2 (requantize without ReLU, so negative values too):");
		show = 1;
		run_layer(4, 8, 1, 2, 1);
		show = 0;
		run_layer(14, 14, 8, 2, 1);
		run_layer(5, 9, 3, 2, 1);
		run_layer(32, 40, 4, 2, 1);

		$display("");
		$display("4) 60 random shapes (height and width 2..64, 1..16 channels, all three kinds):");
		for (t = 0; t < 60; t = t + 1) begin
			case (t % 3)
				0: run_layer(2 + {$random} % 63, 2 + {$random} % 63, 1 + {$random} % 16, 2, 0);
				1: run_layer(4 + {$random} % 61, 4 + {$random} % 61, 1 + {$random} % 16, 4, 0);
				default: run_layer(2 + {$random} % 63, 2 + {$random} % 63, 1 + {$random} % 16, 2, 1);
			endcase
		end

		$display("");
		$display("5) The same pooling with the address unit (TAG paddr / pbe / lmidx instead of scalar arithmetic):");
		fast = 1;
		show = 1;
		run_layer(6, 10, 2, 2, 0);
		show = 0;
		run_layer(28, 28, 8, 2, 0);
		run_layer(7, 13, 5, 2, 0);
		run_layer(9, 61, 4, 2, 0);
		run_layer(13, 30, 5, 4, 0);
		run_layer(7, 7, 2, 4, 0);
		run_layer(5, 9, 3, 2, 1);
		run_layer(32, 40, 4, 2, 1);
		for (t = 0; t < 60; t = t + 1) begin
			case (t % 3)
				0: run_layer(2 + {$random} % 63, 2 + {$random} % 63, 1 + {$random} % 16, 2, 0);
				1: run_layer(4 + {$random} % 61, 4 + {$random} % 61, 1 + {$random} % 16, 4, 0);
				default: run_layer(2 + {$random} % 63, 2 + {$random} % 63, 1 + {$random} % 16, 2, 1);
			endcase
		end

		$display("");
		$display("Totals: %0d layers, %0d packets, %0d errors", layers, pkts_total, errors);
		$display("");
		if (errors != 0) $fatal(1, "FAIL");
		$display("PASS: every pooled value matches the reference, written exactly once");
		$finish;
	end
endmodule
