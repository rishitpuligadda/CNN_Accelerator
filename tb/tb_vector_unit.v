`timescale 1ns/1ps

module tb_vector_unit;
	localparam LANES = 4;
	localparam ADDR  = 11;
	localparam NPKT  = 400;
	localparam QMAX  = 4096;

	reg                    clk, rst_n;
	reg                    pm_we;
	reg  [5:0]             pm_waddr;
	reg  [31:0]            pm_wdata;
	reg  [5:0]             pro_start, body_start, epi_start;
	reg  [6:0]             pro_len, body_len, epi_len;
	reg                    layer_start, layer_end;
	wire                   busy, done;
	wire                   pkt_valid, pkt_ready;
	wire [LANES*32-1:0]    pkt_data;
	wire [ADDR-1:0]        pkt_addr;
	wire [LANES-1:0]       pkt_be;
	wire                   st_en;
	wire [ADDR-1:0]        st_addr;
	wire [LANES-1:0]       st_be;
	wire [LANES*8-1:0]     st_data;

	reg  [LANES*32-1:0]    p_data [0:NPKT-1];
	reg  [ADDR-1:0]        p_addr [0:NPKT-1];
	reg  [LANES-1:0]       p_be   [0:NPKT-1];
	integer                p_idx, n_pkts, avail_pct;
	reg                    avail;

	reg  [ADDR-1:0]        e_addr [0:QMAX-1];
	reg  [LANES-1:0]       e_be   [0:QMAX-1];
	reg  [LANES*8-1:0]     e_data [0:QMAX-1];
	reg  [LANES*32-1:0]    e_in   [0:QMAX-1];
	reg  [LANES*32-1:0]    e_mid  [0:QMAX-1];
	integer                e_kind [0:QMAX-1];
	integer                e_pkt  [0:QMAX-1];
	integer                show_left, fdo;
	integer                e_head, e_tail, errors, stores, cyc, prog;

	reg  signed [31:0]     sum_r [0:LANES-1];
	integer                t_first, t_last;

	vector_unit #(.LANES(LANES), .ADDR(ADDR), .PM_AW(6)) dut (
		.clk(clk), .rst_n(rst_n),
		.pm_we(pm_we), .pm_waddr(pm_waddr), .pm_wdata(pm_wdata),
		.pro_start(pro_start), .pro_len(pro_len), .body_start(body_start), .body_len(body_len),
		.epi_start(epi_start), .epi_len(epi_len),
		.layer_start(layer_start), .layer_end(layer_end), .busy(busy), .done(done),
		.pkt_valid(pkt_valid), .pkt_ready(pkt_ready), .pkt_data(pkt_data), .pkt_addr(pkt_addr), .pkt_be(pkt_be),
		.st_en(st_en), .st_addr(st_addr), .st_be(st_be), .st_data(st_data)
	);

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

	always @(posedge clk) cyc <= cyc + 1;

	// ---------------------------------------------------------------- assembler
	function [18:0] f19(input integer v);
		begin
			if (v < -262144 || v > 262143) $fatal(1, "assembler: immediate %0d does not fit 19 bits", v);
			f19 = v[18:0];
		end
	endfunction
	function [15:0] f16(input integer v);
		begin
			if (v < 0 || v > 65535) $fatal(1, "assembler: immediate %0d does not fit 16 bits", v);
			f16 = v[15:0];
		end
	endfunction
	function [14:0] f15(input integer v);
		begin
			if (v < -16384 || v > 32767) $fatal(1, "assembler: immediate %0d does not fit 15 bits", v);
			f15 = v[14:0];
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
	function [31:0] LI(input [3:0] d, input integer imm);    LI    = {6'h01, 3'b000, d, f19(imm)};          endfunction
	function [31:0] LUI(input [3:0] d, input integer imm);   LUI   = {6'h02, 3'b000, d, 3'b000, f16(imm)};  endfunction
	function [31:0] ORI(input [3:0] d, input integer imm);   ORI   = {6'h03, 3'b000, d, 3'b000, f16(imm)};  endfunction
	function [31:0] TAG(input [3:0] d, input integer f);     TAG   = enc(6'h08, d, 4'd0, 4'd0, f11(f));     endfunction
	function [31:0] SETQ(input [3:0] q, input [3:0] a, input [3:0] b, input integer s); SETQ = enc(6'h09, q, a, b, f11(s)); endfunction
	function [31:0] SETC(input [3:0] c, input [3:0] a, input [3:0] b); SETC = enc(6'h0A, c, a, b, 11'd0); endfunction
	function [31:0] MOV(input [3:0] d, input [3:0] a);       MOV   = enc(6'h10, d, a, 4'd0, 11'd0);          endfunction
	function [31:0] VLI(input [3:0] d, input integer imm);   VLI   = {6'h11, 3'b000, d, 4'd0, f15(imm)};    endfunction
	function [31:0] BCAST(input [3:0] d, input [3:0] a);     BCAST = enc(6'h12, d, a, 4'd0, 11'd0);          endfunction
	function [31:0] ADD(input [3:0] d, input [3:0] a, input [3:0] b); ADD = enc(6'h18, d, a, b, 11'd0);     endfunction
	function [31:0] SUB(input [3:0] d, input [3:0] a, input [3:0] b); SUB = enc(6'h19, d, a, b, 11'd0);     endfunction
	function [31:0] ADDI(input [3:0] d, input [3:0] a, input integer imm); ADDI = {6'h1A, 3'b000, d, a, f15(imm)}; endfunction
	function [31:0] MAX(input [3:0] d, input [3:0] a, input [3:0] b); MAX = enc(6'h1B, d, a, b, 11'd0);     endfunction
	function [31:0] MIN(input [3:0] d, input [3:0] a, input [3:0] b); MIN = enc(6'h1C, d, a, b, 11'd0);     endfunction
	function [31:0] SHL(input [3:0] d, input [3:0] a, input integer n);  SHL  = enc(6'h1D, d, a, 4'd0, f11(n)); endfunction
	function [31:0] SHR(input [3:0] d, input [3:0] a, input integer n);  SHR  = enc(6'h1E, d, a, 4'd0, f11(n)); endfunction
	function [31:0] SHRR(input [3:0] d, input [3:0] a, input integer n); SHRR = enc(6'h1F, d, a, 4'd0, f11(n)); endfunction
	function [31:0] MUL(input [3:0] d, input [3:0] a, input [3:0] b); MUL = enc(6'h20, d, a, b, 11'd0);     endfunction
	function [31:0] REQ(input [3:0] d, input [3:0] a, input integer q);   REQ   = enc(6'h21, d, a, 4'd0, f11(q)); endfunction
	function [31:0] CLAMP(input [3:0] d, input [3:0] a, input integer c); CLAMP = enc(6'h22, d, a, 4'd0, f11(c)); endfunction
	function [31:0] ST8(input [3:0] a, input integer c);     ST8   = enc(6'h38, 4'd0, a, 4'd0, f11(c));     endfunction

	// ---------------------------------------------------------------- reference arithmetic (the spec, in 64 bits)
	function signed [31:0] sat32(input signed [63:0] x);
		begin
			if (x > 64'sd2147483647)       sat32 = 32'sh7FFFFFFF;
			else if (x < -64'sd2147483648) sat32 = 32'sh80000000;
			else                           sat32 = x[31:0];
		end
	endfunction
	function signed [31:0] req(input signed [31:0] a, input signed [15:0] mp, input signed [15:0] mn, input integer s);
		reg signed [63:0] y;
		begin
			y = (a < 0) ? $signed(a) * mn : $signed(a) * mp;
			if (s != 0) y = (y >>> s) + ((y >>> (s - 1)) & 64'sd1);
			req = sat32(y);
		end
	endfunction
	function signed [31:0] clampv(input signed [31:0] a, input signed [31:0] l, input signed [31:0] h);
		reg signed [31:0] c;
		begin
			c = (a > l) ? a : l;
			clampv = (c < h) ? c : h;
		end
	endfunction
	function [7:0] st8b(input signed [31:0] a, input signed [31:0] l, input signed [31:0] h);
		reg signed [31:0] c;
		begin
			c = clampv(a, l, h);
			c = (c < -128) ? -32'sd128 : ((c > 127) ? 32'sd127 : c);
			st8b = c[7:0];
		end
	endfunction
	function signed [31:0] shrr(input signed [31:0] a, input integer n);
		reg signed [63:0] w;
		begin
			w = {{32{a[31]}}, a};
			if (n == 0) shrr = a;
			else begin
				w = (w >>> n) + ((w >>> (n - 1)) & 64'sd1);
				shrr = w[31:0];
			end
		end
	endfunction

	// ---------------------------------------------------------------- expected stores for each program
	localparam M1 = 15521, S1 = 22;

	task push_store(input [ADDR-1:0] ad, input [LANES-1:0] be, input [LANES*8-1:0] d,
	                input [LANES*32-1:0] din, input [LANES*32-1:0] mid, input integer kind, input integer pn);
		begin
			e_addr[e_tail] = ad;
			e_be[e_tail]   = be;
			e_data[e_tail] = d;
			e_in[e_tail]   = din;
			e_mid[e_tail]  = mid;
			e_kind[e_tail] = kind;
			e_pkt[e_tail]  = pn;
			e_tail = e_tail + 1;
		end
	endtask

	task expect_packet(input integer n);
		integer i;
		reg signed [31:0] x, v1, v2, v6;
		reg [LANES*8-1:0] w1, w2;
		reg [LANES*32-1:0] m1, m2;
		begin
			if (n < 0 || n >= NPKT) $fatal(1, "expect_packet: bad packet index");
			for (i = 0; i < LANES; i = i + 1) begin
				x = p_data[n][i*32 +: 32];
				case (prog)
					1: begin
						m1[i*32 +: 32] = req(x, M1, 0, S1);
						w1[i*8 +: 8]   = st8b(m1[i*32 +: 32], -128, 127);
					end
					2: begin
						m1[i*32 +: 32] = req(x, M1, M1 / 8, S1);
						w1[i*8 +: 8]   = st8b(m1[i*32 +: 32], -128, 50);
					end
					default: begin
						v1 = x + 5;
						v2 = v1 * 3;
						v2 = shrr(v2, 3);
						v2 = (v2 > -50) ? v2 : -50;
						v6 = v2 - x;
						v6 = (v6 < v2) ? v6 : v2;
						v6 = v6 <<< 1;
						v6 = v6 >>> 1;
						sum_r[i] = sum_r[i] + x;
						v6 = v6 + {21'd0, p_addr[n]};
						v6 = req(v6, 300, -200, 10);
						m1[i*32 +: 32] = v6;
						v6 = clampv(v6, -100, 100);
						w1[i*8 +: 8] = st8b(v6, -100, 100);
						m2[i*32 +: 32] = sum_r[i];
						w2[i*8 +: 8] = st8b(sum_r[i], 32'sh80000000, 32'sh7FFFFFFF);
					end
				endcase
			end
			push_store(p_addr[n], p_be[n], w1, p_data[n], m1, (prog == 3) ? 3 : 1, n);
			if (prog == 3) push_store(p_addr[n], p_be[n], w2, p_data[n], m2, 4, n);
		end
	endtask

	// ---------------------------------------------------------------- packet source and store monitor
	assign pkt_valid = avail && (p_idx < n_pkts);
	assign pkt_data  = p_data[(p_idx < NPKT) ? p_idx : 0];
	assign pkt_addr  = p_addr[(p_idx < NPKT) ? p_idx : 0];
	assign pkt_be    = p_be[(p_idx < NPKT) ? p_idx : 0];

	reg took;

	initial begin
		took = 1'b0;
		forever begin
			@(posedge clk);
			took = pkt_valid && pkt_ready;
			if (took) begin
				if (p_idx == 0) t_first = cyc;
				expect_packet(p_idx);
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
				t_last = cyc;
				if (e_head == e_tail) begin
					errors = errors + 1;
					$display("FAIL t=%0t: unexpected store at %0d", $time, st_addr);
				end
				else begin
					if (st_addr !== e_addr[e_head] || st_be !== e_be[e_head] || st_data !== e_data[e_head]) begin
						errors = errors + 1;
						if (errors <= 10)
							$display("FAIL t=%0t: store addr=%0d be=%b data=%h, expected addr=%0d be=%b data=%h",
							         $time, st_addr, st_be, st_data, e_addr[e_head], e_be[e_head], e_data[e_head]);
					end
					show_store;
					e_head = e_head + 1;
				end
			end
		end
	end

	task show_store;
		integer i;
		reg signed [31:0] x, m;
		reg signed [7:0]  hb, eb;
		begin
			$fwrite(fdo, "prog %0d store %0d (packet %0d) addr %0d be %b: hw", prog, stores, e_pkt[e_head], st_addr, st_be);
			for (i = 0; i < LANES; i = i + 1) $fwrite(fdo, " %4d", $signed(st_data[i*8 +: 8]));
			$fwrite(fdo, "   expected");
			for (i = 0; i < LANES; i = i + 1) $fwrite(fdo, " %4d", $signed(e_data[e_head][i*8 +: 8]));
			$fdisplay(fdo, "%0s", (st_data === e_data[e_head]) ? "" : "   MISMATCH");
			if (show_left > 0) begin
				show_left = show_left - 1;
				case (e_kind[e_head])
					1: $display("    packet %0d (addr %0d, be %b):", e_pkt[e_head], st_addr, st_be);
					3: $display("    packet %0d (addr %0d, be %b), first store (the computed chain, clamped to -100..100):",
					            e_pkt[e_head], st_addr, st_be);
					4: $display("    packet %0d, second store (running sum of all packets so far, saturated to int8):",
					            e_pkt[e_head]);
					default: $display("    epilogue store (final running sum, clamped to -100..100):");
				endcase
				for (i = 0; i < LANES; i = i + 1) begin
					x  = e_in[e_head][i*32 +: 32];
					m  = e_mid[e_head][i*32 +: 32];
					hb = st_data[i*8 +: 8];
					eb = e_data[e_head][i*8 +: 8];
					case (e_kind[e_head])
						1: $display("      lane %0d: acc %9d  x M / 2^S = %10.3f  -> REQ %6d  -> clamp/int8: hw %4d, expected %4d",
						            i, x, $itor(x) * $itor((x < 0 && prog == 2) ? M1 / 8 : ((x < 0) ? 0 : M1)) / (2.0 ** S1) + 0.0,
						            m, hb, eb);
						3: $display("      lane %0d: input %9d  -> chain result %8d  -> hw %4d, expected %4d", i, x, m, hb, eb);
						default: $display("      lane %0d: running sum %10d  -> hw %4d, expected %4d", i, m, hb, eb);
					endcase
				end
			end
		end
	endtask

	// ---------------------------------------------------------------- program loading and running
	reg [31:0] prg [0:63];
	integer    np;

	task load_program(input integer pro_n, input integer body_n, input integer epi_n);
		integer i;
		begin
			for (i = 0; i < pro_n + body_n + epi_n; i = i + 1) begin
				@(negedge clk);
				pm_we    = 1'b1;
				pm_waddr = i[5:0];
				pm_wdata = prg[i];
			end
			@(negedge clk);
			pm_we      = 1'b0;
			pro_start  = 6'd0;
			pro_len    = pro_n[6:0];
			body_start = pro_n[5:0];
			body_len   = body_n[6:0];
			epi_start  = 6'(pro_n + body_n);
			epi_len    = epi_n[6:0];
		end
	endtask

	task make_packets(input integer n, input integer range);
		integer i, j;
		begin
			for (i = 0; i < n; i = i + 1) begin
				for (j = 0; j < LANES; j = j + 1) p_data[i][j*32 +: 32] = $random % range;
				p_addr[i] = ADDR'($random);
				p_be[i]   = (({$random} % 4) == 0) ? LANES'($random) : {LANES{1'b1}};
			end
			n_pkts = n;
		end
	endtask

	task run_layer(input [8*48:1] name, input integer n, input integer range, input integer pct);
		integer t0, e0, i;
		begin
			make_packets(n, range);
			for (i = 0; i < LANES; i = i + 1) sum_r[i] = 0;
			p_idx = 0;
			avail_pct = pct;
			e0 = errors;
			t0 = stores;
			@(negedge clk);
			layer_start = 1'b1;
			@(negedge clk);
			layer_start = 1'b0;
			if (!busy) begin
				errors = errors + 1;
				$display("FAIL: busy not high after layer_start");
			end
			while (p_idx < n_pkts) @(negedge clk);
			if (prog == 3) begin
				for (i = 0; i < LANES; i = i + 1) begin
					e_data[e_tail][i*8 +: 8]  = st8b(sum_r[i], -100, 100);
					e_mid[e_tail][i*32 +: 32] = sum_r[i];
				end
				e_in[e_tail]   = {(LANES*32){1'b0}};
				e_kind[e_tail] = 5;
				e_pkt[e_tail]  = n;
				e_addr[e_tail] = p_addr[n - 1];
				e_be[e_tail]   = p_be[n - 1];
				e_tail = e_tail + 1;
			end
			layer_end = 1'b1;
			@(negedge clk);
			layer_end = 1'b0;
			i = 0;
			while (!done) begin
				@(negedge clk);
				i = i + 1;
				if (i > 100000) $fatal(1, "done never arrived");
			end
			repeat (3) @(negedge clk);
			if (busy) begin
				errors = errors + 1;
				$display("FAIL: busy still high after done");
			end
			$display("  %0s: %0d packets, %0d stores, %0d errors%0s", name, n, stores - t0, errors - e0,
			         (pct == 100) ? "" : " (packets arrive irregularly)");
		end
	endtask

	initial begin
		$dumpfile("waveforms/vector_unit.vcd");
		$dumpvars(0, tb_vector_unit);

		fdo = $fopen("outputs/vector_unit_outputs.txt", "w");
		show_left = 0;
		errors = 0; stores = 0; cyc = 0; e_head = 0; e_tail = 0; p_idx = 0; n_pkts = 0; avail_pct = 100; avail = 1'b1;
		prog = 0; t_first = 0; t_last = 0;
		pm_we = 1'b0; pm_waddr = 0; pm_wdata = 0;
		pro_start = 0; pro_len = 0; body_start = 0; body_len = 0; epi_start = 0; epi_len = 0;
		layer_start = 1'b0; layer_end = 1'b0;
		for (np = 0; np < NPKT; np = np + 1) begin
			p_data[np] = 0; p_addr[np] = 0; p_be[np] = 0;
		end

		rst_n = 1'b0;
		repeat (2) @(negedge clk);
		rst_n = 1'b1;

		$display("");
		$display("vector_unit: LANES=%0d, programs assembled in the testbench, every store checked", LANES);

		$display("");
		$display("1) Requantize + ReLU (M = %0d, S = %0d, i.e. scale 0.0037):", M1, S1);
		$display("     prologue: LI s1,M  LI s2,0  SETQ q0,s1,s2,S  LI s3,-128  LI s4,127  SETC c0,s3,s4");
		$display("     body:     REQ v0,v7,q0   ST8 v0,c0");
		prog = 1;
		prg[0] = LI(1, M1); prg[1] = LI(2, 0); prg[2] = SETQ(0, 1, 2, S1);
		prg[3] = LI(3, -128); prg[4] = LI(4, 127); prg[5] = SETC(0, 3, 4);
		prg[6] = REQ(0, 7, 0); prg[7] = ST8(0, 0);
		load_program(6, 2, 0);
		show_left = 3;
		run_layer("ReLU, packets always ready        ", NPKT, 100000, 100);
		$display("     %0d cycles for %0d packets = %0.2f cycles per packet (2 instructions + 1 wait for REQ)",
		         t_last - t_first, NPKT, $itor(t_last - t_first) / NPKT);
		run_layer("ReLU                              ", NPKT, 100000, 30);

		$display("");
		$display("2) Leaky ReLU (M_neg = M/8) with a low clamp (hi = 50, like ReLU6 in the output scale):");
		prog = 2;
		prg[1] = LI(2, M1 / 8); prg[4] = LI(4, 50);
		load_program(6, 2, 0);
		show_left = 3;
		run_layer("Leaky + clamp                     ", NPKT, 100000, 100);
		run_layer("Leaky + clamp                     ", NPKT, 100000, 40);

		$display("");
		$display("3) Every phase-2 instruction, chained dependencies, a running sum kept across packets,");
		$display("   two stores per packet, and an epilogue store of the final sum:");
		prog = 3;
		np = 0;
		prg[np] = VLI(3, 3);            np = np + 1;
		prg[np] = VLI(4, -50);          np = np + 1;
		prg[np] = VLI(5, 0);            np = np + 1;
		prg[np] = LUI(2, 1);            np = np + 1;
		prg[np] = ORI(2, 5);            np = np + 1;
		prg[np] = LUI(8, 32768);     np = np + 1;
		prg[np] = LUI(9, 32767);     np = np + 1;
		prg[np] = ORI(9, 65535);     np = np + 1;
		prg[np] = SETC(0, 8, 9);        np = np + 1;
		prg[np] = LI(3, -100);          np = np + 1;
		prg[np] = LI(4, 100);           np = np + 1;
		prg[np] = SETC(1, 3, 4);        np = np + 1;
		prg[np] = LI(5, 300);           np = np + 1;
		prg[np] = LI(6, -200);          np = np + 1;
		prg[np] = SETQ(1, 5, 6, 10);    np = np + 1;
		prg[np] = ADDI(1, 7, 5);        np = np + 1;
		prg[np] = MUL(2, 1, 3);         np = np + 1;
		prg[np] = SHRR(2, 2, 3);        np = np + 1;
		prg[np] = MAX(2, 2, 4);         np = np + 1;
		prg[np] = SUB(6, 2, 7);         np = np + 1;
		prg[np] = MIN(6, 6, 2);         np = np + 1;
		prg[np] = SHL(6, 6, 1);         np = np + 1;
		prg[np] = SHR(6, 6, 1);         np = np + 1;
		prg[np] = ADD(5, 5, 7);         np = np + 1;
		prg[np] = TAG(7, 0);            np = np + 1;
		prg[np] = BCAST(1, 7);          np = np + 1;
		prg[np] = ADD(6, 6, 1);         np = np + 1;
		prg[np] = REQ(6, 6, 1);         np = np + 1;
		prg[np] = CLAMP(6, 6, 1);       np = np + 1;
		prg[np] = MOV(2, 6);            np = np + 1;
		prg[np] = ST8(2, 1);            np = np + 1;
		prg[np] = ST8(5, 0);            np = np + 1;
		prg[np] = ST8(5, 1);            np = np + 1;
		load_program(15, 17, 1);
		show_left = 4;
		run_layer("all instructions                  ", 120, 3000, 100);
		run_layer("all instructions                  ", 120, 3000, 50);

		repeat (5) @(negedge clk);
		$display("");
		$fclose(fdo);
		$display("   every store (hardware and expected bytes) is listed in outputs/vector_unit_outputs.txt");
		$display("4) Totals: %0d stores checked, %0d expected stores never happened, %0d errors", stores, e_tail - e_head, errors);
		$display("");
		if (e_head != e_tail) errors = errors + 1;
		if (errors != 0) $fatal(1, "FAIL: %0d error(s)", errors);
		$display("PASS: every store matches the reference");
		$finish;
	end
endmodule
