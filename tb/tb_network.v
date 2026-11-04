`timescale 1ns/1ps

// Whole networks from one start: the testbench packs the image, all weights and the layer table into
// external memory, pulses start once, and checks every layer's int8 output map (watching the vector unit's
// stores) and the final result written back to external memory, against a reference model of the network.
module tb_network;
	localparam EAW    = 16;
	localparam N      = 4;
	localparam ADDR   = 11;
	localparam EWORDS = 1 << EAW;
	localparam IMG_EB = 0;
	localparam WGT_EB = 4096;
	localparam TBL_EB = 49152;
	localparam WB_EB  = 57344;
	localparam ML     = 8;               // layers per network, at most
	localparam MS     = 32 * 32 * 64;    // largest map (elements): up to 64 channels
	localparam real SM_STEP = 0.1;

	reg                 clk, rst_n, start;
	wire                busy, done, err_valid;
	wire [6:0]          err;
	reg  [EAW-1:0]      tbl_base;
	wire                rd_req_valid, rd_req_ready, rd_resp_valid, rd_resp_ready;
	wire [EAW-1:0]      rd_req_addr;
	wire [31:0]         rd_resp_data;
	wire                wr_req_valid, wr_req_ready;
	wire [EAW-1:0]      wr_req_addr;
	wire [31:0]         wr_req_data;

	reg  [31:0]         ext_mem [0:EWORDS-1];

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

	// ================================================================ external memory model
	reg  [EAW-1:0]      q_addr [0:31];
	integer             q_due  [0:31];
	integer             sq_head, sq_tail, sq_count, lat_min, lat_max, rdy_pct, cyc, wb_count;
	reg                 rdy_r, wrdy_r, mem_on;
	wire                req_fire  = rd_req_valid && rd_req_ready;
	wire                resp_fire = rd_resp_valid && rd_resp_ready;

	assign rd_req_ready  = mem_on && rdy_r && (sq_count < 32);
	assign rd_resp_valid = mem_on && (sq_count != 0) && (q_due[sq_head] <= cyc);
	assign rd_resp_data  = ext_mem[q_addr[sq_head]];
	assign wr_req_ready  = mem_on && wrdy_r;

	always @(posedge clk) begin
		cyc    <= cyc + 1;
		rdy_r  <= ({$random} % 100) < rdy_pct;
		wrdy_r <= ({$random} % 100) < rdy_pct;
		if (!mem_on) begin
			sq_head <= 0; sq_tail <= 0; sq_count <= 0;
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

	// ================================================================ the network under test
	integer nl;                                   // number of layers
	integer LH [0:ML-1];  integer LW [0:ML-1];  integer LC [0:ML-1];  integer LF [0:ML-1];
	integer LKH[0:ML-1];  integer LKW[0:ML-1];  integer LP [0:ML-1];  integer LS [0:ML-1];
	integer LMODE [0:ML-1];                       // 1 requantize + ReLU, 2 + 2x2 max pooling, 4 requantize + softmax
	integer LOH[0:ML-1];  integer LOW[0:ML-1];    // conv output
	integer SOH[0:ML-1];  integer SOW[0:ML-1];    // stored output (after pooling)
	integer QM [0:ML-1];  integer QS [0:ML-1];
	integer WADDR [0:ML-1];

	reg signed [7:0]  map_in  [0:MS-1];           // input of the layer being built
	reg signed [31:0] acc     [0:MS-1];           // its accumulators
	reg signed [7:0]  ref_out [0:ML*MS-1];        // every layer's reference output map
	reg signed [7:0]  hw_out  [0:ML*MS-1];        // every layer's map as stored by the vector unit
	integer           hw_wr   [0:ML*MS-1];
	reg        [15:0] exp_tab [0:255];

	function integer mi(input integer c, input integer y, input integer x);
		mi = (c * 32 + y) * 32 + x;
	endfunction

	function signed [31:0] f_req(input signed [31:0] a, input integer mp, input integer mn, input integer s);
		reg signed [63:0] y;
		begin
			y = (a < 0) ? $signed(a) * mn : $signed(a) * mp;
			if (s != 0) y = (y >>> s) + ((y >>> (s - 1)) & 64'sd1);
			if (y > 64'sd2147483647) y = 64'sd2147483647;
			if (y < -64'sd2147483648) y = -64'sd2147483648;
			f_req = y[31:0];
		end
	endfunction

	function signed [7:0] sat8(input signed [31:0] a);
		begin
			if (a > 127) sat8 = 127;
			else if (a < -128) sat8 = -128;
			else sat8 = a[7:0];
		end
	endfunction

	// one layer: random weights and biases packed for the chip, accumulators, scale, int8 output
	integer wptr;

	task build_layer(input integer l);
		integer c, y, x, f, kh, kw, kk, g, j, m, ng, oy, ox, sum, mx, v, k, d, best;
		reg signed [7:0] wt [0:64*16*49-1];
		reg signed [31:0] bias [0:63];
		real sc;
		begin
			LOH[l] = (LH[l] + 2 * LP[l] - LKH[l]) / LS[l] + 1;
			LOW[l] = (LW[l] + 2 * LP[l] - LKW[l]) / LS[l] + 1;
			SOH[l] = (LMODE[l] == 2) ? LOH[l] / 2 : LOH[l];
			SOW[l] = (LMODE[l] == 2) ? LOW[l] / 2 : LOW[l];
			m  = LC[l] * LKH[l] * LKW[l];
			ng = (LF[l] + 3) / 4;
			for (f = 0; f < LF[l]; f = f + 1) begin
				bias[f] = $random % 3000;
				for (kk = 0; kk < m; kk = kk + 1) wt[f * m + kk] = $random % 64;
			end
			// weights: per group of 4 filters, 4 bias words then M words {w3, w2, w1, w0}, k = c*(kh*kw) + kh*kw_size + kw
			WADDR[l] = wptr;
			for (g = 0; g < ng; g = g + 1) begin
				for (j = 0; j < 4; j = j + 1)
					ext_mem[wptr + g * (m + 4) + j] = (4 * g + j < LF[l]) ? bias[4 * g + j] : 32'd0;
				for (kk = 0; kk < m; kk = kk + 1)
					for (j = 0; j < 4; j = j + 1)
						ext_mem[wptr + g * (m + 4) + 4 + kk][j * 8 +: 8] = (4 * g + j < LF[l]) ? wt[(4 * g + j) * m + kk] : 8'd0;
			end
			wptr = wptr + ng * (m + 4);
			// convolution
			mx = 1;
			for (f = 0; f < LF[l]; f = f + 1)
				for (oy = 0; oy < LOH[l]; oy = oy + 1)
					for (ox = 0; ox < LOW[l]; ox = ox + 1) begin
						sum = bias[f];
						for (c = 0; c < LC[l]; c = c + 1)
							for (kh = 0; kh < LKH[l]; kh = kh + 1)
								for (kw = 0; kw < LKW[l]; kw = kw + 1) begin
									y = oy * LS[l] + kh - LP[l];
									x = ox * LS[l] + kw - LP[l];
									if (y >= 0 && y < LH[l] && x >= 0 && x < LW[l])
										sum = sum + map_in[mi(c, y, x)] * wt[f * m + c * LKH[l] * LKW[l] + kh * LKW[l] + kw];
								end
						acc[mi(f, oy, ox)] = sum;
						v = (sum < 0) ? -sum : sum;
						if (v > mx) mx = v;
					end
			// requantization from the layer's range
			sc = 120.0 / mx;
			QS[l] = 0;
			while ($rtoi(sc * (2.0 ** (QS[l] + 1)) + 0.5) <= 32767 && QS[l] < 47) QS[l] = QS[l] + 1;
			QM[l] = $rtoi(sc * (2.0 ** QS[l]) + 0.5);
			// output map (the next layer's input)
			for (f = 0; f < LF[l]; f = f + 1)
				for (oy = 0; oy < SOH[l]; oy = oy + 1)
					for (ox = 0; ox < SOW[l]; ox = ox + 1) begin
						if (LMODE[l] == 2) begin
							best = -128;
							for (k = 0; k < 4; k = k + 1) begin
								d = sat8(f_req(acc[mi(f, 2 * oy + k / 2, 2 * ox + k % 2)], QM[l], 0, QS[l]));
								if (d > best) best = d;
							end
							ref_out[l * MS + mi(f, oy, ox)] = best;
						end
						else
							ref_out[l * MS + mi(f, oy, ox)] = sat8(f_req(acc[mi(f, oy, ox)], QM[l], (LMODE[l] == 1) ? 0 : QM[l], QS[l]));
					end
		end
	endtask

	// softmax of the last layer (1x1xC logits) exactly as the program computes it, as bytes q (probability x 128)
	reg signed [7:0] sm_q [0:63];
	real             sm_f [0:63];

	task softmax_ref(input integer l);
		integer i, m;
		reg signed [31:0] d, sum, r, q;
		reg [63:0] q64;
		reg [31:0] ex [0:63];
		real fs;
		begin
			m = -128;
			for (i = 0; i < LF[l]; i = i + 1) if (ref_out[l * MS + mi(i, 0, 0)] > m) m = ref_out[l * MS + mi(i, 0, 0)];
			sum = 0;
			for (i = 0; i < LF[l]; i = i + 1) begin
				d = ref_out[l * MS + mi(i, 0, 0)] - m;
				if (d < -128) d = -128;
				ex[i] = {16'd0, exp_tab[d[7:0]]};
				sum = sum + ex[i];
			end
			q64 = (64'd1 << 30) / {32'd0, sum};
			r = q64[31:0];
			fs = 0.0;
			for (i = 0; i < LF[l]; i = i + 1) fs = fs + $exp(ref_out[l * MS + mi(i, 0, 0)] * SM_STEP);
			for (i = 0; i < LF[l]; i = i + 1) begin
				q64 = {32'd0, r} * {32'd0, ex[i]};
				q   = (q64[31:0] >>> 23) + ((q64[31:0] >>> 22) & 1);
				if (q > 127) q = 127;
				sm_q[i] = q[7:0];
				sm_f[i] = $exp(ref_out[l * MS + mi(i, 0, 0)] * SM_STEP) / fs;
			end
		end
	endtask

	// ================================================================ vector-unit programs and the table
	reg  [31:0] prg [0:63];
	integer     np, s_pro, s_body, s_e0, s_e1, s_e2, s_e3, tptr;

	function [31:0] venc(input [5:0] op, input [2:0] pr, input [3:0] d, input [3:0] a, input [3:0] b, input [10:0] x);
		venc = {op, pr, d, a, b, x};
	endfunction
	task vemit(input [31:0] w);
		begin
			prg[np] = w;
			np = np + 1;
		end
	endtask
	function [31:0] LI(input [3:0] d, input integer v);
		LI = {6'h01, 3'd0, d, v[18:0]};
	endfunction

	task build_program(input integer l);
		integer orp, och;
		begin
			np = 0;
			vemit(LI(1, QM[l]));
			vemit(LI(2, (LMODE[l] == 4) ? QM[l] : 0));
			vemit(venc(6'h09, 3'd0, 4'd0, 4'd1, 4'd2, 11'(QS[l])));            // SETQ q0, M, M_neg, S
			vemit(LI(3, -128)); vemit(LI(4, 127));
			vemit(venc(6'h0A, 3'd0, 4'd0, 4'd3, 4'd4, 11'd0));                 // SETC c0 = -128..127
			if (LMODE[l] == 2) begin
				orp = (SOW[l] + 3) / 4;
				och = SOH[l] * orp;
				vemit(LI(1, 1));   vemit(venc(6'h14, 3'd0, 4'd0, 4'd1, 4'd0, 11'd0));   // SETR out_base
				vemit(LI(1, och)); vemit(venc(6'h14, 3'd0, 4'd0, 4'd1, 4'd0, 11'd1));   // SETR channel pitch
				vemit(LI(1, orp)); vemit(venc(6'h14, 3'd0, 4'd0, 4'd1, 4'd0, 11'd2));   // SETR row pitch
				vemit(LI(1, 1));   vemit(venc(6'h14, 3'd0, 4'd0, 4'd1, 4'd0, 11'd3));   // SETR L = 1
				vemit(venc(6'h0C, 3'd0, 4'd2, 4'd0, 4'd1, {6'd0, 2'd2, 3'd2}));        // P2: even row
				vemit(venc(6'h0C, 3'd0, 4'd3, 4'd0, 4'd1, {6'd1, 2'd2, 3'd2}));        // P3: odd row
			end
			if (LMODE[l] == 4) begin
				vemit(LI(4, 0));  vemit(venc(6'h0A, 3'd0, 4'd2, 4'd3, 4'd4, 11'd0));    // c2 = -128..0
				vemit(LI(3, 0));  vemit(LI(4, 127));
				vemit(venc(6'h0A, 3'd0, 4'd1, 4'd3, 4'd4, 11'd0));                      // c1 = 0..127
				vemit(venc(6'h11, 3'd0, 4'd6, 4'd0, 4'hF, 11'h780));                     // VLI v6, -128
				vemit(venc(6'h11, 3'd0, 4'd5, 4'd0, 4'd0, 11'd0));                       // VLI v5, 0
				vemit(LI(10, 1)); vemit(LI(11, 1));
			end
			s_pro  = np;
			s_body = np;
			vemit(venc(6'h21, 3'd0, 4'd0, 4'd7, 4'd0, 11'd0));                    // REQ v0, v7, q0
			if (LMODE[l] == 1) vemit(venc(6'h38, 3'd0, 4'd0, 4'd0, 4'd0, 11'd0));  // ST8 v0, c0
			if (LMODE[l] == 2) begin
				vemit(venc(6'h22, 3'd0, 4'd0, 4'd0, 4'd0, 11'd0));                // CLAMP v0, v0, c0
				vemit(venc(6'h30, 3'd0, 4'd1, 4'd0, 4'd0, 11'd0));                // MAXP v1, v0
				vemit(venc(6'h08, 3'd0, 4'd6, 4'd0, 4'd0, 11'd8));                // TAG s6, lmidx
				vemit(venc(6'h3C, 3'd2, 4'd0, 4'd1, 4'd6, 11'd0));                // [p2] STS v1, s6
				vemit(venc(6'h3B, 3'd3, 4'd2, 4'd6, 4'd0, 11'd0));                // [p3] LDS v2, s6
				vemit(venc(6'h1B, 3'd3, 4'd1, 4'd1, 4'd2, 11'd0));                // [p3] MAX v1, v1, v2
				vemit(venc(6'h34, 3'd0, 4'd1, 4'd1, 4'd0, 11'b00_01_00_01_00));   // PERM lanes 0,1 -> 2,3
				vemit(venc(6'h08, 3'd0, 4'd9, 4'd0, 4'd0, 11'd6));                // TAG s9, paddr
				vemit(venc(6'h08, 3'd0, 4'd5, 4'd0, 4'd0, 11'd7));                // TAG s5, pbe
				vemit(venc(6'h39, 3'd3, 4'd5, 4'd1, 4'd9, 11'd0));                // [p3] ST8A v1, s9, s5, c0
			end
			if (LMODE[l] == 4) begin
				vemit(venc(6'h22, 3'd0, 4'd0, 4'd0, 4'd0, 11'd0));                // CLAMP v0, v0, c0
				vemit(venc(6'h08, 3'd0, 4'd1, 4'd0, 4'd0, 11'd4));                // TAG s1, chan
				vemit(venc(6'h3C, 3'd0, 4'd0, 4'd0, 4'd1, 11'd0));                // STS v0, s1
				vemit(venc(6'h1B, 3'd0, 4'd6, 4'd6, 4'd0, 11'd0));                // MAX v6, v6, v0
			end
			s_e0 = np;
			if (LMODE[l] == 4) begin
				vemit(venc(6'h08, 3'd0, 4'd1, 4'd0, 4'd0, 11'd9));                // TAG s1, iter
				vemit(venc(6'h3B, 3'd0, 4'd1, 4'd1, 4'd0, 11'd0));                // LDS v1, s1
				vemit(venc(6'h19, 3'd0, 4'd1, 4'd1, 4'd6, 11'd0));                // SUB v1, v1, v6
				vemit(venc(6'h22, 3'd0, 4'd1, 4'd1, 4'd0, 11'd2));                // CLAMP v1, v1, c2
				vemit(venc(6'h23, 3'd0, 4'd1, 4'd1, 4'd0, 11'd0));                // LUT v1, v1
				vemit(venc(6'h3C, 3'd0, 4'd0, 4'd1, 4'd1, 11'd0));                // STS v1, s1
				vemit(venc(6'h18, 3'd0, 4'd5, 4'd5, 4'd1, 11'd0));                // ADD v5, v5, v1
			end
			s_e1 = np;
			if (LMODE[l] == 4) begin
				vemit(venc(6'h33, 3'd0, 4'd2, 4'd5, 4'd0, 11'd0));                // RADD s2, v5
				vemit(venc(6'h0B, 3'd0, 4'd3, 4'd2, 4'd0, 11'd30));               // RCP s3, s2, 30
				vemit(venc(6'h12, 3'd0, 4'd4, 4'd3, 4'd0, 11'd0));                // BCAST v4, s3
			end
			s_e2 = np;
			if (LMODE[l] == 4) begin
				vemit(venc(6'h08, 3'd0, 4'd1, 4'd0, 4'd0, 11'd9));                // TAG s1, iter
				vemit(venc(6'h3B, 3'd0, 4'd1, 4'd1, 4'd0, 11'd0));                // LDS v1, s1
				vemit(venc(6'h20, 3'd0, 4'd2, 4'd4, 4'd1, 11'd0));                // MUL v2, v4, v1
				vemit(venc(6'h1F, 3'd0, 4'd2, 4'd2, 4'd0, 11'd23));               // SHRR v2, v2, 23
				vemit(venc(6'h04, 3'd0, 4'd5, 4'd10, 4'd1, 11'd0));               // ADDS s5, s10, s1
				vemit(venc(6'h39, 3'd0, 4'd11, 4'd2, 4'd5, 11'd1));               // ST8A v2, s5, s11, c1
			end
			s_e3 = np;
		end
	endtask

	function [31:0] sect(input integer st, input integer len, input integer cnt);
		sect = {10'd0, 9'(cnt), 7'(len), 6'(st)};
	endfunction

	task write_entry(input integer l);
		integer i, nlut, words;
		begin
			build_program(l);
			nlut  = (LMODE[l] == 4) ? 256 : 0;
			words = 1 + LF[l] * SOH[l] * ((SOW[l] + 3) / 4);
			ext_mem[tptr + 0] = {8'(LF[l]), 8'(LC[l]), 8'(LW[l]), 8'(LH[l])};
			ext_mem[tptr + 1] = {13'd0, (l == nl - 1), (l == nl - 1), (l == 0), 2'd0, ((LMODE[l] == 2) ? 2'd1 : 2'd0),
			                     3'(LS[l]), 3'(LP[l]), 3'(LKW[l]), 3'(LKH[l])};
			ext_mem[tptr + 2] = {5'd0, 11'd1, 16'(WADDR[l])};
			ext_mem[tptr + 3] = {16'(WB_EB), 16'(IMG_EB)};
			ext_mem[tptr + 4] = {8'd0, 12'(words), 1'b0, 11'd0};
			ext_mem[tptr + 5] = {15'd0, 9'(nlut), 1'b0, 7'(np)};
			ext_mem[tptr + 6]  = sect(0, s_pro, 1);
			ext_mem[tptr + 7]  = sect(s_body, s_e0 - s_body, 0);
			ext_mem[tptr + 8]  = sect(s_e0, s_e1 - s_e0, LF[l]);
			ext_mem[tptr + 9]  = sect(s_e1, s_e2 - s_e1, 1);
			ext_mem[tptr + 10] = sect(s_e2, s_e3 - s_e2, LF[l]);
			ext_mem[tptr + 11] = sect(0, 0, 0);
			for (i = 0; i < np; i = i + 1) ext_mem[tptr + 12 + i] = prg[i];
			for (i = 0; i < nlut / 2; i = i + 1) ext_mem[tptr + 12 + np + i] = {exp_tab[2 * i + 1], exp_tab[2 * i]};
			tptr = tptr + 12 + np + nlut / 2;
		end
	endtask

	// ================================================================ watching the vector unit's stores
	integer cur_layer;
	initial begin : snoop
		integer i, base;
		forever begin
			@(posedge clk);
			if (mem_on && dut.st_en) begin
				base = dut.u_seq.layer_idx * MS;
				for (i = 0; i < N; i = i + 1)
					if (dut.st_be[i]) begin
						hw_out[base + dut.st_addr * 4 + i] = dut.st_data[i*8 +: 8];
						hw_wr[base + dut.st_addr * 4 + i]  = hw_wr[base + dut.st_addr * 4 + i] + 1;
					end
			end
		end
	end

	// ================================================================ running a network
	integer errors, nets, total_errs, layer_t [0:ML];

	initial begin : layer_times
		forever begin
			@(posedge clk);
			if (mem_on && dut.u_seq.layer_start) layer_t[dut.u_seq.layer_idx] = cyc;
		end
	end

	task define(input integer l, input integer h, input integer w, input integer c, input integer f,
	            input integer kh, input integer kw, input integer p, input integer s, input integer mode);
		begin
			LH[l] = h; LW[l] = w; LC[l] = c; LF[l] = f; LKH[l] = kh; LKW[l] = kw; LP[l] = p; LS[l] = s; LMODE[l] = mode;
		end
	endtask

	task run_network(input [8*64:1] name, input integer loud);
		integer l, c, y, x, b, i, e0, rp, ch, wa, t0, nerr, written, best_r, best_h;
		reg signed [7:0] hv;
		begin
			e0 = errors;
			// input image, planar with a guard word and rows padded to 4 bytes
			for (i = 0; i < 2048; i = i + 1) ext_mem[IMG_EB + i] = $random;
			for (c = 0; c < LC[0]; c = c + 1)
				for (y = 0; y < LH[0]; y = y + 1)
					for (x = 0; x < LW[0]; x = x + 1) begin
						map_in[mi(c, y, x)] = 8'($random % 100);
						rp = ((LW[0] + 3) / 4) * 4;
						b  = 4 + c * LH[0] * rp + y * rp + x;
						ext_mem[IMG_EB + b / 4][(b % 4) * 8 +: 8] = map_in[mi(c, y, x)];
					end
			// all layers: weights, reference, table entries
			wptr = WGT_EB;
			tptr = TBL_EB;
			for (l = 0; l < nl; l = l + 1) begin
				build_layer(l);
				write_entry(l);
				for (c = 0; c < LF[l]; c = c + 1)
					for (y = 0; y < SOH[l]; y = y + 1)
						for (x = 0; x < SOW[l]; x = x + 1)
							map_in[mi(c, y, x)] = ref_out[l * MS + mi(c, y, x)];
			end
			softmax_ref(nl - 1);
			for (i = 0; i < ML * MS; i = i + 1) hw_wr[i] = 0;
			for (i = 0; i < 2048; i = i + 1) ext_mem[WB_EB + i] = 32'hDEADBEEF;

			$display("");
			$display("  %0s", name);
			t0 = cyc;
			@(negedge clk);
			tbl_base = TBL_EB;
			start = 1'b1;
			@(negedge clk);
			start = 1'b0;
			i = 0;
			while (!done) begin
				@(negedge clk);
				i = i + 1;
				if (i > 2000000) $fatal(1, "network never finished");
			end
			layer_t[nl] = cyc;
			if (err_valid) begin
				errors = errors + 1;
				$display("    FAIL: a layer was rejected, err = %b", err);
			end
			repeat (3) @(negedge clk);

			// every layer's stored map against the reference
			for (l = 0; l < nl; l = l + 1) begin
				nerr = 0; written = 0;
				rp = (SOW[l] + 3) / 4;
				ch = SOH[l] * rp;
				for (c = 0; c < LF[l]; c = c + 1)
					for (y = 0; y < SOH[l]; y = y + 1)
						for (x = 0; x < SOW[l]; x = x + 1) begin
							wa = 1 + c * ch + y * rp + x / 4;
							if (LMODE[l] == 4) wa = 1 + c;
							hv = hw_out[l * MS + wa * 4 + ((LMODE[l] == 4) ? 0 : x % 4)];
							written = written + 1;
							if (hw_wr[l * MS + wa * 4 + ((LMODE[l] == 4) ? 0 : x % 4)] != 1 ||
							    hv != ((LMODE[l] == 4) ? sm_q[c] : ref_out[l * MS + mi(c, y, x)])) begin
								nerr = nerr + 1;
								if (nerr <= 3) $display("    FAIL layer %0d filter %0d (%0d,%0d): %0d, expected %0d", l, c, y, x, hv,
								                        (LMODE[l] == 4) ? sm_q[c] : ref_out[l * MS + mi(c, y, x)]);
							end
						end
				errors = errors + nerr;
				$display("    layer %0d: %2dx%-2dx%-2d -> %2d filters %0dx%0d, pad %0d, stride %0d, %-27s -> %2dx%-2dx%-2d  M=%5d S=%2d  %6d cycles  %0d values, %0d wrong",
				         l, LH[l], LW[l], LC[l], LF[l], LKH[l], LKW[l], LP[l], LS[l],
				         (LMODE[l] == 1) ? "requantize + ReLU" : ((LMODE[l] == 2) ? "requantize + ReLU + 2x2 pool" : "requantize + softmax"),
				         SOH[l], SOW[l], LF[l], QM[l], QS[l], layer_t[l + 1] - layer_t[l], written, nerr);
			end

			// the result in external memory (written back by the chip)
			nerr = 0;
			best_r = 0; best_h = 0;
			for (i = 0; i < LF[nl - 1]; i = i + 1) begin
				hv = ext_mem[WB_EB + 1 + i][7:0];
				if (hv != sm_q[i]) nerr = nerr + 1;
				if (sm_f[i] > sm_f[best_r]) best_r = i;
				if (hv > $signed(ext_mem[WB_EB + 1 + best_h][7:0])) best_h = i;
			end
			errors = errors + nerr;
			if (loud != 0) begin
				$write("    result written back:  class");
				for (i = 0; i < LF[nl - 1]; i = i + 1) $write(" %5d", i);
				$display("");
				$write("      probability (chip):     ");
				for (i = 0; i < LF[nl - 1]; i = i + 1) begin
					hv = ext_mem[WB_EB + 1 + i][7:0];
					$write(" %5.3f", hv / 128.0);
				end
				$display("");
				$write("      softmax (float):        ");
				for (i = 0; i < LF[nl - 1]; i = i + 1) $write(" %5.3f", sm_f[i]);
				$display("");
			end
			$display("    predicted class: chip %0d, float reference %0d;  %0d cycles for the whole network;  %0d errors",
			         best_h, best_r, cyc - t0, errors - e0);
			nets = nets + 1;
		end
	endtask

	integer t, nlr, l2, hh, ww, cc;

	initial begin
		if ($test$plusargs("vcd")) begin
			$dumpfile("waveforms/network.vcd");
			$dumpvars(0, tb_network);
		end
		errors = 0; nets = 0; cyc = 0; start = 1'b0; tbl_base = TBL_EB;
		lat_min = 1; lat_max = 1; rdy_pct = 100; rdy_r = 1'b1; wrdy_r = 1'b1; mem_on = 1'b0;
		sq_head = 0; sq_tail = 0; sq_count = 0;
		for (t = 0; t < EWORDS; t = t + 1) ext_mem[t] = 32'd0;
		for (t = 0; t < 256; t = t + 1)
			exp_tab[t] = 16'($rtoi(32767.0 * $exp(((t < 128) ? 0 : t - 256) * SM_STEP) + 0.5));
		rst_n = 1'b0;
		repeat (3) @(negedge clk);
		rst_n = 1'b1;
		repeat (10) @(negedge clk);           // the chip's reset synchronizer needs a couple of cycles
		mem_on = 1'b1;

		$display("");
		$display("Whole networks from one start: image, weights and layer table in external memory;");
		$display("every layer's int8 map (as stored by the vector unit) and the written-back result are checked.");

		nl = 3;
		define(0, 28, 28, 1, 8, 3, 3, 1, 1, 2);
		define(1, 14, 14, 8, 16, 3, 3, 1, 1, 2);
		define(2, 7, 7, 16, 10, 7, 7, 0, 1, 4);
		run_network("MNIST-style CNN: conv-pool, conv-pool, FC + softmax", 1);

		nl = 4;
		define(0, 16, 16, 3, 8, 3, 3, 1, 2, 1);
		define(1, 8, 8, 8, 12, 1, 1, 0, 1, 1);
		define(2, 8, 8, 12, 8, 3, 3, 1, 1, 2);
		define(3, 4, 4, 8, 5, 4, 4, 0, 1, 4);
		run_network("stride-2 conv, 1x1 conv, conv-pool, FC + softmax", 1);

		nl = 3;
		define(0, 9, 6, 3, 2, 3, 3, 1, 1, 2);
		define(1, 4, 3, 2, 2, 3, 3, 1, 1, 1);
		define(2, 4, 3, 2, 19, 4, 3, 0, 1, 4);
		run_network("small maps, uneven 4x3 FC kernel, 19 classes", 0);

		lat_min = 1; lat_max = 6; rdy_pct = 60;
		nl = 3;
		define(0, 28, 28, 1, 8, 3, 3, 1, 1, 2);
		define(1, 14, 14, 8, 16, 3, 3, 1, 1, 2);
		define(2, 7, 7, 16, 10, 7, 7, 0, 1, 4);
		run_network("the MNIST-style CNN again, slow external memory", 0);
		lat_min = 1; lat_max = 1; rdy_pct = 100;

		for (t = 0; t < 12; t = t + 1) begin
			nlr = 2 + {$random} % 3;                       // 1..3 conv layers, then FC + softmax
			hh = 6 + {$random} % 7; ww = 6 + {$random} % 7; cc = 1 + {$random} % 4;
			nl = nlr;
			for (l2 = 0; l2 < nlr - 1; l2 = l2 + 1) begin
				define(l2, hh, ww, cc, 1 + {$random} % 6, 3, 3, 1, 1, (({$random} % 2) == 1 && hh >= 4 && ww >= 4) ? 2 : 1);
				cc = LF[l2];
				if (LMODE[l2] == 2) begin hh = hh / 2; ww = ww / 2; end
			end
			// the FC kernel covers the whole map, and kernels go up to 7x7: pool the last conv if the map is larger
			if (hh > 7 || ww > 7) begin
				LMODE[nlr - 2] = 2;
				hh = LH[nlr - 2] / 2; ww = LW[nlr - 2] / 2;
			end
			define(nlr - 1, hh, ww, cc, 2 + {$random} % 20, hh, ww, 0, 1, 4);
			run_network("random network", 0);
		end

		$display("");
		$display("Totals: %0d networks, %0d errors", nets, errors);
		$display("");
		if (errors != 0) $fatal(1, "FAIL");
		$display("PASS: every layer of every network and every written-back result matches the reference");
		$finish;
	end
endmodule
