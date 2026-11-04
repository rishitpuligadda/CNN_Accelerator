`timescale 1ns/1ps

module tb_accel_top;
	localparam EAW    = 16;
	localparam N      = 4;
	localparam ADDR   = 11;
	localparam EWORDS = 1 << EAW;
	localparam IMG_EB = 0;
	localparam WGT_EB = 16384;
	localparam TBL_EB = 49152;            // layer table
	localparam WB_EB  = 57344;            // the chip writes its result here
	localparam QMAX   = 65536;
	localparam SQ     = 32;
	localparam KQ     = 49;

	reg                     clk, rst_n, start;
	wire                    busy, done, err_valid;
	wire [6:0]              err;
	reg  [EAW-1:0]          img_ext_base, wgt_ext_base;
	reg  [7:0]              in_h, in_w, in_c, n_filt;
	reg  [2:0]              k_h, k_w, pad, stride;
	reg  [ADDR-1:0]         out_base;

	wire                    rd_req_valid, rd_req_ready, rd_resp_valid, rd_resp_ready;
	wire [EAW-1:0]          rd_req_addr;
	wire [31:0]             rd_resp_data;
	// the packets now go from the FIFO into the vector unit inside the chip; the testbench watches them there
	wire                    pkt_valid = dut.pkt_valid;
	wire                    pkt_ready = dut.pkt_ready;
	wire                    pkt_last  = dut.pkt_last;
	wire                    pkt_take  = pkt_valid && pkt_ready;
	wire [N*32-1:0]         pkt_data  = dut.pkt_data;
	wire [ADDR-1:0]         pkt_addr  = dut.pkt_addr;
	wire [N-1:0]            pkt_be    = dut.pkt_be;
	wire [7:0]              pkt_row   = dut.pkt_row;
	wire [7:0]              pkt_col   = dut.pkt_col;
	wire [7:0]              pkt_chan  = dut.pkt_chan;

	reg  [1:0]              pool;
	reg  [EAW-1:0]          tbl_base;
	wire                    wr_req_valid, wr_req_ready;
	wire [EAW-1:0]          wr_req_addr;
	wire [31:0]             wr_req_data;
	reg                     wr_rdy_r;
	integer                 wb_count;

	reg  [31:0]             ext_mem [0:EWORDS-1];
	integer                 img  [0:16*SQ*SQ-1];
	integer                 wt   [0:64*16*KQ-1];
	integer                 refo [0:64*SQ*SQ-1];
	integer                 bias_v [0:255];
	integer                 got  [0:64*SQ*SQ-1];
	integer                 hw   [0:64*SQ*SQ-1];

	reg  [N*32-1:0]         e_data [0:QMAX-1];
	reg  [ADDR-1:0]         e_addr [0:QMAX-1];
	reg  [N-1:0]            e_be   [0:QMAX-1];
	reg                     e_last [0:QMAX-1];
	reg  [7:0]              e_row  [0:QMAX-1];
	reg  [7:0]              e_col  [0:QMAX-1];
	reg  [7:0]              e_chan [0:QMAX-1];
	integer                 q_head, q_tail, mon_err, pkts, cyc;

	reg  [EAW-1:0]          q_addr [0:31];
	integer                 q_due  [0:31];
	integer                 sq_head, sq_tail, sq_count, lat_min, lat_max, rdy_pct;
	reg                     rdy_r, mem_on;
	wire                    req_fire  = rd_req_valid && rd_req_ready;
	wire                    resp_fire = rd_resp_valid && rd_resp_ready;

	integer L_H, L_W, L_C, L_F, L_KH, L_KW, L_P, L_S, L_RP, L_CH, L_OH, L_OW, L_M, L_G, L_ORP, L_OCH;
	integer errors, layers, small_vals, fd, total_cycles, total_ideal;
	reg [8*32:1] fname;

	accel_top #(.EAW(EAW), .N(N), .ADDR(ADDR)) dut (
		.clk(clk), .rst_n(rst_n), .start(start), .busy(busy), .done(done), .err_valid(err_valid), .err(err),
		.tbl_base(tbl_base),
		.rd_req_valid(rd_req_valid), .rd_req_ready(rd_req_ready), .rd_req_addr(rd_req_addr),
		.rd_resp_valid(rd_resp_valid), .rd_resp_data(rd_resp_data), .rd_resp_ready(rd_resp_ready),
		.wr_req_valid(wr_req_valid), .wr_req_ready(wr_req_ready), .wr_req_addr(wr_req_addr), .wr_req_data(wr_req_data)
	);

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

	// write channel: accepted with the same randomness as reads; the data lands in ext_mem
	assign wr_req_ready = mem_on && wr_rdy_r;
	// the ready signal changes with a non-blocking assignment, so the chip and this model both see the
	// value from before the clock edge (a blocking update here would race with the chip's sampling)
	always @(posedge clk) wr_rdy_r <= ({$random} % 100) < rdy_pct;

	initial begin
		wb_count = 0;
		forever begin
			@(posedge clk);
			if (wr_req_valid && wr_req_ready) begin
				ext_mem[wr_req_addr] = wr_req_data;
				wb_count = wb_count + 1;
			end
		end
	end

	assign rd_req_ready  = mem_on && rdy_r && (sq_count < 32);
	assign rd_resp_valid = mem_on && (sq_count != 0) && (q_due[sq_head] <= cyc);
	assign rd_resp_data  = ext_mem[q_addr[sq_head]];

	always @(posedge clk) begin
		cyc   <= cyc + 1;
		rdy_r <= ({$random} % 100) < rdy_pct;
		if (!mem_on) begin
			sq_head  <= 0;
			sq_tail  <= 0;
			sq_count <= 0;
		end
		else begin
			if (req_fire) begin
				q_addr[sq_tail] <= rd_req_addr;
				q_due[sq_tail]  <= cyc + lat_min + ({$random} % (lat_max - lat_min + 1));
				sq_tail         <= (sq_tail + 1) % 32;
			end
			if (resp_fire) sq_head <= (sq_head + 1) % 32;
			if (req_fire && !resp_fire)      sq_count <= sq_count + 1;
			else if (!req_fire && resp_fire) sq_count <= sq_count - 1;
		end
	end

	function integer oidx(input integer f, input integer y, input integer x);
		oidx = f * SQ * SQ + y * SQ + x;
	endfunction

	function integer widx(input integer f, input integer kk);
		widx = f * 16 * KQ + kk;
	endfunction

	always @(posedge clk) begin
		if (mem_on && pkt_take) begin
			pkts <= pkts + 1;
			if (q_head == q_tail) begin
				mon_err <= mon_err + 1;
				$display("FAIL t=%0t: unexpected packet addr=%0d", $time, pkt_addr);
			end
			else if (pkt_data !== e_data[q_head] || pkt_addr !== e_addr[q_head] ||
			         pkt_be !== e_be[q_head] || pkt_last !== e_last[q_head] ||
			         pkt_row !== e_row[q_head] || pkt_col !== e_col[q_head] || pkt_chan !== e_chan[q_head]) begin
				mon_err <= mon_err + 1;
				if (mon_err < 10)
					$display("FAIL t=%0t: packet addr=%0d be=%b last=%b data=%h, expected addr=%0d be=%b last=%b data=%h",
					         $time, pkt_addr, pkt_be, pkt_last, pkt_data,
					         e_addr[q_head], e_be[q_head], e_last[q_head], e_data[q_head]);
			end
			q_head <= q_head + 1;
		end
	end

	task decode_pkt;
		integer f, y, x0, i, rel;
		begin
			rel = {21'd0, pkt_addr};
			rel = rel - 1;
			f   = rel / L_OCH;
			y   = (rel % L_OCH) / L_ORP;
			x0  = ((rel % L_OCH) % L_ORP) * 4;
			for (i = 0; i < N; i = i + 1)
				if (pkt_be[i] && f < L_F && y < L_OH && x0 + i < L_OW) begin
					got[oidx(f, y, x0 + i)] = got[oidx(f, y, x0 + i)] + 1;
					hw[oidx(f, y, x0 + i)]  = $signed(pkt_data[i*32 +: 32]);
					if ($signed(pkt_data[i*32 +: 32]) != refo[oidx(f, y, x0 + i)]) begin
						errors = errors + 1;
						if (errors <= 10)
							$display("FAIL output f=%0d y=%0d x=%0d: got %0d, reference %0d",
							         f, y, x0 + i, $signed(pkt_data[i*32 +: 32]), refo[oidx(f, y, x0 + i)]);
					end
				end
		end
	endtask

	task source(input integer lmin, input integer lmax, input integer rpct);
		begin
			lat_min = lmin;
			lat_max = lmax;
			rdy_pct = rpct;
		end
	endtask

	task print_outputs(input integer f, input integer maxr, input integer maxcol);
		integer y, x, nr, nc;
		begin
			nr = (L_OH < maxr) ? L_OH : maxr;
			nc = (L_OW < maxcol) ? L_OW : maxcol;
			$display("    filter %0d outputs, rows 0-%0d, columns 0-%0d   (hardware | reference, * = mismatch)", f, nr - 1, nc - 1);
			for (y = 0; y < nr; y = y + 1) begin
				$write("      ");
				for (x = 0; x < nc; x = x + 1) $write("%8d", hw[oidx(f, y, x)]);
				$write("   |");
				for (x = 0; x < nc; x = x + 1) $write("%8d", refo[oidx(f, y, x)]);
				for (x = 0; x < nc; x = x + 1)
					if (hw[oidx(f, y, x)] != refo[oidx(f, y, x)]) $write(" *");
				$display("");
			end
		end
	endtask

	task print_small;
		integer y, x, f, kh, kw;
		begin
			$display("    input channel 0:");
			for (y = 0; y < L_H; y = y + 1) begin
				$write("      ");
				for (x = 0; x < L_W; x = x + 1) $write("%5d", img[y * SQ + x]);
				$display("");
			end
			for (f = 0; f < L_F; f = f + 1) begin
				$display("    filter %0d weights (bias %0d):", f, bias_v[f]);
				for (kh = 0; kh < L_KH; kh = kh + 1) begin
					$write("      ");
					for (kw = 0; kw < L_KW; kw = kw + 1) $write("%5d", wt[widx(f, kh * L_KW + kw)]);
					$display("");
				end
			end
			for (f = 0; f < L_F; f = f + 1) print_outputs(f, L_OH, L_OW);
		end
	endtask

	task explain_one(input integer f, input integer oh, input integer ow);
		integer kh, kw, y, x, v, sum;
		begin
			$display("    by hand: filter %0d output at (%0d,%0d) uses input rows %0d.. and columns %0d.. (stride %0d)",
			         f, oh, ow, oh * L_S - L_P, ow * L_S - L_P, L_S);
			sum = 0;
			for (kh = 0; kh < L_KH; kh = kh + 1) begin
				$write("      ");
				for (kw = 0; kw < L_KW; kw = kw + 1) begin
					y = oh * L_S + kh - L_P;
					x = ow * L_S + kw - L_P;
					v = (y >= 0 && y < L_H && x >= 0 && x < L_W) ? img[y * SQ + x] : 0;
					sum = sum + v * wt[widx(f, kh * L_KW + kw)];
					$write("  %2d x %2d", v, wt[widx(f, kh * L_KW + kw)]);
				end
				$display("");
			end
			$display("      products = %0d, + bias %0d = %0d, hardware gave %0d", sum, bias_v[f], sum + bias_v[f], hw[oidx(f, oh, ow)]);
		end
	endtask

	task dump_layer;
		integer c, y, x, f, kk;
		begin
			$sformat(fname, "outputs/layer%0d_outputs.txt", layers + 1);
			fd = $fopen(fname, "w");
			if (fd == 0) $fatal(1, "cannot open %0s (does the outputs folder exist?)", fname);
			$fdisplay(fd, "layer %0d: %0dx%0dx%0d input, %0d filters %0dx%0d, pad %0d, stride %0d -> %0dx%0dx%0d output",
			          layers + 1, L_H, L_W, L_C, L_F, L_KH, L_KW, L_P, L_S, L_OH, L_OW, L_F);
			for (c = 0; c < L_C; c = c + 1) begin
				$fdisplay(fd, "");
				$fdisplay(fd, "input channel %0d", c);
				for (y = 0; y < L_H; y = y + 1) begin
					for (x = 0; x < L_W; x = x + 1) $fwrite(fd, "%5d", img[c * SQ * SQ + y * SQ + x]);
					$fdisplay(fd, "");
				end
			end
			for (f = 0; f < L_F; f = f + 1) begin
				$fdisplay(fd, "");
				$fdisplay(fd, "filter %0d bias %0d, weights with k = c*(kh*kw) + kh*kw_size + kw", f, bias_v[f]);
				for (kk = 0; kk < L_M; kk = kk + 1) begin
					$fwrite(fd, "%5d", wt[widx(f, kk)]);
					if (kk % L_KW == L_KW - 1) $fdisplay(fd, "");
				end
			end
			for (f = 0; f < L_F; f = f + 1) begin
				$fdisplay(fd, "");
				$fdisplay(fd, "filter %0d output: hardware", f);
				for (y = 0; y < L_OH; y = y + 1) begin
					for (x = 0; x < L_OW; x = x + 1) $fwrite(fd, "%8d", hw[oidx(f, y, x)]);
					$fdisplay(fd, "");
				end
				$fdisplay(fd, "filter %0d output: reference", f);
				for (y = 0; y < L_OH; y = y + 1) begin
					for (x = 0; x < L_OW; x = x + 1) $fwrite(fd, "%8d", refo[oidx(f, y, x)]);
					$fdisplay(fd, "");
				end
			end
			$fclose(fd);
		end
	endtask

	task layer(input integer h, input integer w, input integer ch, input integer nf,
	           input integer kh_, input integer kw_, input integer p, input integer s);
		integer b, c, y, x, f, kh, kw, kk, g, j, i, sum, nbytes, word, top, ow, oh;
		reg [N*32-1:0] pk;
		begin
			L_H = h; L_W = w; L_C = ch; L_F = nf; L_KH = kh_; L_KW = kw_; L_P = p; L_S = s;
			L_RP  = ((w + 3) / 4) * 4;
			L_CH  = h * L_RP;
			L_OH  = (h + 2 * p - kh_) / s + 1;
			L_OW  = (w + 2 * p - kw_) / s + 1;
			L_M   = ch * kh_ * kw_;
			L_G   = (nf + 3) / 4;
			L_ORP = (L_OW + 3) / 4;
			L_OCH = L_OH * L_ORP;
			nbytes = 4 + ch * L_CH;

			for (c = 0; c < ch; c = c + 1)
				for (y = 0; y < h; y = y + 1)
					for (x = 0; x < w; x = x + 1)
						if (small_vals != 0) img[c * SQ * SQ + y * SQ + x] = {$random} % 10;
						else                 img[c * SQ * SQ + y * SQ + x] = $random % 128;
			for (f = 0; f < nf; f = f + 1)
				for (kk = 0; kk < L_M; kk = kk + 1)
					if (small_vals != 0) wt[widx(f, kk)] = ({$random} % 3) - 1;
					else                 wt[widx(f, kk)] = $random % 128;

			for (f = 0; f < nf; f = f + 1)
				if (small_vals != 0) bias_v[f] = ({$random} % 21) - 10;
				else                 bias_v[f] = $random % 30000;

			for (word = 0; word < (nbytes + 3) / 4; word = word + 1)
				ext_mem[IMG_EB + word] = $random;
			for (c = 0; c < ch; c = c + 1)
				for (y = 0; y < h; y = y + 1)
					for (x = 0; x < w; x = x + 1) begin
						b = 4 + c * L_CH + y * L_RP + x;
						ext_mem[IMG_EB + b / 4][(b % 4) * 8 +: 8] = 8'(img[c * SQ * SQ + y * SQ + x]);
					end

			for (g = 0; g < L_G; g = g + 1) begin
				for (j = 0; j < 4; j = j + 1)
					if (4 * g + j < nf) ext_mem[WGT_EB + g * (L_M + 4) + j] = bias_v[4 * g + j];
					else                ext_mem[WGT_EB + g * (L_M + 4) + j] = 32'h0;
				for (kk = 0; kk < L_M; kk = kk + 1)
					for (j = 0; j < 4; j = j + 1)
						if (4 * g + j < nf) ext_mem[WGT_EB + g * (L_M + 4) + 4 + kk][j * 8 +: 8] = 8'(wt[widx(4 * g + j, kk)]);
						else                ext_mem[WGT_EB + g * (L_M + 4) + 4 + kk][j * 8 +: 8] = 8'h00;
			end

			for (f = 0; f < nf; f = f + 1)
				for (oh = 0; oh < L_OH; oh = oh + 1)
					for (ow = 0; ow < L_OW; ow = ow + 1) begin
						sum = 0;
						for (c = 0; c < ch; c = c + 1)
							for (kh = 0; kh < kh_; kh = kh + 1)
								for (kw = 0; kw < kw_; kw = kw + 1) begin
									y = oh * s + kh - p;
									x = ow * s + kw - p;
									if (y >= 0 && y < h && x >= 0 && x < w)
										sum = sum + img[c * SQ * SQ + y * SQ + x] * wt[widx(f, c * kh_ * kw_ + kh * kw_ + kw)];
								end
						refo[oidx(f, oh, ow)] = sum + bias_v[f];
						got[oidx(f, oh, ow)]  = 0;
						hw[oidx(f, oh, ow)]   = 0;
					end

			for (g = 0; g < L_G; g = g + 1)
				for (oh = 0; oh < L_OH; oh = oh + 1)
					for (ow = 0; ow < L_OW; ow = ow + 4) begin
						top = (g == L_G - 1) ? ((nf - 1) % 4) : 3;
						for (j = 0; j <= top; j = j + 1) begin
							for (i = 0; i < 4; i = i + 1)
								pk[i*32 +: 32] = (ow + i < L_OW) ? refo[oidx(4 * g + j, oh, ow + i)] : bias_v[4 * g + j];
							e_data[q_tail] = pk;
							e_addr[q_tail] = ADDR'(1 + (4 * g + j) * L_OCH + oh * L_ORP + ow / 4);
							e_be[q_tail]   = {(ow + 3 < L_OW), (ow + 2 < L_OW), (ow + 1 < L_OW), 1'b1};
							e_last[q_tail] = (j == top);
							e_row[q_tail]  = 8'(oh);
							e_col[q_tail]  = 8'(ow);
							e_chan[q_tail] = 8'(4 * g + j);
							q_tail = q_tail + 1;
						end
					end

			img_ext_base = IMG_EB;
			wgt_ext_base = WGT_EB;
			in_h   = 8'(h);
			in_w   = 8'(w);
			in_c   = 8'(ch);
			n_filt = 8'(nf);
			k_h    = 3'(kh_);
			k_w    = 3'(kw_);
			pad    = 3'(p);
			stride = 3'(s);
			out_base = 11'd1;
		end
	endtask


	// ================================================================ vector unit programs and buffer-B check
	integer vu_mode, force_mode, obuf_checked, obuf_err, q_m, q_mn, q_s;
	integer np_v;
	reg [31:0] prg_v [0:63];
	integer s_pro_l, s_body_l, s_body_s, s_e0_s, s_e1_s, s_e2_s, s_e3_s;
	reg [15:0] exp_tab [0:255];
	localparam real SM_STEP = 0.1;     // real value of one int8 logit step, for the exp table

	function [31:0] venc(input [5:0] op, input [2:0] pr, input [3:0] d, input [3:0] a, input [3:0] b, input [10:0] x);
		venc = {op, pr, d, a, b, x};
	endfunction
	task vemit(input [31:0] w);
		begin
			prg_v[np_v] = w;
			np_v = np_v + 1;
		end
	endtask
	// one-layer network: the layer's table entry (header, sections, program, lookup table) at TBL_EB
	integer   sec_s [0:5];
	integer   sec_l [0:5];
	integer   sec_c [0:5];
	integer   n_lut_e;
	integer   wb_n;

	task write_entry(input integer n_prog, input integer wbn);
		integer i, a;
		begin
			a = TBL_EB;
			ext_mem[a + 0] = {n_filt, in_c, in_w, in_h};
			ext_mem[a + 1] = {13'd0, 1'b1, 1'b1, 1'b1, 2'd0, pool, stride, pad, k_w, k_h};   // last, write back, load image
			ext_mem[a + 2] = {5'd0, out_base, wgt_ext_base};
			ext_mem[a + 3] = {16'(WB_EB), img_ext_base};
			ext_mem[a + 4] = {8'd0, 12'(wbn), 1'b0, 11'd0};                                 // count [23:12], source 0 [10:0]
			ext_mem[a + 5] = {15'd0, 9'(n_lut_e), 1'b0, 7'(n_prog)};
			for (i = 0; i < 6; i = i + 1) ext_mem[a + 6 + i] = {10'd0, 9'(sec_c[i]), 7'(sec_l[i]), 6'(sec_s[i])};
			for (i = 0; i < n_prog; i = i + 1) ext_mem[a + 12 + i] = prg_v[i];
			for (i = 0; i < (n_lut_e + 1) / 2; i = i + 1) ext_mem[a + 12 + n_prog + i] = {exp_tab[2 * i + 1], exp_tab[2 * i]};
			for (i = 0; i < 1600; i = i + 1) ext_mem[WB_EB + i] = 32'hDEADBEEF;               // so missing writes show
			wb_n = wbn;
			tbl_base = TBL_EB;
		end
	endtask

	// requantization chosen from the layer's accumulator range, the way the Python flow will do it
	task choose_scale;
		integer f, y, x, mx, v;
		real sc;
		begin
			mx = 1;
			for (f = 0; f < L_F; f = f + 1)
				for (y = 0; y < L_OH; y = y + 1)
					for (x = 0; x < L_OW; x = x + 1) begin
						v = refo[oidx(f, y, x)];
						if (v < 0) v = -v;
						if (v > mx) mx = v;
					end
			sc  = 120.0 / mx;
			q_s = 0;
			while ($rtoi(sc * (2.0 ** (q_s + 1)) + 0.5) <= 32767 && q_s < 47) q_s = q_s + 1;
			q_m = $rtoi(sc * (2.0 ** q_s) + 0.5);
			if (q_m < 1) q_m = 1;
			q_mn = (vu_mode == 1 || vu_mode == 2) ? 0 : q_m;
		end
	endtask

	// mode 0: requantize; 1: requantize + ReLU; 2: requantize + ReLU + 2x2 max pooling; 3: like 0 with a 40-instruction body
	task load_vu;
		integer i;
		reg [18:0] orp2, och2;
		begin
			np_v = 0;
			vemit({6'h01, 3'd0, 4'd1, 19'(q_m)});                 // LI s1, M
			vemit({6'h01, 3'd0, 4'd2, 19'(q_mn)});                // LI s2, M_neg
			vemit(venc(6'h09, 3'd0, 4'd0, 4'd1, 4'd2, 11'(q_s))); // SETQ q0, s1, s2, S
			vemit({6'h01, 3'd0, 4'd3, 19'h7FF80});                // LI s3, -128
			vemit({6'h01, 3'd0, 4'd4, 19'd127});                  // LI s4, 127
			vemit(venc(6'h0A, 3'd0, 4'd0, 4'd3, 4'd4, 11'd0));    // SETC c0, s3, s4
			if (vu_mode == 2) begin
				orp2 = 19'(((L_OW / 2) + 3) / 4);
				och2 = 19'((L_OH / 2) * (((L_OW / 2) + 3) / 4));
				vemit({6'h01, 3'd0, 4'd1, 19'd1});        vemit(venc(6'h14, 3'd0, 4'd0, 4'd1, 4'd0, 11'd0));  // SETR 0, out_base
				vemit({6'h01, 3'd0, 4'd1, och2});    vemit(venc(6'h14, 3'd0, 4'd0, 4'd1, 4'd0, 11'd1));  // SETR 1, ch pitch
				vemit({6'h01, 3'd0, 4'd1, orp2});    vemit(venc(6'h14, 3'd0, 4'd0, 4'd1, 4'd0, 11'd2));  // SETR 2, row pitch
				vemit({6'h01, 3'd0, 4'd1, 19'd1});        vemit(venc(6'h14, 3'd0, 4'd0, 4'd1, 4'd0, 11'd3));  // SETR 3, L = 1
				vemit(venc(6'h0C, 3'd0, 4'd2, 4'd0, 4'd1, {6'd0, 2'd2, 3'd2}));    // SETP P2: row, low 1 bit == 0
				vemit(venc(6'h0C, 3'd0, 4'd3, 4'd0, 4'd1, {6'd1, 2'd2, 3'd2}));    // SETP P3: row, low 1 bit == 1
			end
			if (vu_mode == 4) begin
				vemit({6'h01, 3'd0, 4'd4, 19'd0});                     // LI s4, 0
				vemit(venc(6'h0A, 3'd0, 4'd2, 4'd3, 4'd4, 11'd0));     // SETC c2, s3, s4   (-128..0)
				vemit({6'h01, 3'd0, 4'd3, 19'd0});                     // LI s3, 0
				vemit({6'h01, 3'd0, 4'd4, 19'd127});                   // LI s4, 127
				vemit(venc(6'h0A, 3'd0, 4'd1, 4'd3, 4'd4, 11'd0));     // SETC c1, s3, s4   (0..127)
				vemit(venc(6'h11, 3'd0, 4'd6, 4'd0, 4'hF, 11'h780));   // VLI v6, -128      (imm15 = {b, x} = 0x7F80)
				vemit(venc(6'h11, 3'd0, 4'd5, 4'd0, 4'd0, 11'd0));     // VLI v5, 0         (running sum)
				vemit({6'h01, 3'd0, 4'd10, 19'd1});                    // LI s10, 1         (output base)
				vemit({6'h01, 3'd0, 4'd11, 19'd1});                    // LI s11, 1         (byte mask)
			end
			s_pro_l  = np_v;
			s_body_s = np_v;
			vemit(venc(6'h21, 3'd0, 4'd0, 4'd7, 4'd0, 11'd0));    // REQ v0, v7, q0
			if (vu_mode == 2) begin
				vemit(venc(6'h22, 3'd0, 4'd0, 4'd0, 4'd0, 11'd0));    // CLAMP v0, v0, c0
				vemit(venc(6'h30, 3'd0, 4'd1, 4'd0, 4'd0, 11'd0));    // MAXP v1, v0
				vemit(venc(6'h08, 3'd0, 4'd6, 4'd0, 4'd0, 11'd8));    // TAG s6, lmidx
				vemit(venc(6'h3C, 3'd2, 4'd0, 4'd1, 4'd6, 11'd0));    // [p2] STS v1, s6
				vemit(venc(6'h3B, 3'd3, 4'd2, 4'd6, 4'd0, 11'd0));    // [p3] LDS v2, s6
				vemit(venc(6'h1B, 3'd3, 4'd1, 4'd1, 4'd2, 11'd0));    // [p3] MAX v1, v1, v2
				vemit(venc(6'h34, 3'd0, 4'd1, 4'd1, 4'd0, 11'b00_01_00_01_00)); // PERM v1, v1, lanes 0,1 -> 2,3
				vemit(venc(6'h08, 3'd0, 4'd9, 4'd0, 4'd0, 11'd6));    // TAG s9, paddr
				vemit(venc(6'h08, 3'd0, 4'd5, 4'd0, 4'd0, 11'd7));    // TAG s5, pbe
				vemit(venc(6'h39, 3'd3, 4'd5, 4'd1, 4'd9, 11'd0));    // [p3] ST8A v1, s9, s5, c0
			end
			else if (vu_mode == 4) begin
				vemit(venc(6'h22, 3'd0, 4'd0, 4'd0, 4'd0, 11'd0));    // CLAMP v0, v0, c0      int8 logit
				vemit(venc(6'h08, 3'd0, 4'd1, 4'd0, 4'd0, 11'd4));    // TAG s1, chan          class number
				vemit(venc(6'h3C, 3'd0, 4'd0, 4'd0, 4'd1, 11'd0));    // STS v0, s1            logit -> local memory
				vemit(venc(6'h1B, 3'd0, 4'd6, 4'd6, 4'd0, 11'd0));    // MAX v6, v6, v0        running max
			end
			else begin
				vemit(venc(6'h38, 3'd0, 4'd0, 4'd0, 4'd0, 11'd0));    // ST8 v0, c0
				if (vu_mode == 3) for (i = 0; i < 38; i = i + 1) vemit(32'h0);   // NOPs: a deliberately slow consumer
			end
			s_body_l = np_v - s_body_s;
			if (vu_mode == 4) begin
				s_e0_s = np_v;                                        // epilogue 0, once per class
				vemit(venc(6'h08, 3'd0, 4'd1, 4'd0, 4'd0, 11'd9));    // TAG s1, iter
				vemit(venc(6'h3B, 3'd0, 4'd1, 4'd1, 4'd0, 11'd0));    // LDS v1, s1
				vemit(venc(6'h19, 3'd0, 4'd1, 4'd1, 4'd6, 11'd0));    // SUB v1, v1, v6        d = logit - max
				vemit(venc(6'h22, 3'd0, 4'd1, 4'd1, 4'd0, 11'd2));    // CLAMP v1, v1, c2      -128..0
				vemit(venc(6'h23, 3'd0, 4'd1, 4'd1, 4'd0, 11'd0));    // LUT v1, v1            exp(d), Q15
				vemit(venc(6'h3C, 3'd0, 4'd0, 4'd1, 4'd1, 11'd0));    // STS v1, s1
				vemit(venc(6'h18, 3'd0, 4'd5, 4'd5, 4'd1, 11'd0));    // ADD v5, v5, v1        running sum
				s_e1_s = np_v;                                        // epilogue 1, once
				vemit(venc(6'h33, 3'd0, 4'd2, 4'd5, 4'd0, 11'd0));    // RADD s2, v5
				vemit(venc(6'h0B, 3'd0, 4'd3, 4'd2, 4'd0, 11'd30));   // RCP s3, s2, 30
				vemit(venc(6'h12, 3'd0, 4'd4, 4'd3, 4'd0, 11'd0));    // BCAST v4, s3
				s_e2_s = np_v;                                        // epilogue 2, once per class
				vemit(venc(6'h08, 3'd0, 4'd1, 4'd0, 4'd0, 11'd9));    // TAG s1, iter
				vemit(venc(6'h3B, 3'd0, 4'd1, 4'd1, 4'd0, 11'd0));    // LDS v1, s1
				vemit(venc(6'h20, 3'd0, 4'd2, 4'd4, 4'd1, 11'd0));    // MUL v2, v4, v1        e x 2^30/sum
				vemit(venc(6'h1F, 3'd0, 4'd2, 4'd2, 4'd0, 11'd23));   // SHRR v2, v2, 23       probability x 128
				vemit(venc(6'h04, 3'd0, 4'd5, 4'd10, 4'd1, 11'd0));   // ADDS s5, s10, s1
				vemit(venc(6'h39, 3'd0, 4'd11, 4'd2, 4'd5, 11'd1));   // ST8A v2, s5, s11, c1
				s_e3_s = np_v;
			end
			for (i = 0; i < 6; i = i + 1) begin sec_s[i] = 0; sec_l[i] = 0; sec_c[i] = 0; end
			sec_s[0] = 0;        sec_l[0] = s_pro_l;  sec_c[0] = 1;
			sec_s[1] = s_body_s; sec_l[1] = s_body_l;
			n_lut_e = 0;
			if (vu_mode == 4) begin
				sec_s[2] = s_e0_s; sec_l[2] = s_e1_s - s_e0_s; sec_c[2] = L_F;
				sec_s[3] = s_e1_s; sec_l[3] = s_e2_s - s_e1_s; sec_c[3] = 1;
				sec_s[4] = s_e2_s; sec_l[4] = s_e3_s - s_e2_s; sec_c[4] = L_F;
				n_lut_e  = 256;
			end
		end
	endtask

	function integer q8(input integer f, input integer y, input integer x);
		reg signed [63:0] yv;
		reg signed [31:0] a;
		begin
			a  = refo[oidx(f, y, x)];
			yv = (a < 0) ? $signed(a) * q_mn : $signed(a) * q_m;
			if (q_s != 0) yv = (yv >>> q_s) + ((yv >>> (q_s - 1)) & 64'sd1);
			if (yv > 127) yv = 127;
			if (yv < -128) yv = -128;
			q8 = yv[31:0];
		end
	endfunction

	// the result as written back by the chip into external memory (word a of the output buffer -> WB_EB + a)
	task ob_read(input [ADDR-1:0] a, output [31:0] d);
		d = ext_mem[WB_EB + {21'd0, a}];
	endtask

	// softmax over the classes (1x1xC output): bit-exact reference of the program, plus float softmax
	task check_softmax(input integer loud);
		integer i, m, e0;
		reg signed [31:0] lg [0:63];
		reg signed [31:0] ex [0:63];
		reg signed [31:0] r, sum, rr, q, d;
		reg [63:0] q64;
		reg [31:0] wd;
		reg signed [7:0] hv;
		real fsum, fp, perr, maxerr;
		begin
			e0 = obuf_err;
			m = -128;
			for (i = 0; i < L_F; i = i + 1) begin
				lg[i] = q8(i, 0, 0);
				if (lg[i] > m) m = lg[i];
			end
			sum = 0;
			for (i = 0; i < L_F; i = i + 1) begin
				d = lg[i] - m;
				if (d < -128) d = -128;
				ex[i] = {16'd0, exp_tab[d[7:0]]};
				sum = sum + ex[i];
			end
			q64 = (64'd1 << 30) / {32'd0, sum};
			if (q64[63:32] != 32'd0) $fatal(1, "softmax reference: reciprocal wider than 32 bits");
			rr  = q64[31:0];
			fsum = 0.0;
			for (i = 0; i < L_F; i = i + 1) fsum = fsum + $exp(lg[i] * SM_STEP);
			maxerr = 0.0;
			if (loud != 0) $write("      class:            ");
			if (loud != 0) for (i = 0; i < L_F; i = i + 1) $write(" %5d", i);
			if (loud != 0) $display("");
			if (loud != 0) $write("      logit (int8):     ");
			if (loud != 0) for (i = 0; i < L_F; i = i + 1) $write(" %5d", lg[i]);
			if (loud != 0) $display("");
			if (loud != 0) $write("      softmax (float):  ");
			if (loud != 0) for (i = 0; i < L_F; i = i + 1) $write(" %5.3f", $exp(lg[i] * SM_STEP) / fsum);
			if (loud != 0) $display("");
			if (loud != 0) $write("      buffer B (q/128): ");
			for (i = 0; i < L_F; i = i + 1) begin
				q64 = {32'd0, rr} * {32'd0, ex[i]};
				if (q64[63:32] != 32'd0) $fatal(1, "softmax reference: product wider than 32 bits");
				r   = q64[31:0];
				q   = (r >>> 23) + ((r >>> 22) & 1);
				if (q > 127) q = 127;
				ob_read(ADDR'(1 + i), wd);
				if (wd[31:8] === 24'hx) $display("note: upper bytes of class word %0d unknown", i);
				hv = wd[7:0];
				obuf_checked = obuf_checked + 1;
				if ({{24{hv[7]}}, hv} != q) begin
					obuf_err = obuf_err + 1;
					if (obuf_err - e0 <= 5) $display("FAIL softmax class %0d = %0d, expected %0d", i, hv, q);
				end
				if (loud != 0) $write(" %5.3f", hv / 128.0);
				fp  = $exp(lg[i] * SM_STEP) / fsum;
				perr = hv / 128.0 - fp;
				if (perr < 0.0) perr = -perr;
				if (perr > maxerr) maxerr = perr;
			end
			if (loud != 0) $display("");
			$display("      softmax of %0d classes in buffer B: largest difference from float softmax %0.4f, %0d wrong",
			         L_F, maxerr, obuf_err - e0);
		end
	endtask

	// every stored int8 value in buffer B against the reference (requantized, and pooled in mode 2)
	task check_obuf(input integer loud);
		begin
			if (vu_mode == 4) check_softmax(loud);
			else check_maps(loud);
		end
	endtask

	task check_maps(input integer loud);
		integer f, y, x, oh_s, ow_s, rp_s, ch_s, e, k, mx, e0, hvi;
		reg [ADDR-1:0] wa;
		reg [31:0] wd;
		reg signed [7:0] hv;
		begin
			e0 = obuf_err;
			if (vu_mode == 2) begin
				oh_s = L_OH / 2; ow_s = L_OW / 2; rp_s = (ow_s + 3) / 4; ch_s = oh_s * rp_s;
			end
			else begin
				oh_s = L_OH; ow_s = L_OW; rp_s = L_ORP; ch_s = L_OCH;
			end
			for (f = 0; f < L_F; f = f + 1)
				for (y = 0; y < oh_s; y = y + 1) begin
					if (loud != 0 && f == 0 && y < 4) $write("      ");
					for (x = 0; x < ow_s; x = x + 1) begin
						wa = ADDR'(1 + f * ch_s + y * rp_s + x / 4);
						ob_read(wa, wd);
						hv = wd[(x % 4) * 8 +: 8];
						if (vu_mode == 2) begin
							mx = -128;
							for (k = 0; k < 4; k = k + 1) begin
								e = q8(f, 2 * y + k / 2, 2 * x + k % 2);
								if (e > mx) mx = e;
							end
							e = mx;
						end
						else e = q8(f, y, x);
						obuf_checked = obuf_checked + 1;
						hvi = {{24{hv[7]}}, hv};
						if (hvi != e) begin
							obuf_err = obuf_err + 1;
							if (obuf_err - e0 <= 5) $display("FAIL buffer B: filter %0d (%0d,%0d) = %0d, expected %0d", f, y, x, hv, e);
						end
						if (loud != 0 && f == 0 && y < 4 && x < 10) $write(" %4d", hv);
					end
					if (loud != 0 && f == 0 && y < 4) $display("");
				end
		end
	endtask

	task pulse_start;
		begin
			@(negedge clk);
			start = 1'b1;
			@(negedge clk);
			start = 1'b0;
		end
	endtask

	task run(input integer h, input integer w, input integer ch, input integer nf,
	         input integer kh_, input integer kw_, input integer p, input integer s, input integer loud);
		integer t0, p0, e0, f, y, x, missing, tiles, ideal, wbw, wb0;
		begin
			layer(h, w, ch, nf, kh_, kw_, p, s);
			if (force_mode >= 0)                vu_mode = force_mode;
			else if (1 + nf * L_OCH > 1536)     vu_mode = 2;            // the unpooled output would not fit buffer B
			else                                vu_mode = layers % 2;   // requantize, or requantize + ReLU
			choose_scale;
			load_vu;
			pool = (vu_mode == 2) ? 2'd1 : 2'd0;
			if (vu_mode == 4)      wbw = 1 + L_F;
			else if (vu_mode == 2) wbw = 1 + L_F * (L_OH / 2) * (((L_OW / 2) + 3) / 4);
			else                   wbw = 1 + L_F * L_OCH;
			write_entry(np_v, wbw);
			wb0 = wb_count;
			p0 = pkts;
			e0 = errors + mon_err;
			if (loud != 0) begin
				$display("");
				$write("  %0dx%0dx%0d input, %0d filters %0dx%0d, pad %0d, stride %0d -> %0dx%0dx%0d output (M = %0d, %0d group(s)",
				       h, w, ch, nf, kh_, kw_, p, s, L_OH, L_OW, nf, L_M, L_G);
				if (L_M > 512) $display(", single weight buffer)");
				else           $display(")");
			end
			t0 = cyc;
			pulse_start;
			while (!done) begin
				@(posedge clk);
				if (pkt_take) decode_pkt;
				if (cyc - t0 > 600000) $fatal(1, "layer never finished");
			end
			if (err_valid || err != 7'd0) begin
				errors = errors + 1;
				$display("FAIL: valid layer was rejected, err = %b", err);
			end
			repeat (2) @(negedge clk);
			if (busy) begin
				errors = errors + 1;
				$display("FAIL: busy still high after done");
			end
			if (loud != 0)
				$display("    vector unit: %0s, M = %0d, S = %0d; int8 result written back (filter 0, top-left corner):",
				         (vu_mode == 0) ? "requantize" : ((vu_mode == 1) ? "requantize + ReLU" :
				         ((vu_mode == 2) ? "requantize + ReLU + 2x2 max pooling" :
				         ((vu_mode == 4) ? "requantize, then softmax over the classes" : "requantize, 40-instruction body"))), q_m, q_s);
			if (wb_count - wb0 != wbw || wb_n != wbw) begin
				errors = errors + 1;
				$display("FAIL: %0d words written back, expected %0d", wb_count - wb0, wbw);
			end
			check_obuf(loud);

			missing = 0;
			for (f = 0; f < nf; f = f + 1)
				for (y = 0; y < L_OH; y = y + 1)
					for (x = 0; x < L_OW; x = x + 1)
						if (got[oidx(f, y, x)] != 1) missing = missing + 1;
			if (missing != 0) begin
				errors = errors + 1;
				$display("FAIL: %0d outputs were never produced or produced more than once", missing);
			end

			tiles = L_G * L_OH * ((L_OW + 3) / 4);
			ideal = tiles * (L_M + 1);
			total_cycles = total_cycles + (cyc - t0);
			total_ideal  = total_ideal + ideal;
			if (loud != 0) begin
				$display("    %0d cycles (%0d tiles x (M+1) = %0d ideal compute), %0d packets, %0d outputs: %0d errors, %0d missing/duplicated",
				         cyc - t0, tiles, ideal, pkts - p0, nf * L_OH * L_OW, errors + mon_err - e0, missing);
				if (small_vals != 0) begin
					print_small;
					explain_one(0, 0, 0);
					if (L_OH > 2 && L_OW > 2) explain_one(L_F - 1, 2, 2);
				end
				else if (L_OW >= 4) print_outputs(0, 2, 6);
				else begin
					$write("    hardware:");
					for (f = 0; f < nf; f = f + 1) $write(" %0d", hw[oidx(f, 0, 0)]);
					$display("");
					$write("    reference:");
					for (f = 0; f < nf; f = f + 1) $write(" %0d", refo[oidx(f, 0, 0)]);
					$display("");
				end
				dump_layer;
				$display("    full input, weights and outputs in %0s", fname);
			end
			else
				$display("    %0dx%0dx%0d, %0d filters %0dx%0d, pad %0d, stride %0d: %0d outputs, %0d errors%0s",
				         h, w, ch, nf, kh_, kw_, p, s, nf * L_OH * L_OW, errors + mon_err - e0 + missing,
				         (vu_mode == 2) ? "  (pooled 2x2)" : ((vu_mode == 1) ? "  (ReLU)" : ""));
			layers = layers + 1;
		end
	endtask

	task reject(input [7:0] h, input [7:0] w, input [7:0] ch, input [7:0] nf,
	            input [2:0] kh_, input [2:0] kw_, input [2:0] p, input [2:0] s,
	            input [10:0] obase, input integer bit_n, input [8*40:1] why);
		integer t0, p0;
		begin
			in_h = h; in_w = w; in_c = ch; n_filt = nf;
			k_h = kh_; k_w = kw_; pad = p; stride = s; out_base = obase; pool = 2'd0;
			img_ext_base = IMG_EB; wgt_ext_base = WGT_EB;
			for (t0 = 0; t0 < 6; t0 = t0 + 1) begin sec_s[t0] = 0; sec_l[t0] = 0; sec_c[t0] = 0; end
			n_lut_e = 0;
			write_entry(0, 0);
			p0 = pkts;
			t0 = cyc;
			pulse_start;
			while (!done) begin
				@(negedge clk);
				if (cyc - t0 > 2000) $fatal(1, "rejected layer never reported");
			end
			if (err[bit_n] == 1'b1 && pkts == p0)
				$display("    %0s: rejected with err = %b (bit %0d)   ok", why, err, bit_n);
			else begin
				errors = errors + 1;
				$display("FAIL: %0s: err = %b, expected bit %0d, %0d packets", why, err, bit_n, pkts - p0);
			end
			repeat (2) @(negedge clk);
		end
	endtask

	integer n, rh, rw, rc, rf, rkh, rkw, rp, rs;

	initial begin
		if ($test$plusargs("vcd")) begin
			$dumpfile("waveforms/accel_top.vcd");
			$dumpvars(0, tb_accel_top);
		end

		errors = 0; layers = 0; cyc = 0; small_vals = 0; fd = 0; total_cycles = 0; total_ideal = 0;
		pool = 2'd0; tbl_base = TBL_EB; wr_rdy_r = 1'b1; n_lut_e = 0; wb_n = 0;
		for (n = 0; n < 6; n = n + 1) begin sec_s[n] = 0; sec_l[n] = 0; sec_c[n] = 0; end
		for (n = 0; n < 256; n = n + 1)
			exp_tab[n] = 16'($rtoi(32767.0 * $exp(((n < 128) ? 0 : n - 256) * SM_STEP) + 0.5));
		s_e0_s = 0; s_e1_s = 0; s_e2_s = 0; s_e3_s = 0;
		vu_mode = 0; force_mode = -1; obuf_checked = 0; obuf_err = 0; q_m = 1; q_mn = 1; q_s = 0; np_v = 0;
		s_pro_l = 0; s_body_l = 0; s_body_s = 0;
		q_head = 0; q_tail = 0; mon_err = 0; pkts = 0;
		sq_head = 0; sq_tail = 0; sq_count = 0; rdy_r = 1'b1; mem_on = 1'b0;
		source(1, 1, 100);
		start = 1'b0;
		img_ext_base = 0; wgt_ext_base = 0; in_h = 0; in_w = 0; in_c = 0; n_filt = 0;
		k_h = 0; k_w = 0; pad = 0; stride = 0; out_base = 0;
		for (n = 0; n < 32; n = n + 1) begin
			q_addr[n] = {EAW{1'b0}};
			q_due[n]  = 0;
		end

`ifdef USE_SRAM_MACRO
		$display("accel_top: full convolution layers, memories: sky130 macros");
