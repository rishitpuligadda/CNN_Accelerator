`timescale 1ns/1ps

module tb_result_collector;
	localparam N     = 4;
	localparam WIDTH = 8;
	localparam ACC_W = 4 * WIDTH;
	localparam ADDR  = 11;
	localparam RW    = 2;
	localparam MMAX  = 1024;
	localparam QMAX  = 4096;

	reg                  clk, rst_n;
	reg                  en;
	reg  [N*WIDTH-1:0]   act_lanes, wgt_lanes;
	wire [N*WIDTH-1:0]   act_sk, wgt_sk;
	wire [N*ACC_W-1:0]   c_col;
	wire [N*RW-1:0]      c_row;
	wire [N-1:0]         c_valid;
	wire [N*N-1:0]       pe_done;
	wire                 arr_done;

	reg  [ADDR-1:0]      ch_pitch, desc_addr;
	reg                  desc_push;
	reg  [N-1:0]         desc_lanes, desc_cols;
	wire                 desc_full;
	wire                 pkt_valid, pkt_last;
	wire [N*ACC_W-1:0]   pkt_data;
	wire [ADDR-1:0]      pkt_addr;
	wire [N-1:0]         pkt_be;

	integer              A [0:N-1][0:MMAX-1];
	integer              B [0:MMAX-1][0:N-1];
	reg  [N*ACC_W-1:0]   e_data [0:QMAX-1];
	reg  [ADDR-1:0]      e_addr [0:QMAX-1];
	reg  [N-1:0]         e_be   [0:QMAX-1];
	reg                  e_last [0:QMAX-1];
	integer              q_head, q_tail, mon_err, pkts, lasts, full_seen, pe_pulses, arr_pulses;
	integer              errors, tiles, n, cyc;
	reg                  mon_on, trace;

	skew_buffer #(.LANES(N), .WIDTH(WIDTH)) u_skew_act (
		.clk(clk), .rst_n(rst_n), .din(act_lanes), .dout(act_sk)
	);

	skew_buffer #(.LANES(N), .WIDTH(WIDTH)) u_skew_wgt (
		.clk(clk), .rst_n(rst_n), .din(wgt_lanes), .dout(wgt_sk)
	);

	systolic_array #(.TILE_MAX(N), .WIDTH(WIDTH)) u_array (
		.c_col(c_col), .c_row(c_row), .c_valid(c_valid), .pe_done(pe_done), .done(arr_done),
		.a(wgt_sk), .b(act_sk), .clk(clk), .rst_n(rst_n), .en(en)
	);

	result_collector #(.N(N), .ACC_W(ACC_W), .ADDR(ADDR), .QD(4)) dut (
		.clk(clk), .rst_n(rst_n),
		.c_col(c_col), .c_row(c_row), .c_valid(c_valid),
		.ch_pitch(ch_pitch),
		.desc_push(desc_push), .desc_addr(desc_addr), .desc_lanes(desc_lanes), .desc_cols(desc_cols),
		.desc_full(desc_full),
		.pkt_valid(pkt_valid), .pkt_data(pkt_data), .pkt_addr(pkt_addr), .pkt_be(pkt_be), .pkt_last(pkt_last)
	);

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

	always @(posedge clk) cyc <= cyc + 1;

	always @(negedge clk) begin
		if (mon_on) begin
			if (desc_full) full_seen <= full_seen + 1;
			pe_pulses <= pe_pulses + $countones(pe_done);
			if (arr_done) arr_pulses <= arr_pulses + 1;
			if (pkt_valid) begin
				pkts <= pkts + 1;
				if (pkt_last) lasts <= lasts + 1;
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
	end

	always @(negedge clk) begin
		if (trace) begin
			$write("  %3d |  %b  |", cyc, en);
			for (n = 0; n < N; n = n + 1)
				if (c_valid[n]) $write("  r%0d", c_row[n*RW +: RW]);
				else            $write("   .");
			$write("  |");
			if (pkt_valid)
				$display("  addr %4d  be %b  last %b  data %6d %6d %6d %6d", pkt_addr, pkt_be, pkt_last,
				         $signed(pkt_data[0*ACC_W +: ACC_W]), $signed(pkt_data[1*ACC_W +: ACC_W]),
				         $signed(pkt_data[2*ACC_W +: ACC_W]), $signed(pkt_data[3*ACC_W +: ACC_W]));
			else
				$display("");
		end
	end

	task make_tile(input integer m, input integer lanes, input integer cols, input integer kind);
		integer i, j, k;
		begin
			for (k = 0; k < m; k = k + 1) begin
				for (i = 0; i < N; i = i + 1) begin
					if (kind == 1)      A[i][k] = i + k;
					else if (kind == 2) A[i][k] = (i % 2 == 0) ? -128 : 127;
					else                A[i][k] = $random % 128;
					if (((lanes >> i) & 1) == 0) A[i][k] = 0;
				end
				for (j = 0; j < N; j = j + 1) begin
					if (kind == 1)      B[k][j] = j + 1;
					else if (kind == 2) B[k][j] = -128;
					else                B[k][j] = $random % 128;
					if (((cols >> j) & 1) == 0) B[k][j] = 0;
				end
			end
		end
	endtask

	task expect_tile(input integer m, input integer lanes, input integer cols, input integer addr);
		integer i, j, k, sum, top;
		reg [N*ACC_W-1:0] w;
		begin
			if (lanes < 1 || lanes > 15 || cols < 1 || cols > 15 || addr < 0 || addr > 2047)
				$fatal(1, "expect_tile: bad arguments");
			top = -1;
			for (j = 0; j < N; j = j + 1)
				if (((cols >> j) & 1) != 0) top = j;
			for (j = 0; j < N; j = j + 1) begin
				if (((cols >> j) & 1) != 0) begin
					for (i = 0; i < N; i = i + 1) begin
						sum = 0;
						for (k = 0; k < m; k = k + 1)
							sum = sum + A[i][k] * B[k][j];
						w[i*ACC_W +: ACC_W] = sum;
					end
					e_data[q_tail] = w;
					e_addr[q_tail] = ADDR'(addr + j * ch_pitch);
					e_be[q_tail]   = lanes[N-1:0];
					e_last[q_tail] = (j == top);
					q_tail = q_tail + 1;
				end
			end
		end
	endtask

	task stream_tile(input integer m, input integer lanes, input integer cols, input integer addr, input integer gap);
		integer i, k;
		begin
			if (m < 3 || m > MMAX || gap < 1 || lanes < 1 || lanes > 15 || cols < 1 || cols > 15 || addr < 0 || addr > 2047)
				$fatal(1, "stream_tile: bad arguments");
			for (k = 0; k < m; k = k + 1) begin
				@(negedge clk);
				en = 1'b1;
				for (i = 0; i < N; i = i + 1) begin
					act_lanes[i*WIDTH +: WIDTH] = WIDTH'(A[i][k]);
					wgt_lanes[i*WIDTH +: WIDTH] = WIDTH'(B[k][i]);
				end
				desc_push = (k == 0);
				if (k == 0) begin
					desc_addr  = addr[ADDR-1:0];
					desc_lanes = lanes[N-1:0];
					desc_cols  = cols[N-1:0];
				end
			end
			for (k = 0; k < gap; k = k + 1) begin
				@(negedge clk);
				en        = 1'b0;
				desc_push = 1'b0;
				act_lanes = {(N*WIDTH){1'b0}};
				wgt_lanes = {(N*WIDTH){1'b0}};
			end
			tiles = tiles + 1;
		end
	endtask

	task tile(input integer m, input integer lanes, input integer cols, input integer addr, input integer gap,
	          input integer kind);
		begin
			make_tile(m, lanes, cols, kind);
			expect_tile(m, lanes, cols, addr);
			stream_tile(m, lanes, cols, addr, gap);
		end
	endtask

	task drain;
		begin
			repeat (3 * N + 8) @(negedge clk);
		end
	endtask

	task report(input integer t0, input integer p0, input integer e0);
		begin
			$display("    %0d tiles, %0d packets checked, %0d errors", tiles - t0, pkts - p0, mon_err - e0);
		end
	endtask

	integer t0, p0, e0, m, ln, cl, g;

	initial begin
		$dumpfile("result_collector.vcd");
		$dumpvars(0, tb_result_collector);

		errors = 0; tiles = 0; cyc = 0;
		q_head = 0; q_tail = 0; mon_err = 0; pkts = 0; lasts = 0; full_seen = 0; pe_pulses = 0; arr_pulses = 0;
		mon_on = 1'b0; trace = 1'b0;
		en = 1'b0; act_lanes = 0; wgt_lanes = 0;
		ch_pitch = 11'd49; desc_push = 1'b0; desc_addr = 0; desc_lanes = 0; desc_cols = 0;

		rst_n = 1'b0;
		repeat (2) @(negedge clk);
		rst_n = 1'b1;
		repeat (4) @(negedge clk);
		mon_on = 1'b1;

		$display("");
		$display("1) One tile, M = 4, small values: activations A[i][k] = i+k, weights B[k][j] = j+1");
		$display("   row sums of A are 6, 10, 14, 18, so column j's results are (j+1) x those;");
		$display("   tile address 100, channel pitch 49 words, so column j's packet goes to 100 + 49j");
		$display("   cyc | en  | array columns 0..3 |  packet out");
		@(negedge clk);
		trace = 1'b1;
		tile(4, 15, 15, 100, 1, 1);
		repeat (9) @(negedge clk);
		trace = 1'b0;
		drain;
		$display("   each column delivers rows r0..r3 on consecutive cycles, one column behind the other;");
		$display("   a packet leaves the cycle after a column's r3, carrying all 4 rows of that column");

		$display("");
		$display("2) Full tiles back to back with the minimum one-cycle gap:");
		for (g = 0; g < 4; g = g + 1) begin
			m = (g == 0) ? 3 : (g == 1) ? 9 : (g == 2) ? 27 : 72;
			t0 = tiles; p0 = pkts; e0 = mon_err;
			for (n = 0; n < 8; n = n + 1)
				tile(m, 15, 15, 1 + 4 * n, 1, 0);
			drain;
			$write("  M = %2d:", m);
			report(t0, p0, e0);
		end

		$display("");
		$display("3) Partial tiles and partial filter groups:");
		t0 = tiles; p0 = pkts; e0 = mon_err;
		tile(9, 3, 15, 200, 1, 0);
		tile(9, 15, 3, 300, 1, 0);
		tile(9, 1, 1, 400, 1, 0);
		tile(9, 15, 8, 500, 1, 0);
		tile(9, 5, 10, 600, 1, 0);
		drain;
		$display("    lane_on 0011, col_on 0011, lane/col 0001, col_on 1000, lane_on 0101 + col_on 1010:");
		report(t0, p0, e0);

		$display("");
		$display("4) Extreme values: M = 784 (the FC length) with -128 x -128 and 127 x -128 products:");
		t0 = tiles; p0 = pkts; e0 = mon_err;
		tile(784, 15, 15, 700, 1, 2);
		drain;
		$display("    results are 784 x (-128 x -128) = %0d and 784 x (127 x -128) = %0d,", 784 * 16384, -784 * 16256);
		$display("    far inside the 32-bit range (about +-2.1 billion)");
		report(t0, p0, e0);

		$display("");
		$display("5) 40 random tiles: random M (3..40), random gaps (1..3), random lanes and columns:");
		t0 = tiles; p0 = pkts; e0 = mon_err;
		for (n = 0; n < 40; n = n + 1) begin
			m  = 3 + {$random} % 38;
			ln = 1 + {$random} % 15;
			cl = 1 + {$random} % 15;
			tile(m, ln, cl, {$random} % 2048, 1 + {$random} % 3, 0);
		end
		drain;
		report(t0, p0, e0);

		repeat (4) @(negedge clk);
		$display("");
		$display("6) Totals: %0d tiles, %0d packets, %0d last flags, %0d expected packets never arrived, desc_full seen %0d times",
		         tiles, pkts, lasts, q_tail - q_head, full_seen);
		if (q_head != q_tail) begin
			errors = errors + 1;
			$display("FAIL: %0d expected packets never arrived", q_tail - q_head);
		end
		if (lasts != tiles) begin
			errors = errors + 1;
			$display("FAIL: %0d last flags for %0d tiles", lasts, tiles);
		end
		$display("   PE done pulses: %0d (16 per tile), array done pulses: %0d (1 per tile)", pe_pulses, arr_pulses);
		if (pe_pulses != 16 * tiles || arr_pulses != tiles) begin
			errors = errors + 1;
			$display("FAIL: PE or array done pulse count is wrong");
		end
		if (full_seen != 0) begin
			errors = errors + 1;
			$display("FAIL: descriptor FIFO filled up");
		end
		errors = errors + mon_err;
		$display("");

		if (errors != 0) $fatal(1, "FAIL: %0d error(s)", errors);
		$display("PASS: %0d tiles, %0d packets checked", tiles, pkts);
		$finish;
	end
endmodule
