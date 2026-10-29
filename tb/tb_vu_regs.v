`timescale 1ns/1ps

module tb_vu_regs;
	parameter LANES  = 4;
	parameter CYCLES = 40000;

	localparam W = LANES * 32;

	reg              clk, rst_n;
	reg  [2:0]       vra, vrb, vw0_idx, vw1_idx;
	reg  [W-1:0]     pkt_data, vw0_data, vw1_data;
	reg              vw0_en, vw1_en, sw_en, q_we, c_we;
	reg  [LANES-1:0] vw0_lanes, vw1_lanes;
	reg  [3:0]       sra, srb, sw_idx;
	reg  [31:0]      sw_data, c_lo, c_hi;
	reg  [1:0]       q_widx, q_ridx, c_widx, c_ridx;
	reg  [15:0]      q_mpos, q_mneg;
	reg  [5:0]       q_s;
	wire [W-1:0]     vda, vdb;
	wire [31:0]      sda, sdb, lo, hi;
	wire [15:0]      mpos, mneg;
	wire [5:0]       s;

	reg  [W-1:0]     mv  [0:6];
	reg  [31:0]      ms  [0:15];
	reg  [15:0]      mqp [0:3];
	reg  [15:0]      mqn [0:3];
	reg  [5:0]       mqs [0:3];
	reg  [31:0]      mcl [0:3];
	reg  [31:0]      mch [0:3];

	integer          errors, t, i, k;
	integer          n_v, n_bypass, n_s, n_set, n_v7;

	vu_regs #(.LANES(LANES)) dut (
		.clk(clk), .rst_n(rst_n),
		.vra(vra), .vrb(vrb), .vda(vda), .vdb(vdb), .pkt_data(pkt_data),
		.vw0_en(vw0_en), .vw0_idx(vw0_idx), .vw0_lanes(vw0_lanes), .vw0_data(vw0_data),
		.vw1_en(vw1_en), .vw1_idx(vw1_idx), .vw1_lanes(vw1_lanes), .vw1_data(vw1_data),
		.sra(sra), .srb(srb), .sda(sda), .sdb(sdb), .sw_en(sw_en), .sw_idx(sw_idx), .sw_data(sw_data),
		.q_we(q_we), .q_widx(q_widx), .q_mpos(q_mpos), .q_mneg(q_mneg), .q_s(q_s), .q_ridx(q_ridx),
		.mpos(mpos), .mneg(mneg), .s(s),
		.c_we(c_we), .c_widx(c_widx), .c_lo(c_lo), .c_hi(c_hi), .c_ridx(c_ridx), .lo(lo), .hi(hi)
	);

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

	function [W-1:0] rand_vec(input integer unused);
		integer j;
		reg [W-1:0] v;
		begin
			v = {W{1'b0}};
			for (j = 0; j < LANES; j = j + 1) v[j*32 +: 32] = $random + unused;
			rand_vec = v;
		end
	endfunction

	function [W-1:0] exp_v(input [2:0] idx);
		reg [W-1:0] v;
		integer j;
		begin
			if (idx == 3'd7) exp_v = pkt_data;
			else begin
				v = mv[idx];
				for (j = 0; j < LANES; j = j + 1) begin
					if (vw0_en && vw0_idx == idx && vw0_lanes[j]) v[j*32 +: 32] = vw0_data[j*32 +: 32];
					if (vw1_en && vw1_idx == idx && vw1_lanes[j]) v[j*32 +: 32] = vw1_data[j*32 +: 32];
				end
				exp_v = v;
			end
		end
	endfunction

	function [31:0] exp_s(input [3:0] idx);
		begin
			if (idx == 4'd0) exp_s = 32'd0;
			else             exp_s = ms[idx];
		end
	endfunction

	task check;
		begin
			n_v = n_v + 2;
			if (vra == 3'd7 || vrb == 3'd7) n_v7 = n_v7 + 1;
			if ((vw0_en && (vw0_idx == vra || vw0_idx == vrb)) || (vw1_en && (vw1_idx == vra || vw1_idx == vrb)))
				n_bypass = n_bypass + 1;
			if (vda !== exp_v(vra) || vdb !== exp_v(vrb)) begin
				errors = errors + 1;
				if (errors <= 10) $display("FAIL t=%0t: vector read v%0d/v%0d = %h/%h, expected %h/%h",
				                           $time, vra, vrb, vda, vdb, exp_v(vra), exp_v(vrb));
			end
			n_s = n_s + 2;
			if (sda !== exp_s(sra) || sdb !== exp_s(srb)) begin
				errors = errors + 1;
				if (errors <= 10) $display("FAIL t=%0t: scalar read s%0d/s%0d = %h/%h, expected %h/%h",
				                           $time, sra, srb, sda, sdb, exp_s(sra), exp_s(srb));
			end
			n_set = n_set + 1;
			if (mpos !== mqp[q_ridx] || mneg !== mqn[q_ridx] || s !== mqs[q_ridx] ||
			    lo !== mcl[c_ridx] || hi !== mch[c_ridx]) begin
				errors = errors + 1;
				if (errors <= 10) $display("FAIL t=%0t: requant/clamp set read wrong (q%0d, c%0d)", $time, q_ridx, c_ridx);
			end
		end
	endtask

	task commit;
		begin
			for (i = 0; i < 7; i = i + 1)
				for (k = 0; k < LANES; k = k + 1) begin
					if (vw1_en && vw1_idx == i[2:0] && vw1_lanes[k])      mv[i][k*32 +: 32] = vw1_data[k*32 +: 32];
					else if (vw0_en && vw0_idx == i[2:0] && vw0_lanes[k]) mv[i][k*32 +: 32] = vw0_data[k*32 +: 32];
				end
			if (sw_en && sw_idx != 4'd0) ms[sw_idx] = sw_data;
			if (q_we) begin
				mqp[q_widx] = q_mpos;
				mqn[q_widx] = q_mneg;
				mqs[q_widx] = q_s;
			end
			if (c_we) begin
				mcl[c_widx] = c_lo;
				mch[c_widx] = c_hi;
			end
		end
	endtask

	task randomize_inputs(input integer same_reg_pct);
		begin
			vra       = 3'($random);
			vrb       = 3'($random);
			pkt_data  = rand_vec(0);
			vw0_en    = ({$random} % 2) == 1;
			vw1_en    = ({$random} % 2) == 1;
			vw0_idx   = 3'($random);
			vw1_idx   = (({$random} % 100) < same_reg_pct) ? vw0_idx : 3'($random);
			vw0_lanes = LANES'($random);
			vw1_lanes = LANES'($random);
			vw0_data  = rand_vec(0);
			vw1_data  = rand_vec(0);
			if (({$random} % 100) < same_reg_pct) vra = vw0_idx;
			sra       = 4'($random);
			srb       = 4'($random);
			sw_en     = ({$random} % 2) == 1;
			sw_idx    = 4'($random);
			sw_data   = $random;
			q_we      = ({$random} % 8) == 0;
			q_widx    = 2'($random);
			q_ridx    = 2'($random);
			q_mpos    = 16'($random);
			q_mneg    = 16'($random);
			q_s       = 6'($random);
			c_we      = ({$random} % 8) == 0;
			c_widx    = 2'($random);
			c_ridx    = 2'($random);
			c_lo      = $random;
			c_hi      = $random;
		end
	endtask

	initial begin
		$dumpfile("waveforms/vu_regs.vcd");
		$dumpvars(0, tb_vu_regs);

		errors = 0; n_v = 0; n_bypass = 0; n_s = 0; n_set = 0; n_v7 = 0;
		for (i = 0; i < 7; i = i + 1)  mv[i] = {W{1'b0}};
		for (i = 0; i < 16; i = i + 1) ms[i] = 32'd0;
		for (i = 0; i < 4; i = i + 1) begin
			mqp[i] = 16'd0; mqn[i] = 16'd0; mqs[i] = 6'd0;
			mcl[i] = 32'h80000000; mch[i] = 32'h7FFFFFFF;
		end
		vw0_en = 1'b0; vw1_en = 1'b0; sw_en = 1'b0; q_we = 1'b0; c_we = 1'b0;
		vra = 0; vrb = 0; vw0_idx = 0; vw1_idx = 0; vw0_lanes = 0; vw1_lanes = 0;
		pkt_data = 0; vw0_data = 0; vw1_data = 0; sra = 0; srb = 0; sw_idx = 0; sw_data = 0;
		q_widx = 0; q_ridx = 0; q_mpos = 0; q_mneg = 0; q_s = 0; c_widx = 0; c_ridx = 0; c_lo = 0; c_hi = 0;

		rst_n = 1'b0;
		repeat (2) @(negedge clk);
		rst_n = 1'b1;

		$display("");
		$display("vu_regs LANES=%0d: 7 vector registers + v7 (packet), 16 scalar registers (s0 = 0),", LANES);
		$display("4 requantization sets, 4 clamp sets; two vector write ports with same-cycle forwarding;");
		$display("scalar writes become visible in the next cycle (no forwarding needed: scalar ops finish in their own cycle)");
		$display("");

		@(negedge clk);
		#1;
		check;
		$display("1) After reset: all registers 0, clamp sets = full int32 range   %0s", (errors == 0) ? "ok" : "WRONG");

		for (t = 0; t < CYCLES; t = t + 1) begin
			@(negedge clk);
			randomize_inputs((t < CYCLES / 2) ? 10 : 60);
			#1;
			check;
			@(posedge clk);
			commit;
		end
		@(negedge clk);
		vw0_en = 1'b0; vw1_en = 1'b0; sw_en = 1'b0; q_we = 1'b0; c_we = 1'b0;

		$display("2) %0d random cycles (both write ports, lane masks, reads of registers being written):", CYCLES);
		$display("   vector reads checked:     %0d  (%0d cycles reading a register written in the same cycle, %0d reading v7)",
		         n_v, n_bypass, n_v7);
		$display("   scalar reads checked:     %0d", n_s);
		$display("   set reads checked:        %0d", n_set);
		$display("");

		if (errors != 0) $fatal(1, "FAIL: %0d error(s)", errors);
		$display("PASS: every read matched the reference model");
		$finish;
	end
endmodule
