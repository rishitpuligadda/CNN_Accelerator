`timescale 1ns/1ps

module tb_systolic_activity;
	parameter N     = 4;
	parameter WIDTH = 8;
	parameter KMAX  = 8;

	localparam ACC_W = 4*WIDTH;
	localparam ROW_W = $clog2(N);
	localparam NRUN  = 3;
	localparam SENT  = 32'h7EADBEEF;

	wire signed [N*ACC_W-1:0] c_col;
	wire        [N*ROW_W-1:0] c_row;
	wire        [N-1:0]       c_valid;
	wire        [N*N-1:0]     pe_done;
	wire                      done;
	reg  signed [N*WIDTH-1:0] a, b;
	reg                       clk, rst_n;
	reg                       en;

	wire        [N*N-1:0]     pe_en;

	integer Am          [0:1][0:N-1][0:KMAX-1];
	integer Bm          [0:1][0:KMAX-1][0:N-1];
	integer gold        [0:1][0:N-1][0:N-1];
	integer got         [0:1][0:N-1][0:N-1];
	integer got_cnt     [0:N-1];
	integer first_cycle [0:NRUN-1][0:N*N-1];
	integer active_cnt  [0:NRUN-1][0:N*N-1];
	integer run_k       [0:NRUN-1];
	integer errors = 0;

	integer cur_nt, cur_k0, cur_k1;

	systolic_array #(.TILE_MAX(N), .WIDTH(WIDTH)) dut (
		.c_col(c_col),
		.c_row(c_row),
		.c_valid(c_valid),
		.pe_done(pe_done),
		.done(done),
		.a(a),
		.b(b),
		.clk(clk),
		.rst_n(rst_n),
		.en(en)
	);

	genvar gi, gj;
	generate
		for (gi = 0; gi < N; gi = gi + 1) begin : TAP_ROW
			for (gj = 0; gj < N; gj = gj + 1) begin : TAP_COL
				assign pe_en[gi*N + gj] = dut.ROW[gi].COL[gj].PE.en;
			end
		end
	endgenerate

	initial clk = 1'b0;
	always #5 clk = ~clk;

	function integer tile_of(input integer s);
		begin
			tile_of = -1;
			if (s >= 0 && s < cur_k0)
				tile_of = 0;
			else if (cur_nt == 2 && s >= cur_k0 + 1 && s < cur_k0 + 1 + cur_k1)
				tile_of = 1;
		end
	endfunction

	function integer kidx_of(input integer s);
		begin
			if (s < cur_k0) kidx_of = s;
			else            kidx_of = s - (cur_k0 + 1);
		end
	endfunction

	task run_tiles(input integer r, input integer nt, input integer k0, input integer k1);
		integer t, i, j, kk, kt, tl, sum, total, stream_len, idx, s, tp;
		integer seen_done, n_hot, row_got, row_exp;
		reg     exp_en;
		begin
			cur_nt   = nt;
			cur_k0   = k0;
			cur_k1   = (nt == 2) ? k1 : 0;
			run_k[r] = cur_k0 + cur_k1;

			for (tl = 0; tl < nt; tl = tl + 1) begin
				kt = (tl == 0) ? cur_k0 : cur_k1;
				for (i = 0; i < N; i = i + 1)
					for (kk = 0; kk < kt; kk = kk + 1) begin
						Am[tl][i][kk] = $random % 10;
						Bm[tl][kk][i] = $random % 10;
					end
				for (i = 0; i < N; i = i + 1)
					for (j = 0; j < N; j = j + 1) begin
						sum = 0;
						for (kk = 0; kk < kt; kk = kk + 1)
							sum = sum + Am[tl][i][kk] * Bm[tl][kk][j];
						gold[tl][i][j] = sum;
						got[tl][i][j]  = SENT;
					end
			end

			for (idx = 0; idx < N*N; idx = idx + 1) begin
				first_cycle[r][idx] = -1;
				active_cnt[r][idx]  = 0;
			end
			for (j = 0; j < N; j = j + 1) got_cnt[j] = 0;

			$display("");
			if (nt == 1)
				$display("============ RUN %0d: A (%0dx%0d) x B (%0dx%0d) = C (%0dx%0d) ============",
				         r+1, N, k0, k0, N, N, N);
			else
				$display("============ RUN %0d: TWO TILES BACK TO BACK (K = %0d, idle cycle, K = %0d) ============",
				         r+1, k0, k1);

			for (tl = 0; tl < nt; tl = tl + 1) begin
				kt = (tl == 0) ? cur_k0 : cur_k1;
				if (nt == 2) $display("--- tile %0d ---", tl);
				$display("A =");
				for (i = 0; i < N; i = i + 1) begin
					for (kk = 0; kk < kt; kk = kk + 1) $write("%5d", Am[tl][i][kk]);
					$display("");
				end
				$display("B =");
				for (kk = 0; kk < kt; kk = kk + 1) begin
					for (j = 0; j < N; j = j + 1) $write("%5d", Bm[tl][kk][j]);
					$display("");
				end
			end

			$display("");
			$display("PE activity (rows 0..%0d)   # = en high   D = done pulse   * = en high + done   . = idle   ! = wrong", N-1);
			$display("valid = c_valid (one bit per column, MSB = column %0d)", N-1);

			seen_done  = 0;
			stream_len = (nt == 1) ? cur_k0 : cur_k0 + 1 + cur_k1;
			total      = stream_len + 2*N + 1;

			for (t = 0; t < total; t = t + 1) begin
				@(negedge clk);
				en = (tile_of(t) >= 0);
				for (i = 0; i < N; i = i + 1) begin
					s  = t - i;
					tp = tile_of(s);
					if (tp >= 0) begin
						b[i*WIDTH +: WIDTH] = Am[tp][i][kidx_of(s)][WIDTH-1:0];
						a[i*WIDTH +: WIDTH] = Bm[tp][kidx_of(s)][i][WIDTH-1:0];
					end
					else begin
						b[i*WIDTH +: WIDTH] = {WIDTH{1'b0}};
						a[i*WIDTH +: WIDTH] = {WIDTH{1'b0}};
					end
				end
				#1;

				$write("t=%t  cycle %2d  en=%b |", $time, t, en);
				for (i = 0; i < N; i = i + 1) begin
					$write(" ");
					for (j = 0; j < N; j = j + 1) begin
						idx    = i*N + j;
						exp_en = (tile_of(t - i - j) >= 0);
						if (pe_en[idx] !== exp_en) begin
							$write("!");
							errors = errors + 1;
						end
						else if (pe_en[idx] && pe_done[idx]) $write("*");
						else if (pe_en[idx])                 $write("#");
						else if (pe_done[idx])               $write("D");
						else                                 $write(".");
						if (pe_en[idx]) begin
							if (first_cycle[r][idx] < 0) first_cycle[r][idx] = t;
							active_cnt[r][idx] = active_cnt[r][idx] + 1;
						end
					end
					$write(" |");
				end
				$write("  valid=%b", c_valid);
				if (done) begin
					$write("  <- tile %0d fully streamed", seen_done);
					seen_done = seen_done + 1;
				end
				$display("");

				for (j = 0; j < N; j = j + 1) begin
					n_hot = 0;
					for (i = 0; i < N; i = i + 1)
						if (pe_done[i*N + j]) n_hot = n_hot + 1;
					if (n_hot > 1) begin
						$display("COLLISION: %0d PEs in column %0d done in the same cycle", n_hot, j);
						errors = errors + 1;
					end
				end

				for (j = 0; j < N; j = j + 1)
					if (c_valid[j]) begin
						tl      = got_cnt[j] / N;
						row_exp = got_cnt[j] % N;
						row_got = c_row[j*ROW_W +: ROW_W];
						if (tl >= nt) begin
							$display("ERROR: column %0d streamed an extra result", j);
							errors = errors + 1;
						end
						else begin
							if (row_got != row_exp) begin
								$display("ORDER FAIL col %0d: got row %0d, expected row %0d", j, row_got, row_exp);
								errors = errors + 1;
							end
							got[tl][row_got][j] = $signed(c_col[j*ACC_W +: ACC_W]);
						end
						got_cnt[j] = got_cnt[j] + 1;
					end
			end

			if (seen_done != nt) begin
				$display("ERROR: expected %0d done pulse(s), saw %0d", nt, seen_done);
				errors = errors + 1;
			end
			for (j = 0; j < N; j = j + 1)
				if (got_cnt[j] != nt*N) begin
					$display("ERROR: column %0d streamed %0d results, expected %0d", j, got_cnt[j], nt*N);
					errors = errors + 1;
				end

			for (tl = 0; tl < nt; tl = tl + 1) begin
				for (i = 0; i < N; i = i + 1)
					for (j = 0; j < N; j = j + 1)
						if (got[tl][i][j] != gold[tl][i][j]) begin
							$display("RESULT FAIL tile %0d c[%0d][%0d] = %0d, expected %0d",
							         tl, i, j, got[tl][i][j], gold[tl][i][j]);
							errors = errors + 1;
						end

				$display("");
				if (nt == 2) $display("--- tile %0d ---", tl);
				$display("C (streamed from array)     expected");
				for (i = 0; i < N; i = i + 1) begin
					for (j = 0; j < N; j = j + 1) $write("%6d", got[tl][i][j]);
					$write("    ");
					for (j = 0; j < N; j = j + 1) $write("%6d", gold[tl][i][j]);
					$display("");
				end
			end
		end
	endtask

	task check_order;
		integer i, j, r, idx;
		reg     ok;
		begin
			ok = 1'b1;
			$display("");
			$display("==================== ORDER CHECK ====================");
			$write("First active cycle of each PE   (");
			for (r = 0; r < NRUN; r = r + 1) $write("run %0d | ", r+1);
			$display("expected i+j)");
			for (i = 0; i < N; i = i + 1) begin
				for (r = 0; r < NRUN; r = r + 1) begin
					for (j = 0; j < N; j = j + 1) $write("%3d", first_cycle[r][i*N + j]);
					$write("   |");
				end
				for (j = 0; j < N; j = j + 1) $write("%3d", i + j);
				$display("");
			end

			$display("");
			$write("Active cycles of each PE   (");
			for (r = 0; r < NRUN; r = r + 1) begin
				$write("run %0d, K = %0d", r+1, run_k[r]);
				if (r < NRUN-1) $write(" | ");
			end
			$display(")");
			for (i = 0; i < N; i = i + 1) begin
				for (r = 0; r < NRUN; r = r + 1) begin
					for (j = 0; j < N; j = j + 1) $write("%3d", active_cnt[r][i*N + j]);
					if (r < NRUN-1) $write("   |");
				end
				$display("");
			end

			for (r = 0; r < NRUN; r = r + 1)
				for (idx = 0; idx < N*N; idx = idx + 1) begin
					if (first_cycle[r][idx] != idx/N + idx%N) begin
						$display("ORDER FAIL run %0d PE(%0d,%0d): started at %0d, expected %0d",
						         r+1, idx/N, idx%N, first_cycle[r][idx], idx/N + idx%N);
						ok = 1'b0;
					end
					if (active_cnt[r][idx] != run_k[r]) begin
						$display("COUNT FAIL run %0d PE(%0d,%0d): active %0d cycles, expected %0d",
						         r+1, idx/N, idx%N, active_cnt[r][idx], run_k[r]);
						ok = 1'b0;
					end
				end

			$display("");
			if (ok) $display("All runs: same diagonal order, every PE active for exactly its total K");
			else    errors = errors + 1;
		end
	endtask

	initial begin
		$timeformat(-9, 0, " ns", 7);
		$dumpfile("waveforms/systolic_activity.vcd");
		$dumpvars(0, tb_systolic_activity);
		rst_n = 1'b0; en = 1'b0; a = 0; b = 0;
		repeat (2) @(negedge clk);
		rst_n = 1'b1;
		repeat (3) @(negedge clk);

		run_tiles(0, 1, 4, 0);
		run_tiles(1, 1, 6, 0);
		run_tiles(2, 2, 5, 4);
		check_order;

		$display("");
		if (errors == 0) $display("PASS: enables, order, streamed results and back-to-back tiles all correct");
		else             $display("FAIL: %0d error(s)", errors);
		$finish;
	end
endmodule
