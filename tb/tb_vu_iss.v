`timescale 1ns/1ps

module tb_vu_iss;
	parameter NPROG = 300;
	parameter NPKT  = 40;

	localparam LANES = 4;
	localparam ADDR  = 11;
	localparam W     = LANES * 32;
	localparam QMAX  = 4096;

	reg                 clk, rst_n;
	reg                 lut_we_tb;
	reg  [7:0]          lut_wa_tb;
	reg  [15:0]         lut_wd_tb;
	reg                 pm_we;
	reg  [5:0]          pm_waddr;
	reg  [31:0]         pm_wdata;
	reg  [5:0]          pro_start, body_start, epi_start;
	reg  [6:0]          pro_len, body_len, epi_len;
	reg                 layer_start, layer_end;
	wire                unused_busy, done;
	wire                pkt_valid, pkt_ready;
	wire [W-1:0]        pkt_data;
	wire [ADDR-1:0]     pkt_addr;
	wire [LANES-1:0]    pkt_be;
	wire [7:0]          pkt_row, pkt_col, pkt_chan;
	wire                pkt_last;
	wire                st_en;
	wire [ADDR-1:0]     st_addr;
	wire [LANES-1:0]    st_be;
	wire [LANES*8-1:0]  st_data;

	vector_unit #(.LANES(LANES), .ADDR(ADDR), .PM_AW(6)) dut (
		.clk(clk), .rst_n(rst_n),
		.pm_we(pm_we), .pm_waddr(pm_waddr), .pm_wdata(pm_wdata),
		.lut_we(lut_we_tb), .lut_waddr(lut_wa_tb), .lut_wdata(lut_wd_tb),
		.pro_start(pro_start), .pro_len(pro_len), .body_start(body_start), .body_len(body_len),
		.epi_start(epi_start), .epi_len(epi_len),
		.layer_start(layer_start), .layer_end(layer_end), .busy(unused_busy), .done(done),
		.pkt_valid(pkt_valid), .pkt_ready(pkt_ready), .pkt_data(pkt_data), .pkt_addr(pkt_addr), .pkt_be(pkt_be),
		.pkt_row(pkt_row), .pkt_col(pkt_col), .pkt_chan(pkt_chan), .pkt_last(pkt_last),
		.st_en(st_en), .st_addr(st_addr), .st_be(st_be), .st_data(st_data)
	);

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

	// ================================================================ interpreter state (the spec)
	reg  [W-1:0]        iv  [0:6];
	reg  [31:0]         is  [0:15];
	reg  [15:0]         iqp [0:3];
	reg  [15:0]         iqn [0:3];
	reg  [5:0]          iqs [0:3];
	reg  [31:0]         icl [0:3];
	reg  [31:0]         ich [0:3];
	reg  [W-1:0]        ipkt;
	reg  [ADDR-1:0]     iaddr;
	reg  [LANES-1:0]    ibe;
	reg  [7:0]          irow, icol, ichan;
	reg                 ilast;
	reg  [LANES-1:0]    imask;
	reg  [2:0]          ipt_tag [2:7];
	reg  [1:0]          ipt_op  [2:7];
	reg  [9:0]          ipt_val [2:7];
	reg  [31:0]         prog_mem [0:63];
	reg  [W-1:0]        lm  [0:255];
	reg  [15:0]         ilut [0:255];
	reg  [31:0]         ia_base, ia_chp, ia_rp;
	reg  [1:0]          ia_l;

	reg  [ADDR-1:0]     e_addr [0:QMAX-1];
	reg  [LANES-1:0]    e_be   [0:QMAX-1];
	reg  [LANES*8-1:0]  e_data [0:QMAX-1];
	integer             e_head, e_tail;

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

	function [W-1:0] vget(input [2:0] r);
		vget = (r == 3'd7) ? ipkt : iv[r];
	endfunction

	task vput(input [2:0] r, input [W-1:0] v);
		if (r != 3'd7) iv[r] = v;
	endtask

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

	function [31:0] tagv(input [3:0] t);
		reg [LANES-1:0] v;
		integer j;
		begin
			case (t)
				4'd6: tagv = ia_base + {24'd0, ichan} * {16'd0, ia_chp[15:0]} + {24'd0, irow >> ia_l} * {16'd0, ia_rp[15:0]}
				             + {24'd0, icol >> (ia_l + 2)};
				4'd7: begin
					v = {LANES{1'b0}};
					for (j = 0; j < (LANES >> ia_l); j = j + 1) v[j] = ibe[((j + 1) << ia_l) - 1];
					tagv = ({28'd0, v} << ((icol >> ia_l) & 3)) & 32'hF;
				end
				4'd8: tagv = {24'd0, 1'b0, ichan[1:0], 5'd0} + {26'd0, icol[7:2]};
				default: tagv = (t > 4'd8) ? 32'd0 : {21'd0, itag(t[2:0])};
			endcase
		end
	endfunction

	function ipred(input [2:0] p);
		reg [10:0] t, kmask, v;
		begin
			if (p == 3'd0 || p == 3'd1) ipred = 1'b1;
			else begin
				t     = itag(ipt_tag[p]);
				kmask = (11'd1 << ipt_val[p][9:6]) - 11'd1;
				v     = {5'd0, ipt_val[p][5:0]};
				case (ipt_op[p])
					2'd0:    ipred = (t == {1'b0, ipt_val[p]});
					2'd1:    ipred = (t != {1'b0, ipt_val[p]});
					2'd2:    ipred = ((t & kmask) == (v & kmask));
					default: ipred = ((t & kmask) != (v & kmask));
				endcase
			end
		end
	endfunction

	task iss_exec(input [31:0] w);
		reg [5:0]  op;
		reg [3:0]  d, a, b;
		reg [10:0] x;
		reg [31:0] simm15, simm19;
		reg [W-1:0] va, vb, vr;
		reg [LANES*8-1:0] sb;
		reg signed [31:0] la, lb, c;
		reg [2:0] pr;
		reg [63:0] q64;
		reg [LANES-1:0] wl;
		reg [W-1:0] old;
		integer i;
		begin
			pr = w[25:23];
			op = w[31:26]; d = w[22:19]; a = w[18:15]; b = w[14:11]; x = w[10:0];
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
				6'h08: if (d != 0) is[d] = tagv(x[3:0]);
				6'h0E: if (d != 0) is[d] = $signed(is[a]) * $signed(is[b][15:0]);
				6'h0B: if (d != 0) begin
					q64 = (64'd1 << x[4:0]) / {32'd0, is[a]};
					if (q64[63:32] != 32'd0) $fatal(1, "RCP reference: quotient wider than 32 bits");
					is[d] = (is[a] == 32'd0) ? 32'hFFFFFFFF : q64[31:0];
				end
				6'h32: if (d != 0) begin
					c = 32'sh80000000;
					for (i = 0; i < LANES; i = i + 1)
						if (ibe[i] && $signed(va[i*32 +: 32]) > c) c = va[i*32 +: 32];
					is[d] = c;
				end
				6'h33: if (d != 0) begin
					c = 0;
					for (i = 0; i < LANES; i = i + 1) if (ibe[i]) c = c + va[i*32 +: 32];
					is[d] = c;
				end
				6'h3D: ilut[is[a][7:0]] = is[b][15:0];
				6'h0F: if (d != 0) is[d] = is[a] << is[b][4:0];
				6'h14: case (x[1:0])
					2'd0: ia_base = is[a];
					2'd1: ia_chp  = {16'd0, is[a][15:0]};
					2'd2: ia_rp   = {16'd0, is[a][15:0]};
					default: ia_l = is[a][1:0];
				endcase
				6'h3B: if (d[2:0] != 3'd7) begin
					old = iv[d[2:0]];
					vr  = lm[is[a][7:0]];
					for (i = 0; i < LANES; i = i + 1) if (!wl[i]) vr[i*32 +: 32] = old[i*32 +: 32];
					iv[d[2:0]] = vr;
				end
				6'h3E: if (d[2:0] != 3'd7) begin
					old = iv[d[2:0]];
					for (i = 0; i < LANES; i = i + 1) begin
						la = {{24{lm[is[a][9:2]][i*32 + is[a][1:0]*8 + 7]}}, lm[is[a][9:2]][i*32 + is[a][1:0]*8 +: 8]};
						vr[i*32 +: 32] = wl[i] ? la : old[i*32 +: 32];
					end
					iv[d[2:0]] = vr;
				end
				6'h3C: for (i = 0; i < LANES; i = i + 1) if (wl[i]) lm[is[b][7:0]][i*32 +: 32] = va[i*32 +: 32];
				6'h3F: for (i = 0; i < LANES; i = i + 1)
					if (wl[i]) begin
						la = va[i*32 +: 32];
						la = (la < -128) ? -32'sd128 : ((la > 127) ? 32'sd127 : la);
						lm[is[b][9:2]][i*32 + is[b][1:0]*8 +: 8] = la[7:0];
					end
				6'h39: begin
					for (i = 0; i < LANES; i = i + 1) begin
						c = f_clamp(va[i*32 +: 32], icl[x[1:0]], ich[x[1:0]]);
						c = (c < -128) ? -32'sd128 : ((c > 127) ? 32'sd127 : c);
						sb[i*8 +: 8] = c[7:0];
					end
					e_addr[e_tail % QMAX] = is[b][ADDR-1:0];
					e_be[e_tail % QMAX]   = is[d][LANES-1:0] & wl;
					e_data[e_tail % QMAX] = sb;
					e_tail = e_tail + 1;
				end
				6'h04: if (d != 0) is[d] = is[a] + is[b];
				6'h05: if (d != 0) is[d] = is[a] + simm15;
				6'h06: if (d != 0) is[d] = is[a] << x[4:0];
				6'h07: if (d != 0) is[d] = $signed(is[a]) >>> x[4:0];
				6'h0D: if (d != 0) is[d] = is[a] & {17'd0, b, x};
				6'h0C: if (d[2:1] != 2'b00) begin ipt_tag[d[2:0]] = x[2:0]; ipt_op[d[2:0]] = x[4:3]; ipt_val[d[2:0]] = {b, x[10:5]}; end
				6'h28: for (i = 0; i < LANES; i = i + 1) imask[i] = $signed(va[i*32 +: 32]) > $signed(vb[i*32 +: 32]);
				6'h29: for (i = 0; i < LANES; i = i + 1) imask[i] = va[i*32 +: 32] == vb[i*32 +: 32];
				6'h2B: imask = ibe;
				6'h09: begin iqp[d[1:0]] = is[a][15:0]; iqn[d[1:0]] = is[b][15:0]; iqs[d[1:0]] = x[5:0]; end
				6'h0A: begin icl[d[1:0]] = is[a]; ich[d[1:0]] = is[b]; end
				6'h23, 6'h10, 6'h11, 6'h12, 6'h13, 6'h2A, 6'h18, 6'h19, 6'h1A, 6'h1B, 6'h1C, 6'h1D, 6'h1E, 6'h1F,
				6'h20, 6'h21, 6'h22, 6'h30, 6'h31, 6'h34, 6'h35: begin
					for (i = 0; i < LANES; i = i + 1) begin
						la = va[i*32 +: 32];
						lb = vb[i*32 +: 32];
						case (op)
							6'h10: c = la;
							6'h11: c = simm15;
							6'h12: c = is[a];
							6'h13: c = i;
							6'h2A: c = imask[i] ? la : lb;
							6'h23: c = {{16{ilut[la[7:0]][15]}}, ilut[la[7:0]]};
							6'h34: c = va[x[2*i +: 2]*32 +: 32];
							6'h35: c = va[is[b][2*i +: 2]*32 +: 32];
							6'h30, 6'h31: begin
								if (2 * i + 1 < LANES) begin
									la = va[(2*i)*32 +: 32];
									lb = va[(2*i+1)*32 +: 32];
									c  = (op == 6'h30) ? ((la > lb) ? la : lb) : la + lb;
								end
								else c = 0;
							end
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
							default: c = f_clamp(la, icl[x[1:0]], ich[x[1:0]]);
						endcase
						vr[i*32 +: 32] = c;
					end
					old = vget(d[2:0]);
					for (i = 0; i < LANES; i = i + 1)
						if (!wl[i]) vr[i*32 +: 32] = old[i*32 +: 32];
					vput(d[2:0], vr);
				end
				6'h38: begin
					for (i = 0; i < LANES; i = i + 1) begin
						c = f_clamp(va[i*32 +: 32], icl[x[1:0]], ich[x[1:0]]);
						c = (c < -128) ? -32'sd128 : ((c > 127) ? 32'sd127 : c);
						sb[i*8 +: 8] = c[7:0];
					end
					e_addr[e_tail % QMAX] = iaddr;
					e_be[e_tail % QMAX]   = ibe & wl;
					e_data[e_tail % QMAX] = sb;
					e_tail = e_tail + 1;
				end
				default: begin end
			endcase
		end
	endtask

	task iss_section(input integer start, input integer len);
		integer i;
		for (i = 0; i < len; i = i + 1) iss_exec(prog_mem[start + i]);
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
			ipkt = {W{1'b0}}; iaddr = {ADDR{1'b0}}; ibe = {LANES{1'b0}};
			irow = 8'd0; icol = 8'd0; ichan = 8'd0; ilast = 1'b0; imask = {LANES{1'b0}};
			ia_base = 32'd0; ia_chp = 32'd0; ia_rp = 32'd0; ia_l = 2'd0;
			for (i = 2; i < 8; i = i + 1) begin ipt_tag[i] = 3'd0; ipt_op[i] = 2'd0; ipt_val[i] = 10'd0; end
		end
	endtask

	// ================================================================ random program generator
	integer pro_n, body_n, epi_n, cur_prog;
	integer op_hist [0:63];

	function [31:0] rnd_ins(input integer must_store);
		integer k;
		reg [5:0] op;
		reg [3:0] d, a, b;
		reg [10:0] x;
		begin
			d = 4'($random); a = 4'($random); b = 4'($random); x = 11'($random);
			k = (must_store != 0) ? 21 : {$random} % 60;
			case (k)
				0:  op = 6'h01;  1: op = 6'h02;  2: op = 6'h03;  3: op = 6'h08;
				4:  op = 6'h09;  5: op = 6'h0A;  6: op = 6'h10;  7: op = 6'h11;
				8:  op = 6'h12;  9: op = 6'h18; 10: op = 6'h19; 11: op = 6'h1A;
				12: op = 6'h1B; 13: op = 6'h1C; 14: op = 6'h1D; 15: op = 6'h1E;
				16: op = 6'h1F; 17: op = 6'h20; 18: op = 6'h21; 19: op = 6'h22;
				20: op = 6'h21; 21: op = 6'h38; 22: op = 6'h20;
				23: op = 6'h04; 24: op = 6'h05; 25: op = 6'h06; 26: op = 6'h07;
				27: op = 6'h0D; 28: op = 6'h0C; 29: op = 6'h0C; 30: op = 6'h13;
				31: op = 6'h28; 32: op = 6'h29; 33: op = 6'h2A; 34: op = 6'h2B;
				35, 36, 37: op = 6'h30;
				38: op = 6'h31; 39: op = 6'h31;
				40: op = 6'h34; 41: op = 6'h35;
				42: op = 6'h0E; 43: op = 6'h0F; 44: op = 6'h14; 45: op = 6'h14;
				46: op = 6'h39; 47: op = 6'h3B; 48: op = 6'h3C; 49: op = 6'h3E;
				50: op = 6'h3F; 51: op = 6'h3B; 52: op = 6'h3C; 53: op = 6'h08;
				54: op = 6'h32; 55: op = 6'h33; 56: op = 6'h23; 57: op = 6'h23;
				58: op = 6'h3D; default: op = 6'h0B;
			endcase
			if (op == 6'h09 && x[5:0] > 6'd47) x[5:0] = x[5:0] - 6'd16;
			if (op == 6'h08 && ({$random} % 2) == 1) x[3:0] = 4'(6 + {$random} % 3);
			op_hist[op] = op_hist[op] + 1;
			k = {$random} % 10;
			rnd_ins = {op, (k < 5) ? 3'd0 : ((k < 7) ? 3'd1 : 3'(2 + {$random} % 6)), d, a, b, x};
		end
	endfunction

	task make_program;
		integer i;
		begin
			pro_n  = 2 + {$random} % 10;
			body_n = 1 + {$random} % 24;
			epi_n  = {$random} % 8;
			for (i = 0; i < pro_n; i = i + 1)  prog_mem[i] = rnd_ins(0);
			for (i = 0; i < body_n; i = i + 1) prog_mem[pro_n + i] = rnd_ins(({$random} % 4 == 0) ? 1 : 0);
			prog_mem[pro_n + body_n - 1] = rnd_ins(1);
			for (i = 0; i < epi_n; i = i + 1)  prog_mem[pro_n + body_n + i] = rnd_ins(({$random} % 3 == 0) ? 1 : 0);
			for (i = pro_n + body_n + epi_n; i < 64; i = i + 1) prog_mem[i] = 32'h0;
		end
	endtask

	// ================================================================ packets, stores, state check
	reg  [W-1:0]        p_data [0:NPKT-1];
	reg  [ADDR-1:0]     p_addr [0:NPKT-1];
	reg  [LANES-1:0]    p_be   [0:NPKT-1];
	reg  [7:0]          p_row  [0:NPKT-1];
	reg  [7:0]          p_col  [0:NPKT-1];
	reg  [7:0]          p_chan [0:NPKT-1];
	reg                 p_last [0:NPKT-1];
	integer             p_idx, avail_pct, errors, stores, state_err, cyc, busy_cycles, issued;
	reg                 avail, took;

	assign pkt_valid = avail && (p_idx < NPKT);
	assign pkt_data  = p_data[(p_idx < NPKT) ? p_idx : 0];
	assign pkt_addr  = p_addr[(p_idx < NPKT) ? p_idx : 0];
	assign pkt_be    = p_be[(p_idx < NPKT) ? p_idx : 0];
	assign pkt_row   = p_row[(p_idx < NPKT) ? p_idx : 0];
	assign pkt_col   = p_col[(p_idx < NPKT) ? p_idx : 0];
	assign pkt_chan  = p_chan[(p_idx < NPKT) ? p_idx : 0];
	assign pkt_last  = p_last[(p_idx < NPKT) ? p_idx : 0];

	always @(posedge clk) cyc <= cyc + 1;

	initial begin
		took = 1'b0;
		forever begin
			@(posedge clk);
			took = pkt_valid && pkt_ready;
			if (took) begin
				ipkt  = p_data[p_idx];
				iaddr = p_addr[p_idx];
				ibe   = p_be[p_idx];
				irow  = p_row[p_idx];
				icol  = p_col[p_idx];
				ichan = p_chan[p_idx];
				ilast = p_last[p_idx];
				iss_section(pro_n, body_n);
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
				if (e_head == e_tail) begin
					errors = errors + 1;
					if (errors <= 10) $display("FAIL program %0d: unexpected store", cur_prog);
				end
				else begin
					if (st_addr !== e_addr[e_head % QMAX] || st_be !== e_be[e_head % QMAX] || st_data !== e_data[e_head % QMAX]) begin
						errors = errors + 1;
						if (errors <= 10)
							$display("FAIL program %0d: store addr=%0d be=%b data=%h, interpreter says addr=%0d be=%b data=%h",
							         cur_prog, st_addr, st_be, st_data, e_addr[e_head % QMAX], e_be[e_head % QMAX], e_data[e_head % QMAX]);
					end
					e_head = e_head + 1;
				end
			end
		end
	end

	task check_state;
		integer i;
		begin
			for (i = 0; i < 7; i = i + 1)
				if (dut.u_regs.vreg[i] !== iv[i]) begin
					state_err = state_err + 1;
					if (state_err <= 10) $display("FAIL program %0d: v%0d = %h, interpreter %h", cur_prog, i, dut.u_regs.vreg[i], iv[i]);
				end
			for (i = 1; i < 16; i = i + 1)
				if (dut.u_regs.sreg[i] !== is[i]) begin
					state_err = state_err + 1;
					if (state_err <= 10) $display("FAIL program %0d: s%0d = %h, interpreter %h", cur_prog, i, dut.u_regs.sreg[i], is[i]);
				end
			for (i = 0; i < 4; i = i + 1)
				if (dut.u_regs.q_mp[i] !== iqp[i] || dut.u_regs.q_mn[i] !== iqn[i] || dut.u_regs.q_sh[i] !== iqs[i] ||
				    dut.u_regs.c_l[i] !== icl[i] || dut.u_regs.c_h[i] !== ich[i]) begin
					state_err = state_err + 1;
					if (state_err <= 10) $display("FAIL program %0d: requant/clamp set %0d differs", cur_prog, i);
				end
			for (i = 0; i < 256; i = i + 1)
				if (dut.lmem[i] !== lm[i]) begin
					state_err = state_err + 1;
					if (state_err <= 10) $display("FAIL program %0d: local memory entry %0d differs", cur_prog, i);
				end
			for (i = 0; i < 256; i = i + 1)
				if (dut.lut[i] !== ilut[i]) begin
					state_err = state_err + 1;
					if (state_err <= 10) $display("FAIL program %0d: lookup-table entry %0d differs", cur_prog, i);
				end
			if (dut.ar_base !== ia_base || {16'd0, dut.ar_chp} !== ia_chp || {16'd0, dut.ar_rp} !== ia_rp || dut.ar_l !== ia_l) begin
				state_err = state_err + 1;
				if (state_err <= 10) $display("FAIL program %0d: address-unit settings differ", cur_prog);
			end
			if (dut.mask !== imask) begin
				state_err = state_err + 1;
				if (state_err <= 10) $display("FAIL program %0d: mask = %b, interpreter %b", cur_prog, dut.mask, imask);
			end
			for (i = 2; i < 8; i = i + 1)
				if (dut.pt_tag[i] !== ipt_tag[i] || dut.pt_op[i] !== ipt_op[i] || dut.pt_val[i] !== ipt_val[i]) begin
					state_err = state_err + 1;
					if (state_err <= 10) $display("FAIL program %0d: predicate entry %0d differs", cur_prog, i);
				end
		end
	endtask

	task show_program;
		integer i;
		begin
			$display("    example random program (%0d prologue, %0d body, %0d epilogue instructions), hex words:", pro_n, body_n, epi_n);
			$write("     prologue:");
			for (i = 0; i < pro_n; i = i + 1) $write(" %h", prog_mem[i]);
			$display("");
			$write("     body:    ");
			for (i = 0; i < body_n; i = i + 1) $write(" %h", prog_mem[pro_n + i]);
			$display("");
			$write("     epilogue:");
			for (i = 0; i < epi_n; i = i + 1) $write(" %h", prog_mem[pro_n + body_n + i]);
			$display("");
		end
	endtask

	task run_program;
		integer i, j, t0;
		begin
			make_program;
			for (i = 0; i < NPKT; i = i + 1) begin
				for (j = 0; j < LANES; j = j + 1)
					case ({$random} % 4)
						0:       p_data[i][j*32 +: 32] = $random;
						1:       p_data[i][j*32 +: 32] = $random % 1000;
						2:       p_data[i][j*32 +: 32] = $random % 100000;
						default: p_data[i][j*32 +: 32] = $random % 20000000;
					endcase
				p_addr[i] = ADDR'($random);
				p_be[i]   = LANES'($random);
				p_row[i]  = 8'({$random} % 8);
				p_col[i]  = 8'(4 * ({$random} % 4));
				p_chan[i] = 8'({$random} % 6);
				p_last[i] = ({$random} % 4) == 0;
			end

			for (i = 0; i < pro_n + body_n + epi_n; i = i + 1) begin
				@(negedge clk);
				pm_we    = 1'b1;
				pm_waddr = i[5:0];
				pm_wdata = prog_mem[i];
			end
			@(negedge clk);
			pm_we      = 1'b0;
			pro_start  = 6'd0;
			pro_len    = pro_n[6:0];
			body_start = pro_n[5:0];
			body_len   = body_n[6:0];
			epi_start  = 6'(pro_n + body_n);
			epi_len    = epi_n[6:0];

			iss_reset;
			for (i = 0; i < 7; i = i + 1)  iv[i] = dut.u_regs.vreg[i];
			for (i = 1; i < 16; i = i + 1) is[i] = dut.u_regs.sreg[i];
			for (i = 0; i < 4; i = i + 1) begin
				iqp[i] = dut.u_regs.q_mp[i]; iqn[i] = dut.u_regs.q_mn[i]; iqs[i] = dut.u_regs.q_sh[i];
				icl[i] = dut.u_regs.c_l[i];  ich[i] = dut.u_regs.c_h[i];
			end
			ipkt = dut.cur_data; iaddr = dut.cur_addr; ibe = dut.cur_be;
			irow = dut.cur_row; icol = dut.cur_col; ichan = dut.cur_chan; ilast = dut.cur_last; imask = dut.mask;
			ia_base = dut.ar_base; ia_chp = {16'd0, dut.ar_chp}; ia_rp = {16'd0, dut.ar_rp}; ia_l = dut.ar_l;
			for (i = 0; i < 256; i = i + 1) lm[i] = dut.lmem[i];
			for (i = 0; i < 256; i = i + 1) ilut[i] = dut.lut[i];
			for (i = 2; i < 8; i = i + 1) begin
				ipt_tag[i] = dut.pt_tag[i]; ipt_op[i] = dut.pt_op[i]; ipt_val[i] = dut.pt_val[i];
			end
			iss_section(0, pro_n);

			p_idx = 0;
			avail_pct = 20 + {$random} % 81;
			t0 = cyc;
			@(negedge clk);
			layer_start = 1'b1;
			@(negedge clk);
			layer_start = 1'b0;
			while (p_idx < NPKT) @(negedge clk);
			iss_section(pro_n + body_n, epi_n);
			layer_end = 1'b1;
			@(negedge clk);
			layer_end = 1'b0;
			i = 0;
			while (!done) begin
				@(negedge clk);
				i = i + 1;
				if (i > 50000) $fatal(1, "program %0d: done never arrived", cur_prog);
			end
			busy_cycles = busy_cycles + (cyc - t0);
			issued      = issued + pro_n + NPKT * body_n + epi_n;
			repeat (2) @(negedge clk);
			check_state;
		end
	endtask

	integer n;

	initial begin
		if ($test$plusargs("vcd")) begin
			$dumpfile("waveforms/vu_iss.vcd");
			$dumpvars(0, tb_vu_iss);
		end

		errors = 0; stores = 0; state_err = 0; cyc = 0; busy_cycles = 0; issued = 0;
		e_head = 0; e_tail = 0; p_idx = NPKT; avail = 1'b0; avail_pct = 100; cur_prog = 0;
		pro_n = 0; body_n = 0; epi_n = 0;
		for (n = 0; n < 64; n = n + 1) op_hist[n] = 0;
		pm_we = 1'b0; pm_waddr = 0; pm_wdata = 0;
		pro_start = 0; pro_len = 0; body_start = 0; body_len = 0; epi_start = 0; epi_len = 0;
		layer_start = 1'b0; layer_end = 1'b0;
		for (n = 0; n < NPKT; n = n + 1) begin
			p_data[n] = 0; p_addr[n] = 0; p_be[n] = 0;
			p_row[n] = 0; p_col[n] = 0; p_chan[n] = 0; p_last[n] = 0;
		end
		iss_reset;

		lut_we_tb = 1'b0; lut_wa_tb = 8'd0; lut_wd_tb = 16'd0;
		rst_n = 1'b0;
		repeat (2) @(negedge clk);
		rst_n = 1'b1;
		for (n = 0; n < 256; n = n + 1) begin
			@(negedge clk);
			lut_we_tb = 1'b1;
			lut_wa_tb = n[7:0];
			lut_wd_tb = 16'($random);
		end
		@(negedge clk);
		lut_we_tb = 1'b0;

		$display("");
		$display("vector_unit against the instruction-set interpreter: %0d random programs, %0d packets each", NPROG, NPKT);
		$display("(random instruction mixes, random registers and immediates, packets arriving irregularly;");
		$display(" every store and the final contents of every register are compared with the interpreter)");
		$display("");

		for (cur_prog = 0; cur_prog < NPROG; cur_prog = cur_prog + 1) begin
			run_program;
			if (cur_prog == 0) show_program;
		end

		$display("");
		$display("  instructions generated per type:");
		$display("    LI %0d  LUI %0d  ORI %0d  TAG %0d  SETQ %0d  SETC %0d  MOV %0d  VLI %0d  BCAST %0d",
		         op_hist[6'h01], op_hist[6'h02], op_hist[6'h03], op_hist[6'h08], op_hist[6'h09], op_hist[6'h0A],
		         op_hist[6'h10], op_hist[6'h11], op_hist[6'h12]);
		$display("    ADD %0d  SUB %0d  ADDI %0d  MAX %0d  MIN %0d  SHL %0d  SHR %0d  SHRR %0d  MUL %0d  REQ %0d  CLAMP %0d  ST8 %0d",
		         op_hist[6'h18], op_hist[6'h19], op_hist[6'h1A], op_hist[6'h1B], op_hist[6'h1C], op_hist[6'h1D],
		         op_hist[6'h1E], op_hist[6'h1F], op_hist[6'h20], op_hist[6'h21], op_hist[6'h22], op_hist[6'h38]);
		$display("    ADDS %0d  ADDIS %0d  SHLS %0d  SHRS %0d  ANDIS %0d  SETP %0d  IDX %0d  CMPGT %0d  CMPEQ %0d  SEL %0d  MBE %0d",
		         op_hist[6'h04], op_hist[6'h05], op_hist[6'h06], op_hist[6'h07], op_hist[6'h0D], op_hist[6'h0C],
		         op_hist[6'h13], op_hist[6'h28], op_hist[6'h29], op_hist[6'h2A], op_hist[6'h2B]);
		$display("    MAXP %0d  ADDP %0d  PERM %0d  PERMS %0d", op_hist[6'h30], op_hist[6'h31], op_hist[6'h34], op_hist[6'h35]);
		$display("    RMAX %0d  RADD %0d  LUT %0d  LUTW %0d  RCP %0d",
		         op_hist[6'h32], op_hist[6'h33], op_hist[6'h23], op_hist[6'h3D], op_hist[6'h0B]);
		$display("    MULS %0d  SLLV %0d  SETR %0d  ST8A %0d  LDS %0d  STS %0d  LDS8 %0d  STS8 %0d",
		         op_hist[6'h0E], op_hist[6'h0F], op_hist[6'h14], op_hist[6'h39], op_hist[6'h3B], op_hist[6'h3C],
		         op_hist[6'h3E], op_hist[6'h3F]);
		$display("    (half of all instructions carry a predicate: 20%% lane mask, 30%% packet predicates P2-P7)");
		$display("  %0d instructions executed in %0d cycles (the difference is interlock stalls and waiting for packets)",
		         issued, busy_cycles);
		$display("  %0d stores compared, %0d store mismatches, %0d register-state mismatches, %0d expected stores missing",
		         stores, errors, state_err, e_tail - e_head);
		$display("");
		if (e_head != e_tail) errors = errors + 1;
		if (errors + state_err != 0) $fatal(1, "FAIL");
		$display("PASS: the hardware matches the interpreter on every program");
		$finish;
	end
endmodule
