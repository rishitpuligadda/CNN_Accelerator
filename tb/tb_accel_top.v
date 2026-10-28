`timescale 1ns/1ps

module tb_accel_top;
	localparam EAW    = 16;
	localparam N      = 4;
	localparam ADDR   = 11;
	localparam EWORDS = 1 << EAW;
	localparam IMG_EB = 0;
	localparam WGT_EB = 16384;
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
	wire                    pkt_valid, pkt_last;
	wire [N*32-1:0]         pkt_data;
	wire [ADDR-1:0]         pkt_addr;
	wire [N-1:0]            pkt_be;

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
		.img_ext_base(img_ext_base), .wgt_ext_base(wgt_ext_base),
		.in_h(in_h), .in_w(in_w), .in_c(in_c), .n_filt(n_filt),
		.k_h(k_h), .k_w(k_w), .pad(pad), .stride(stride), .out_base(out_base),
		.rd_req_valid(rd_req_valid), .rd_req_ready(rd_req_ready), .rd_req_addr(rd_req_addr),
		.rd_resp_valid(rd_resp_valid), .rd_resp_data(rd_resp_data), .rd_resp_ready(rd_resp_ready),
		.pkt_valid(pkt_valid), .pkt_data(pkt_data), .pkt_addr(pkt_addr), .pkt_be(pkt_be), .pkt_last(pkt_last)
	);

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
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

	always @(negedge clk) begin
		if (pkt_valid) begin
			pkts <= pkts + 1;
			if (q_head == q_tail) begin
				mon_err <= mon_err + 1;
				$display("FAIL t=%0t: unexpected packet addr=%0d", $time, pkt_addr);
			end
			else if (pkt_data !== e_data[q_head] || pkt_addr !== e_addr[q_head] ||
			         pkt_be !== e_be[q_head] || pkt_last !== e_last[q_head]) begin
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
				else                 bias_v[f] = $random % 1048576;

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
		integer t0, p0, e0, f, y, x, missing, tiles, ideal;
		begin
			layer(h, w, ch, nf, kh_, kw_, p, s);
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
				@(negedge clk);
				if (pkt_valid) decode_pkt;
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
				$display("    %0dx%0dx%0d, %0d filters %0dx%0d, pad %0d, stride %0d: %0d outputs, %0d errors",
				         h, w, ch, nf, kh_, kw_, p, s, nf * L_OH * L_OW, errors + mon_err - e0 + missing);
			layers = layers + 1;
		end
	endtask

	task reject(input [7:0] h, input [7:0] w, input [7:0] ch, input [7:0] nf,
	            input [2:0] kh_, input [2:0] kw_, input [2:0] p, input [2:0] s,
	            input [10:0] obase, input integer bit_n, input [8*40:1] why);
		integer t0, p0;
		begin
			in_h = h; in_w = w; in_c = ch; n_filt = nf;
			k_h = kh_; k_w = kw_; pad = p; stride = s; out_base = obase;
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
		$dumpfile("waveforms/accel_top.vcd");
		$dumpvars(0, tb_accel_top);

		errors = 0; layers = 0; cyc = 0; small_vals = 0; fd = 0; total_cycles = 0; total_ideal = 0;
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
		$display("5) Invalid configurations must be rejected without running:");
		reject(8, 8, 1, 4, 0, 3, 0, 1, 1, 0, "zero kernel height              ");
		reject(8, 8, 1, 4, 3, 3, 0, 5, 1, 1, "stride 5                        ");
		reject(8, 8, 1, 4, 3, 3, 3, 1, 1, 2, "padding as large as the kernel  ");
		reject(2, 8, 1, 4, 5, 3, 0, 1, 1, 3, "kernel taller than the input    ");
		reject(8, 8, 128, 4, 3, 3, 1, 1, 1, 4, "weights larger than 4 KB      ");
		reject(32, 32, 8, 4, 3, 3, 1, 1, 1, 5, "image larger than 6 KB        ");
		reject(28, 28, 1, 8, 3, 3, 1, 1, 1000, 6, "outputs past the address space");
		$display("    and a valid layer still runs right after:");
		run(10, 10, 3, 6, 3, 3, 0, 1, 0);

		repeat (4) @(negedge clk);
		$display("");
		$display("6) Totals: %0d layers, %0d packets, %0d cycles against %0d ideal compute cycles, %0d expected packets missing",
		         layers, pkts, total_cycles, total_ideal, q_tail - q_head);
		if (q_head != q_tail) begin
			errors = errors + 1;
			$display("FAIL: %0d expected packets never arrived", q_tail - q_head);
		end
		errors = errors + mon_err;
		$display("");

		if (errors != 0) $fatal(1, "FAIL: %0d error(s)", errors);
		$display("PASS: %0d convolution layers, every output matches the reference; all invalid configurations rejected", layers);
		$finish;
	end
endmodule
