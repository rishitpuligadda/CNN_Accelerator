`timescale 1ns/1ps

module tb_accel_top;
	localparam EAW    = 16;
	localparam N      = 4;
	localparam ADDR   = 11;
	localparam DIMW   = 8;
	localparam EWORDS = 1 << EAW;
	localparam IMG_EB = 0;
	localparam WGT_EB = 16384;
	localparam QMAX   = 65536;
	localparam SQ     = 32;

	reg                     clk, rst_n, start;
	wire                    busy, done;
	reg  [EAW-1:0]          img_ext_base, wgt_ext_base;
	reg  [ADDR:0]           img_words;
	reg  [10:0]             m;
	reg  [7:0]              n_groups, c_max;
	reg  [3:0]              last_cols;
	reg  [DIMW-1:0]         in_h, in_w, out_h, out_w;
	reg  [2:0]              kh_max, kw_max, pad;
	reg  signed [ADDR+2:0]  step_kh, step_c, tile_addr0;
	reg  [ADDR+1:0]         act_rp;
	reg  [ADDR-1:0]         out_base, out_rp_w, out_ch_pitch;

	wire                    rd_req_valid, rd_req_ready, rd_resp_valid, rd_resp_ready;
	wire [EAW-1:0]          rd_req_addr;
	wire [31:0]             rd_resp_data;
	wire                    pkt_valid, pkt_last;
	wire [N*32-1:0]         pkt_data;
	wire [ADDR-1:0]         pkt_addr;
	wire [N-1:0]            pkt_be;

	reg  [31:0]             ext_mem [0:EWORDS-1];
	integer                 img  [0:16*SQ*SQ-1];
	integer                 wt   [0:16*16*49-1];
	integer                 refo [0:16*SQ*SQ-1];
	integer                 got  [0:16*SQ*SQ-1];
	integer                 hw   [0:16*SQ*SQ-1];

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

	integer L_F, L_RP, L_CH, L_OH, L_OW, L_M, L_G, L_ORP, L_OCH;
	integer errors, layers, small_vals, fd;
	reg [8*32:1] fname;

	accel_top #(.EAW(EAW), .N(N), .ADDR(ADDR), .DIMW(DIMW)) dut (
		.clk(clk), .rst_n(rst_n), .start(start), .busy(busy), .done(done),
		.img_ext_base(img_ext_base), .img_words(img_words), .wgt_ext_base(wgt_ext_base),
		.m(m), .n_groups(n_groups), .last_cols(last_cols),
		.in_h(in_h), .in_w(in_w), .kh_max(kh_max), .kw_max(kw_max), .c_max(c_max), .pad(pad),
		.step_kh(step_kh), .step_c(step_c), .tile_addr0(tile_addr0), .act_rp(act_rp),
		.out_h(out_h), .out_w(out_w), .out_base(out_base), .out_rp_w(out_rp_w), .out_ch_pitch(out_ch_pitch),
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


	task print_input(input integer h, input integer w, input integer ch, input integer maxc);
		integer c, y, x;
		begin
			for (c = 0; c < ch && c < maxc; c = c + 1) begin
				$display("    input channel %0d:", c);
				for (y = 0; y < h; y = y + 1) begin
					$write("      ");
					for (x = 0; x < w; x = x + 1) $write("%5d", img[c * SQ * SQ + y * SQ + x]);
					$display("");
				end
			end
		end
	endtask

	task print_weights(input integer f, input integer ch, input integer k);
		integer c, kh, kw;
		begin
			for (c = 0; c < ch; c = c + 1) begin
				$display("    filter %0d, channel %0d weights:", f, c);
				for (kh = 0; kh < k; kh = kh + 1) begin
					$write("      ");
					for (kw = 0; kw < k; kw = kw + 1) $write("%5d", wt[f * 16 * 49 + c * k * k + kh * k + kw]);
					$display("");
				end
			end
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

	task explain_one(input integer f, input integer oh, input integer ow, input integer k, input integer p, input integer h, input integer w);
		integer kh, kw, y, x, v, sum;
		begin
			$display("    by hand: filter %0d output at (%0d,%0d) = sum of patch x weights", f, oh, ow);
			sum = 0;
			for (kh = 0; kh < k; kh = kh + 1) begin
				$write("      ");
				for (kw = 0; kw < k; kw = kw + 1) begin
					y = oh + kh - p;
					x = ow + kw - p;
					v = (y >= 0 && y < h && x >= 0 && x < w) ? img[y * SQ + x] : 0;
					sum = sum + v * wt[f * 16 * 49 + kh * k + kw];
					$write("  %2d x %2d", v, wt[f * 16 * 49 + kh * k + kw]);
				end
				$display("");
			end
			$display("      total = %0d, hardware gave %0d", sum, hw[oidx(f, oh, ow)]);
		end
	endtask

	task dump_layer(input integer h, input integer w, input integer ch, input integer nf, input integer k, input integer p);
		integer c, y, x, f, kh, kw;
		begin
			$sformat(fname, "layer%0d_outputs.txt", layers + 1);
			fd = $fopen(fname, "w");
			$fdisplay(fd, "layer %0d: %0dx%0dx%0d input, %0d filters %0dx%0d, pad %0d -> %0dx%0dx%0d output",
			          layers + 1, h, w, ch, nf, k, k, p, L_OH, L_OW, nf);
			for (c = 0; c < ch; c = c + 1) begin
				$fdisplay(fd, "");
				$fdisplay(fd, "input channel %0d", c);
				for (y = 0; y < h; y = y + 1) begin
					for (x = 0; x < w; x = x + 1) $fwrite(fd, "%5d", img[c * SQ * SQ + y * SQ + x]);
					$fdisplay(fd, "");
				end
			end
			for (f = 0; f < nf; f = f + 1)
				for (c = 0; c < ch; c = c + 1) begin
					$fdisplay(fd, "");
					$fdisplay(fd, "filter %0d channel %0d weights", f, c);
					for (kh = 0; kh < k; kh = kh + 1) begin
						for (kw = 0; kw < k; kw = kw + 1) $fwrite(fd, "%5d", wt[f * 16 * 49 + c * k * k + kh * k + kw]);
						$fdisplay(fd, "");
					end
				end
			for (f = 0; f < nf; f = f + 1) begin
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

	task source(input integer lmin, input integer lmax, input integer rpct);
		begin
			lat_min = lmin;
			lat_max = lmax;
			rdy_pct = rpct;
		end
	endtask

	task layer(input integer h, input integer w, input integer ch, input integer nf, input integer k, input integer p);
		integer b, c, y, x, f, kh, kw, kk, g, j, i, sum, nbytes, word, top, ow, oh;
		reg [3:0] cols;
		reg [N*32-1:0] pk;
		begin
			L_F = nf;
			L_RP  = ((w + 3) / 4) * 4;
			L_CH  = h * L_RP;
			L_OH  = h + 2 * p - k + 1;
			L_OW  = w + 2 * p - k + 1;
			L_M   = ch * k * k;
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
					if (small_vals != 0) wt[f * 16 * 49 + kk] = ({$random} % 3) - 1;
					else                 wt[f * 16 * 49 + kk] = $random % 128;

			for (word = 0; word < (nbytes + 3) / 4; word = word + 1)
				ext_mem[IMG_EB + word] = $random;
			for (c = 0; c < ch; c = c + 1)
				for (y = 0; y < h; y = y + 1)
					for (x = 0; x < w; x = x + 1) begin
						b = 4 + c * L_CH + y * L_RP + x;
						ext_mem[IMG_EB + b / 4][(b % 4) * 8 +: 8] = 8'(img[c * SQ * SQ + y * SQ + x]);
					end

			for (g = 0; g < L_G; g = g + 1)
				for (kk = 0; kk < L_M; kk = kk + 1)
					for (j = 0; j < 4; j = j + 1)
						if (4 * g + j < nf) ext_mem[WGT_EB + g * L_M + kk][j * 8 +: 8] = 8'(wt[(4 * g + j) * 16 * 49 + kk]);
						else                ext_mem[WGT_EB + g * L_M + kk][j * 8 +: 8] = 8'h00;

			for (f = 0; f < nf; f = f + 1)
				for (oh = 0; oh < L_OH; oh = oh + 1)
					for (ow = 0; ow < L_OW; ow = ow + 1) begin
						sum = 0;
						for (c = 0; c < ch; c = c + 1)
							for (kh = 0; kh < k; kh = kh + 1)
								for (kw = 0; kw < k; kw = kw + 1) begin
									y = oh + kh - p;
									x = ow + kw - p;
									if (y >= 0 && y < h && x >= 0 && x < w)
										sum = sum + img[c * SQ * SQ + y * SQ + x] * wt[f * 16 * 49 + c * k * k + kh * k + kw];
								end
						refo[oidx(f, oh, ow)] = sum;
						got[oidx(f, oh, ow)]  = 0;
					end

			cols = (nf % 4 == 0) ? 4'hF : 4'((1 << (nf % 4)) - 1);
			for (g = 0; g < L_G; g = g + 1)
				for (oh = 0; oh < L_OH; oh = oh + 1)
					for (ow = 0; ow < L_OW; ow = ow + 4) begin
						top = (g == L_G - 1) ? ((nf - 1) % 4) : 3;
						for (j = 0; j <= top; j = j + 1) begin
							for (i = 0; i < 4; i = i + 1)
								pk[i*32 +: 32] = (ow + i < L_OW) ? refo[oidx(4 * g + j, oh, ow + i)] : 0;
							e_data[q_tail] = pk;
							e_addr[q_tail] = ADDR'(1 + (4 * g + j) * L_OCH + oh * L_ORP + ow / 4);
							e_be[q_tail]   = {(ow + 3 < L_OW), (ow + 2 < L_OW), (ow + 1 < L_OW), 1'b1};
							e_last[q_tail] = (j == top);
							q_tail = q_tail + 1;
						end
					end

			img_ext_base = IMG_EB;
			img_words    = (ADDR+1)'((nbytes + 3) / 4);
			wgt_ext_base = WGT_EB;
			m            = 11'(L_M);
			n_groups     = 8'(L_G);
			last_cols    = cols;
			in_h         = DIMW'(h);
			in_w         = DIMW'(w);
			kh_max       = 3'(k - 1);
			kw_max       = 3'(k - 1);
			c_max        = 8'(ch - 1);
			pad          = 3'(p);
			step_kh      = (ADDR+3)'(L_RP - (k - 1));
			step_c       = (ADDR+3)'(L_CH - (k - 1) * L_RP - (k - 1));
			tile_addr0   = (ADDR+3)'(4 - p * L_RP - p);
			act_rp       = (ADDR+2)'(L_RP);
			out_h        = DIMW'(L_OH);
			out_w        = DIMW'(L_OW);
			out_base     = 11'd1;
			out_rp_w     = ADDR'(L_ORP);
			out_ch_pitch = ADDR'(L_OCH);
		end
	endtask

	task run(input integer h, input integer w, input integer ch, input integer nf, input integer k, input integer p);
		integer t0, p0, e0, f, y, x, missing, tiles, ideal, img_w;
		begin
			layer(h, w, ch, nf, k, p);
			p0 = pkts;
			e0 = errors + mon_err;
			$display("");
			$write("  %0dx%0dx%0d input, %0d filters %0dx%0d, pad %0d -> %0dx%0dx%0d output   (M = %0d, %0d filter group(s)",
			       h, w, ch, nf, k, k, p, L_OH, L_OW, nf, L_M, L_G);
			if (L_M > 512) $display(", single weight buffer)");
			else           $display(", double-buffered weights)");
			@(negedge clk);
			start = 1'b1;
			t0 = cyc;
			@(negedge clk);
			start = 1'b0;
			@(negedge clk);
			if (!busy) begin
				errors = errors + 1;
				$display("FAIL: busy did not go high after start");
			end
			while (!done) begin
				@(negedge clk);
				if (pkt_valid) decode_pkt;
				if (cyc - t0 > 400000) $fatal(1, "layer never finished");
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
			img_w = (4 + ch * L_CH + 3) / 4;
			$display("    finished in %0d cycles: image %0d words, weights %0d words, %0d tiles x (M+1) = %0d compute cycles",
			         cyc - t0, img_w, L_G * L_M, tiles, ideal);
			$display("    %0d packets, all %0d outputs compared with a reference convolution: %0d errors, %0d missing or duplicated",
			         pkts - p0, nf * L_OH * L_OW, errors + mon_err - e0, missing);
			if (small_vals != 0) begin
				print_input(h, w, ch, 1);
				for (f = 0; f < nf; f = f + 1) print_weights(f, ch, k);
				for (f = 0; f < nf; f = f + 1) print_outputs(f, L_OH, L_OW);
				explain_one(0, 0, 0, k, p, h, w);
				explain_one(1, 2, 2, k, p, h, w);
			end
			else if (L_OW >= 4)
				print_outputs(0, 3, 6);
			else begin
				$write("    outputs of all %0d filters (1x1 output each), hardware:", nf);
				for (f = 0; f < nf; f = f + 1) $write(" %0d", hw[oidx(f, 0, 0)]);
				$display("");
				$write("                                              reference:");
				for (f = 0; f < nf; f = f + 1) $write(" %0d", refo[oidx(f, 0, 0)]);
				$display("");
			end
			dump_layer(h, w, ch, nf, k, p);
			$display("    full input, weights and every output (hardware and reference) written to %0s", fname);
			layers = layers + 1;
		end
	endtask

	initial begin
		$dumpfile("accel_top.vcd");
		$dumpvars(0, tb_accel_top);

		errors = 0; layers = 0; cyc = 0; small_vals = 0; fd = 0;
		q_head = 0; q_tail = 0; mon_err = 0; pkts = 0;
		sq_head = 0; sq_tail = 0; sq_count = 0; rdy_r = 1'b1; mem_on = 1'b0;
		source(1, 1, 100);
		start = 1'b0;
		img_ext_base = 0; img_words = 0; wgt_ext_base = 0; m = 0; n_groups = 0; last_cols = 0;
		in_h = 0; in_w = 0; kh_max = 0; kw_max = 0; c_max = 0; pad = 0;
		step_kh = 0; step_c = 0; tile_addr0 = 0; act_rp = 0;
		out_h = 0; out_w = 0; out_base = 0; out_rp_w = 0; out_ch_pitch = 0;
		for (cyc = 0; cyc < 32; cyc = cyc + 1) begin
			q_addr[cyc] = {EAW{1'b0}};
			q_due[cyc]  = 0;
		end
		cyc = 0;

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
		$display("0) A tiny layer with small numbers you can check by hand (inputs 0-9, weights -1..1):");
		small_vals = 1;
		run(5, 5, 1, 2, 3, 1);
		small_vals = 0;

		$display("");
		$display("1) Ideal external memory (1-cycle latency, always ready):");
		run(28, 28, 1, 8, 3, 1);
		run(14, 14, 8, 16, 3, 1);
		run(10, 10, 3, 6, 3, 0);
		run(7, 7, 16, 10, 7, 0);
		run(12, 12, 2, 4, 5, 2);
		run(8, 8, 4, 5, 1, 0);

		$display("");
		$display("2) Slow external memory (latency 1-6 cycles, accepts 60%% of requests):");
		source(1, 6, 60);
		run(14, 14, 8, 16, 3, 1);
		run(7, 7, 16, 10, 7, 0);
		$display("");
		$display("   one tile per group and an even slower memory (40%% accepted), so loading a group takes longer than computing one:");
		source(1, 6, 40);
		run(3, 6, 16, 12, 3, 0);

		repeat (4) @(negedge clk);
		$display("");
		$display("3) Totals: %0d layers, %0d packets, %0d expected packets never arrived", layers, pkts, q_tail - q_head);
		if (q_head != q_tail) begin
			errors = errors + 1;
			$display("FAIL: %0d expected packets never arrived", q_tail - q_head);
		end
		errors = errors + mon_err;
		$display("");

		if (errors != 0) $fatal(1, "FAIL: %0d error(s)", errors);
		$display("PASS: %0d convolution layers, every output matches the reference", layers);
		$finish;
	end
endmodule