`else
		$display("accel_top: full convolution layers, memories: behavioral");
`endif

		rst_n = 1'b0;
		repeat (3) @(negedge clk);
		rst_n = 1'b1;
		repeat (4) @(negedge clk);
		mem_on = 1'b1;

		$display("");
		$display("0) Small numbers you can check by hand (inputs 0-9, weights -1..1):");
		small_vals = 1;
		run(5, 5, 1, 2, 3, 3, 1, 1, 1);
		run(7, 7, 1, 1, 3, 3, 1, 2, 1);
		small_vals = 0;

		$display("");
		$display("1) Layer shapes from before, ideal memory:");
		run(28, 28, 1, 8, 3, 3, 1, 1, 1);
		run(14, 14, 8, 16, 3, 3, 1, 1, 1);
		run(10, 10, 3, 6, 3, 3, 0, 1, 1);
		run(7, 7, 16, 10, 7, 7, 0, 1, 1);
		run(12, 12, 2, 4, 5, 5, 2, 1, 1);

		$display("");
		$display("2) Stride 2, 3 and 4, uneven kernels, and the K = 1 and K = 2 cases (also with stride):");
		run(14, 14, 4, 8, 3, 3, 1, 2, 1);
		run(15, 15, 3, 6, 3, 3, 0, 2, 1);
		run(16, 16, 2, 4, 3, 3, 1, 3, 1);
		run(17, 17, 1, 4, 5, 5, 2, 4, 1);
		run(12, 10, 2, 5, 3, 5, 1, 1, 1);
		run(9, 11, 3, 3, 1, 3, 0, 2, 1);
		run(8, 8, 1, 4, 1, 1, 0, 1, 1);
		run(8, 8, 2, 5, 1, 1, 0, 1, 1);
		run(9, 9, 1, 4, 1, 1, 0, 2, 1);
		run(9, 11, 2, 4, 1, 1, 0, 2, 1);
		run(13, 13, 1, 4, 1, 1, 0, 3, 1);
		run(4, 4, 1, 16, 1, 1, 0, 1, 1);
		run(4, 5, 2, 16, 1, 1, 0, 1, 1);

		$display("");
		$display("3) 25 random layer shapes:");
		for (n = 0; n < 25; n = n + 1) begin
			rkh = 1 + {$random} % 5;
			rkw = 1 + {$random} % 5;
			rp  = {$random} % 4;
			if (rp >= rkh) rp = rkh - 1;
			if (rp >= rkw) rp = rkw - 1;
			rs  = 1 + {$random} % 4;
			rh  = rkh + {$random} % 18;
			rw  = rkw + {$random} % 18;
			rc  = 1 + {$random} % 6;
			rf  = 1 + {$random} % 9;
			while (4 + rc * rh * ((rw + 3) / 4) * 4 > 6140) rc = rc - 1;
			run(rh, rw, rc, rf, rkh, rkw, rp, rs, 0);
		end

		$display("");
		$display("4) Slow external memory (latency 1-6, 60%% accepted), then a memory-bound layer (40%%):");
		source(1, 6, 60);
		run(14, 14, 8, 16, 3, 3, 1, 1, 1);
		run(14, 14, 4, 8, 3, 3, 1, 2, 1);
		source(1, 6, 40);
		run(3, 6, 16, 12, 3, 3, 0, 1, 1);
		source(1, 1, 100);

		$display("");
		$display("5) Backpressure from the vector unit itself: 2x2 max pooling (~13 cycles per packet),");
		$display("   then a 40-instruction body; the credits must hold the array back without losing anything:");
		force_mode = 2;
		run(28, 28, 1, 8, 3, 3, 1, 1, 1);
		run(14, 14, 4, 8, 3, 3, 1, 1, 0);
		force_mode = 3;
		run(8, 8, 1, 4, 1, 1, 0, 1, 1);
		run(14, 14, 4, 8, 3, 3, 1, 2, 0);
		for (n = 0; n < 4; n = n + 1) begin
			force_mode = (n % 2 == 0) ? 2 : 3;
			run(4 + {$random} % 12, 4 + {$random} % 12, 1 + {$random} % 4, 1 + {$random} % 9, 3, 3, 1, 1 + {$random} % 2, 0);
		end
		force_mode = -1;

		$display("");
		$display("5b) Classifier layers: the array computes the logits (an FC layer), the vector unit requantizes them");
		$display("    and runs softmax over the classes; the probabilities (x128) are read back from buffer B:");
		force_mode = 4;
		run(7, 7, 16, 10, 7, 7, 0, 1, 1);
		run(1, 1, 64, 10, 1, 1, 0, 1, 1);
		run(4, 4, 8, 32, 4, 4, 0, 1, 1);
		run(3, 3, 32, 2, 3, 3, 0, 1, 0);
		run(2, 2, 16, 64, 2, 2, 0, 1, 0);
		for (n = 0; n < 4; n = n + 1) begin
			rh = 1 + {$random} % 5;                          // FC layer: kernel = whole input -> 1x1xC logits
			rw = 1 + {$random} % 5;
			rc = 1 + {$random} % 32;
			while (rc * rh * rw > 1020) rc = rc - 1;
			rf = 1 + {$random} % 64;
			run(rh, rw, rc, rf, rh, rw, 0, 1, 0);
		end
		force_mode = -1;

		$display("");
		$display("6) Invalid configurations must be rejected without running:");
		reject(8, 8, 1, 4, 0, 3, 0, 1, 1, 0, "zero kernel height              ");
		reject(8, 8, 1, 4, 3, 3, 0, 5, 1, 1, "stride 5                        ");
		reject(8, 8, 1, 4, 3, 3, 3, 1, 1, 2, "padding as large as the kernel  ");
		reject(2, 8, 1, 4, 5, 3, 0, 1, 1, 3, "kernel taller than the input    ");
		reject(8, 8, 128, 4, 3, 3, 1, 1, 1, 4, "weights larger than 4 KB      ");
		reject(32, 32, 8, 4, 3, 3, 1, 1, 1, 5, "image larger than 6 KB        ");
		reject(28, 28, 1, 8, 3, 3, 1, 1, 1000, 6, "outputs do not fit buffer B   ");
		$display("    and a valid layer still runs right after:");
		run(10, 10, 3, 6, 3, 3, 0, 1, 0);

		repeat (4) @(negedge clk);
		$display("");
		$display("7) Totals: %0d layers, %0d packets, %0d cycles against %0d ideal compute cycles, %0d expected packets missing",
		         layers, pkts, total_cycles, total_ideal, q_tail - q_head);
		if (q_head != q_tail) begin
			errors = errors + 1;
			$display("FAIL: %0d expected packets never arrived", q_tail - q_head);
		end
		errors = errors + mon_err + obuf_err;
		$display("   %0d int8 values written back to external memory and checked, %0d wrong", obuf_checked, obuf_err);
		$display("");

		if (errors != 0) $fatal(1, "FAIL: %0d error(s)", errors);
		$display("PASS: %0d layers, every accumulator and every int8 result written back to external memory matches the reference; all invalid configurations rejected", layers);
		$finish;
	end
endmodule
