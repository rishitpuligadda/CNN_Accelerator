`timescale 1ns/1ps

module tb_vu_pred;
	localparam LANES = 4;
	localparam ADDR  = 11;
	localparam W     = LANES * 32;
	localparam NPKT  = 256;
	localparam NPROG = 400;

	reg                 clk, rst_n;
	reg                 lut_we_tb = 1'b0;
	reg  [7:0]          lut_wa_tb = 8'd0;
	reg  [15:0]         lut_wd_tb = 16'd0;
	reg                 pm_we;
	reg  [5:0]          pm_waddr;
	reg  [31:0]         pm_wdata;
	reg  [5:0]          pro_start, body_start, epi_start;
	reg  [6:0]          pro_len, body_len, epi_len;
	reg                 layer_start, layer_end;
	wire                unused_busy, done;
	wire                pkt_valid, pkt_ready;
	wire                st_en;
	wire [ADDR-1:0]     st_addr;
	wire [LANES-1:0]    st_be;
	wire [LANES*8-1:0]  st_data;

	reg  [ADDR-1:0]     p_addr [0:NPKT-1];
	reg  [LANES-1:0]    p_be   [0:NPKT-1];
	reg  [7:0]          p_row  [0:NPKT-1];
	reg  [7:0]          p_col  [0:NPKT-1];
	reg  [7:0]          p_chan [0:NPKT-1];
	reg                 p_last [0:NPKT-1];
	integer             p_idx, n_pkts;
	reg                 avail;
	wire [7:0]          pi = (p_idx < NPKT) ? p_idx[7:0] : 8'd0;

	vector_unit #(.LANES(LANES), .ADDR(ADDR), .PM_AW(6)) dut (
		.clk(clk), .rst_n(rst_n),
		.pm_we(pm_we), .pm_waddr(pm_waddr), .pm_wdata(pm_wdata),
		.lut_we(lut_we_tb), .lut_waddr(lut_wa_tb), .lut_wdata(lut_wd_tb),
		.pro_start(pro_start), .pro_len(pro_len), .body_start(body_start), .body_len(body_len),
		.epi_start(epi_start), .epi_len(epi_len),
		.layer_start(layer_start), .layer_end(layer_end), .busy(unused_busy), .done(done),
		.pkt_valid(pkt_valid), .pkt_ready(pkt_ready),
		.pkt_data({W{1'b0}}), .pkt_addr(p_addr[pi]), .pkt_be(p_be[pi]),
		.pkt_row(p_row[pi]), .pkt_col(p_col[pi]), .pkt_chan(p_chan[pi]), .pkt_last(p_last[pi]),
		.st_en(st_en), .st_addr(st_addr), .st_be(st_be), .st_data(st_data)
	);

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

	// ---------------------------------------------------------------- the predicate table under test
	reg [2:0] cfg_tag [2:7];
	reg [1:0] cfg_op  [2:7];
	reg [9:0] cfg_val [2:7];

	function [10:0] tagval(input integer n, input [2:0] t);
		if (n < 0 || n >= NPKT) $fatal(1, "bad packet index");
		else case (t)
			3'd0:    tagval = p_addr[n];
			3'd1:    tagval = {7'd0, p_be[n]};
			3'd2:    tagval = {3'd0, p_row[n]};
			3'd3:    tagval = {3'd0, p_col[n]};
			3'd4:    tagval = {3'd0, p_chan[n]};
			3'd5:    tagval = {10'd0, p_last[n]};
			default: tagval = 11'd0;
		endcase
	endfunction

	// The spec (v0.6, section 6), written out independently of the RTL.
	function ref_pred(input integer n, input integer p);
		reg [10:0] t, kmask, v;
		begin
			t     = tagval(n, cfg_tag[p]);
			kmask = (11'd1 << cfg_val[p][9:6]) - 11'd1;
			v     = {5'd0, cfg_val[p][5:0]};
			case (cfg_op[p])
				2'd0:    ref_pred = (t == {1'b0, cfg_val[p]});
				2'd1:    ref_pred = (t != {1'b0, cfg_val[p]});
				2'd2:    ref_pred = ((t & kmask) == (v & kmask));
				default: ref_pred = ((t & kmask) != (v & kmask));
			endcase
		end
	endfunction

	function [5:0] ref_bits(input integer n);
		integer p;
		begin
			ref_bits = 6'd0;
			for (p = 2; p < 8; p = p + 1) ref_bits[p-2] = ref_pred(n, p);
		end
	endfunction

	// ---------------------------------------------------------------- program
	function [31:0] enc(input [5:0] op, input [2:0] pr, input [3:0] d, input [3:0] a, input [3:0] b, input [10:0] x);
		enc = {op, pr, d, a, b, x};
	endfunction

	reg [31:0] prg [0:63];
	integer    np;

	task build_program;
		integer p;
		begin
			np = 0;
			prg[np] = {6'h01, 3'b000, 4'd3, 19'h7FF80}; np = np + 1;       // LI s3, -128
			prg[np] = {6'h01, 3'b000, 4'd4, 19'd127};   np = np + 1;       // LI s4, 127
			prg[np] = enc(6'h0A, 3'd0, 4'd0, 4'd3, 4'd4, 11'd0); np = np + 1;   // SETC c0, s3, s4
			for (p = 2; p < 8; p = p + 1) begin                             // SETP p, tag, op, val
				prg[np] = enc(6'h0C, 3'd0, p[3:0], 4'd0, cfg_val[p][9:6], {cfg_val[p][5:0], cfg_op[p], cfg_tag[p]});
				np = np + 1;
			end
			pro_len = np[6:0];
			prg[np] = enc(6'h11, 3'd0, 4'd0, 4'd0, 4'd0, 11'd0); np = np + 1;   // VLI v0, 0
			for (p = 2; p < 8; p = p + 1) begin                             // [p] ADDI v0, v0, 1 << (p-2)
				prg[np] = enc(6'h1A, p[2:0], 4'd0, 4'd0, 4'd0, 11'(1 << (p - 2)));
				np = np + 1;
			end
			prg[np] = enc(6'h38, 3'd0, 4'd0, 4'd0, 4'd0, 11'd0); np = np + 1;   // ST8 v0, c0
		end
	endtask

	task load_program;
		integer i;
		begin
			for (i = 0; i < np; i = i + 1) begin
				@(negedge clk);
				pm_we    = 1'b1;
				pm_waddr = i[5:0];
				pm_wdata = prg[i];
			end
			@(negedge clk);
			pm_we      = 1'b0;
			pro_start  = 6'd0;
			body_start = pro_len[5:0];
			body_len   = 7'(np) - pro_len;
			epi_start  = 6'd0;
			epi_len    = 7'd0;
		end
	endtask

	// ---------------------------------------------------------------- random configurations and packets, biased to edges
	reg [7:0] edge8 [0:15];

	function [7:0] rnd8(input integer unused);
		rnd8 = (({$random} % 3) != 0) ? edge8[{$random} % 16] : 8'($random + unused);
	endfunction

	task make_packets(input integer n);
		integer i;
		begin
			for (i = 0; i < n; i = i + 1) begin
				case ({$random} % 5)
					0:       p_addr[i] = 11'd0;
					1:       p_addr[i] = 11'h7FF;
					2:       p_addr[i] = {3'd0, rnd8(0)};
					default: p_addr[i] = 11'($random);
				endcase
				p_be[i]   = LANES'($random);
				p_row[i]  = rnd8(0);
				p_col[i]  = rnd8(0);
				p_chan[i] = rnd8(0);
				p_last[i] = ({$random} % 2) == 1;
			end
			n_pkts = n;
		end
	endtask

	task make_config;
		integer p, src;
		reg [3:0]  k;
		reg [10:0] t;
		begin
			for (p = 2; p < 8; p = p + 1) begin
				cfg_tag[p] = 3'({$random} % 8);
				cfg_op[p]  = 2'($random);
				src = {$random} % n_pkts;
				t   = tagval(src, cfg_tag[p]);
				if (cfg_op[p] < 2) begin
					case ({$random} % 3)
						0:       cfg_val[p] = (t[10] == 1'b0) ? t[9:0] : t[9:0];
						1:       cfg_val[p] = 10'({$random} % 4);
						default: cfg_val[p] = 10'($random);
					endcase
				end
				else begin
					k = (({$random} % 2) == 1) ? 4'({$random} % 5) : 4'($random);
					case ({$random} % 3)
						0:       cfg_val[p] = {k, t[5:0]};
						1:       cfg_val[p] = {k, 6'({$random} % 4)};
						default: cfg_val[p] = {k, 6'($random)};
					endcase
				end
			end
		end
	endtask

	function [8*14:1] tagname(input [2:0] t);
		case (t)
			3'd0: tagname = "addr";  3'd1: tagname = "be";   3'd2: tagname = "row";  3'd3: tagname = "col";
			3'd4: tagname = "chan";  3'd5: tagname = "last"; default: tagname = "(none: 0)";
		endcase
	endfunction

	task show_config;
		integer p;
		begin
			for (p = 2; p < 8; p = p + 1)
				case (cfg_op[p])
					2'd0: $display("      P%0d: %0s == %0d", p, tagname(cfg_tag[p]), cfg_val[p]);
					2'd1: $display("      P%0d: %0s != %0d", p, tagname(cfg_tag[p]), cfg_val[p]);
					2'd2: $display("      P%0d: low %0d bits of %0s == low bits of %0d", p, cfg_val[p][9:6], tagname(cfg_tag[p]), cfg_val[p][5:0]);
					default: $display("      P%0d: low %0d bits of %0s != low bits of %0d", p, cfg_val[p][9:6], tagname(cfg_tag[p]), cfg_val[p][5:0]);
				endcase
		end
	endtask

	// ---------------------------------------------------------------- source, collector, run
	integer errors, checked, show_left, n_true, n_false, cur;
	integer k_seen [0:15];
	integer op_seen [0:3];
	reg     took;

	assign pkt_valid = avail && (p_idx < n_pkts);

	initial begin
		took = 1'b0;
		forever begin
			@(posedge clk);
			took = pkt_valid && pkt_ready;
			@(negedge clk);
			if (took) p_idx = p_idx + 1;
			avail = ({$random} % 100) < 70;
		end
	end

	initial begin : collect
		reg [5:0] e;
		integer i;
		forever begin
			@(negedge clk);
			if (st_en) begin
				e = ref_bits(cur);
				for (i = 0; i < 6; i = i + 1) if (e[i]) n_true = n_true + 1; else n_false = n_false + 1;
				checked = checked + 1;
				if (st_addr !== p_addr[cur] || st_be !== p_be[cur] || st_data !== {LANES{2'b00, e}}) begin
					errors = errors + 1;
					if (errors <= 10) begin
						$display("    FAIL packet %0d: addr %0d be %b row %0d col %0d chan %0d last %0d -> true predicates %b, expected %b",
						         cur, p_addr[cur], p_be[cur], p_row[cur], p_col[cur], p_chan[cur], p_last[cur], st_data[5:0], e);
						show_config;
					end
				end
				else if (show_left > 0) begin
					show_left = show_left - 1;
					$display("      packet: addr %4d  be %b  row %3d  col %3d  chan %3d  last %0d  ->  P7..P2 true: %b  (expected %b)",
					         p_addr[cur], p_be[cur], p_row[cur], p_col[cur], p_chan[cur], p_last[cur], st_data[5:0], e);
				end
				cur = cur + 1;
			end
		end
	end

	task run_program(input integer show);
		integer i, p;
		begin
			make_packets(NPKT);
			make_config;
			for (p = 2; p < 8; p = p + 1) begin
				op_seen[cfg_op[p]] = op_seen[cfg_op[p]] + 1;
				if (cfg_op[p] >= 2) k_seen[cfg_val[p][9:6]] = k_seen[cfg_val[p][9:6]] + 1;
			end
			build_program;
			load_program;
			if (show != 0) begin
				$display("    predicate table of this program:");
				show_config;
				show_left = 6;
			end
			p_idx = 0;
			cur = 0;
			@(negedge clk);
			layer_start = 1'b1;
			@(negedge clk);
			layer_start = 1'b0;
			while (p_idx < n_pkts) @(negedge clk);
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
			if (cur != n_pkts) begin
				errors = errors + 1;
				$display("    FAIL: %0d stores, expected %0d", cur, n_pkts);
			end
		end
	endtask

	integer t;

	initial begin
		if ($test$plusargs("vcd")) begin
			$dumpfile("waveforms/vu_pred.vcd");
			$dumpvars(0, tb_vu_pred);
		end

		edge8[0] = 8'd0;   edge8[1] = 8'd1;    edge8[2] = 8'd2;    edge8[3] = 8'd3;
		edge8[4] = 8'd4;   edge8[5] = 8'd7;    edge8[6] = 8'd8;    edge8[7] = 8'd15;
		edge8[8] = 8'd16;  edge8[9] = 8'd31;   edge8[10] = 8'd63;  edge8[11] = 8'd64;
		edge8[12] = 8'd127; edge8[13] = 8'd128; edge8[14] = 8'd254; edge8[15] = 8'd255;

		errors = 0; checked = 0; show_left = 0; n_true = 0; n_false = 0; cur = 0;
		for (t = 0; t < 16; t = t + 1) k_seen[t] = 0;
		for (t = 0; t < 4; t = t + 1) op_seen[t] = 0;
		p_idx = 0; n_pkts = 0; avail = 1'b1;
		pm_we = 1'b0; pm_waddr = 0; pm_wdata = 0;
		pro_start = 0; pro_len = 0; body_start = 0; body_len = 0; epi_start = 0; epi_len = 0;
		layer_start = 1'b0; layer_end = 1'b0;
		for (t = 0; t < NPKT; t = t + 1) begin
			p_addr[t] = 0; p_be[t] = 0; p_row[t] = 0; p_col[t] = 0; p_chan[t] = 0; p_last[t] = 0;
		end

		rst_n = 1'b0;
		repeat (2) @(negedge clk);
		rst_n = 1'b1;

		$display("");
		$display("Packet predicates P2..P7 (spec v0.6, section 6).");
		$display("Each program sets all six entries; the body adds bit (p-2) when Pp is true, so every");
		$display("stored byte shows exactly which predicates held for that packet.");
		$display("");

		for (t = 0; t < NPROG; t = t + 1) begin
			if (t < 2) $display("  program %0d:", t);
			run_program((t < 2) ? 1 : 0);
		end

		$display("");
		$display("  %0d programs, %0d packets, %0d predicate evaluations (%0d true, %0d false)",
		         NPROG, checked, checked * 6, n_true, n_false);
		$display("  entries per op: tag==val %0d, tag!=val %0d, low-k-bits== %0d, low-k-bits!= %0d",
		         op_seen[0], op_seen[1], op_seen[2], op_seen[3]);
		$write("  low-k-bits entries per k:");
		for (t = 0; t < 16; t = t + 1) $write(" k%0d:%0d", t, k_seen[t]);
		$display("");
		$display("  %0d errors", errors);
		$display("");
		if (errors != 0) $fatal(1, "FAIL");
		$display("PASS: every predicate evaluation matches the spec");
		$finish;
	end
endmodule
