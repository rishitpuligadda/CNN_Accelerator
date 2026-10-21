`timescale 1ns/1ps

module tb_systolic_activity;
	parameter N     = 4;
	parameter WIDTH = 8;
	parameter KMAX  = 8;

	localparam ACC_W = 4*WIDTH;

	wire signed [N*N*ACC_W-1:0] c;
	wire        [N*N-1:0]       pe_done;
	wire                        done;
	reg  signed [N*WIDTH-1:0]   a, b;
	reg                         clk, rst_n;
	reg                         en;

	wire        [N*N-1:0]       pe_en;

	integer Am          [0:N-1][0:KMAX-1];
	integer Bm          [0:KMAX-1][0:N-1];
	integer gold        [0:N-1][0:N-1];
	integer first_cycle [0:1][0:N*N-1];
	integer active_cnt  [0:1][0:N*N-1];
	integer run_k       [0:1];
	integer errors = 0;

	systolic_array #(.TILE_MAX(N), .WIDTH(WIDTH)) dut (
		.c(c),
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

	task run_mult(input integer r, input integer k);
		integer t, i, j, kk, sum, total, idx, seen_done;
		reg     exp_en;
		begin
			run_k[r] = k;
			for (i = 0; i < N; i = i + 1)
				for (kk = 0; kk < k; kk = kk + 1) begin
					Am[i][kk] = $random % 10;
					Bm[kk][i] = $random % 10;
				end
			for (i = 0; i < N; i = i + 1)
				for (j = 0; j < N; j = j + 1) begin
					sum = 0;
					for (kk = 0; kk < k; kk = kk + 1)
						sum = sum + Am[i][kk] * Bm[kk][j];
					gold[i][j] = sum;
				end
			for (idx = 0; idx < N*N; idx = idx + 1) begin
				first_cycle[r][idx] = -1;
				active_cnt[r][idx]  = 0;
			end

			$display("");
			$display("============ MULTIPLICATION %0d: A (%0dx%0d) x B (%0dx%0d) = C (%0dx%0d) ============", r+1, N, k, k, N, N, N);
			$display("A =");
			for (i = 0; i < N; i = i + 1) begin
				for (kk = 0; kk < k; kk = kk + 1) $write("%5d", Am[i][kk]);
				$display("");
			end
			$display("B =");
			for (kk = 0; kk < k; kk = kk + 1) begin
				for (j = 0; j < N; j = j + 1) $write("%5d", Bm[kk][j]);
				$display("");
			end
			$display("");
			$display("PE activity (row 0 | row 1 | row 2 | row 3)   # = en high   D = done pulse   . = idle   ! = wrong");

			seen_done = 0;
			total     = k + 2*N + 1;

			for (t = 0; t < total; t = t + 1) begin
				@(negedge clk);
				en = (t < k);
				for (i = 0; i < N; i = i + 1) begin
					if (t-i >= 0 && t-i < k) b[i*WIDTH +: WIDTH] = Am[i][t-i][WIDTH-1:0];
					else                     b[i*WIDTH +: WIDTH] = {WIDTH{1'b0}};
					if (t-i >= 0 && t-i < k) a[i*WIDTH +: WIDTH] = Bm[t-i][i][WIDTH-1:0];
					else                     a[i*WIDTH +: WIDTH] = {WIDTH{1'b0}};
				end
				#1;

				$write("t=%t  cycle %2d  en=%b |", $time, t, en);
				for (i = 0; i < N; i = i + 1) begin
					$write(" ");
					for (j = 0; j < N; j = j + 1) begin
						idx    = i*N + j;
						exp_en = (t >= i+j) && (t < i+j+k);
						if (pe_en[idx] !== exp_en) begin
							$write("!");
							errors = errors + 1;
						end
						else if (pe_en[idx]) $write("#");
						else if (pe_done[idx]) $write("D");
						else $write(".");
						if (pe_en[idx]) begin
							if (first_cycle[r][idx] < 0) first_cycle[r][idx] = t;
							active_cnt[r][idx] = active_cnt[r][idx] + 1;
						end
					end
					$write(" |");
				end
				if (done) $write("  <- done, results captured");
				$display("");

				if (done) begin
					seen_done = seen_done + 1;
					for (i = 0; i < N; i = i + 1)
						for (j = 0; j < N; j = j + 1)
							if (c[(i*N + j)*ACC_W +: ACC_W] != gold[i][j]) begin
								$display("RESULT FAIL c[%0d][%0d] = %0d, expected %0d", i, j, $signed(c[(i*N + j)*ACC_W +: ACC_W]), gold[i][j]);
								errors = errors + 1;
							end
				end
			end

			if (seen_done != 1) begin
				$display("ERROR: expected 1 done pulse, saw %0d", seen_done);
				errors = errors + 1;
			end

			$display("");
			$display("C (from array)              expected");
			for (i = 0; i < N; i = i + 1) begin
				for (j = 0; j < N; j = j + 1) $write("%6d", $signed(c[(i*N + j)*ACC_W +: ACC_W]));
				$write("    ");
				for (j = 0; j < N; j = j + 1) $write("%6d", gold[i][j]);
				$display("");
			end
		end
	endtask

	task check_order;
		integer i, j, idx;
		reg     ok;
		begin
			ok = 1'b1;
			$display("");
			$display("==================== ORDER CHECK ====================");
			$display("First active cycle of each PE   (run 1 | run 2 | expected i+j)");
			for (i = 0; i < N; i = i + 1) begin
				for (j = 0; j < N; j = j + 1) $write("%3d", first_cycle[0][i*N + j]);
				$write("   |");
				for (j = 0; j < N; j = j + 1) $write("%3d", first_cycle[1][i*N + j]);
				$write("   |");
				for (j = 0; j < N; j = j + 1) $write("%3d", i + j);
				$display("");
			end
			$display("");
			$display("Active cycles of each PE   (run 1, K = %0d | run 2, K = %0d)", run_k[0], run_k[1]);
			for (i = 0; i < N; i = i + 1) begin
				for (j = 0; j < N; j = j + 1) $write("%3d", active_cnt[0][i*N + j]);
				$write("   |");
				for (j = 0; j < N; j = j + 1) $write("%3d", active_cnt[1][i*N + j]);
				$display("");
			end
			for (idx = 0; idx < N*N; idx = idx + 1) begin
				if (first_cycle[0][idx] != idx/N + idx%N || first_cycle[1][idx] != first_cycle[0][idx]) begin
					$display("ORDER FAIL PE(%0d,%0d): run 1 started at %0d, run 2 at %0d, expected %0d",
					         idx/N, idx%N, first_cycle[0][idx], first_cycle[1][idx], idx/N + idx%N);
					ok = 1'b0;
				end
				if (active_cnt[0][idx] != run_k[0] || active_cnt[1][idx] != run_k[1]) begin
					$display("COUNT FAIL PE(%0d,%0d): active %0d / %0d cycles, expected %0d / %0d",
					         idx/N, idx%N, active_cnt[0][idx], active_cnt[1][idx], run_k[0], run_k[1]);
					ok = 1'b0;
				end
			end
			$display("");
			if (ok) $display("Both runs: same diagonal order, every PE active for exactly K cycles (%0d, then %0d)", run_k[0], run_k[1]);
			else    errors = errors + 1;
		end
	endtask

	initial begin
		$timeformat(-9, 0, " ns", 7);
		$dumpfile("systolic_activity.vcd");
		$dumpvars(0, tb_systolic_activity);
		rst_n = 1'b0; en = 1'b0; a = 0; b = 0;
		repeat (2) @(negedge clk);
		rst_n = 1'b1;
		repeat (3) @(negedge clk);

		run_mult(0, 4);
		run_mult(1, 6);
		check_order;

		$display("");
		if (errors == 0) $display("PASS: enables, order and results all correct");
		else             $display("FAIL: %0d error(s)", errors);
		$finish;
	end
endmodule
