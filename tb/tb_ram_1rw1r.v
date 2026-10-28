`timescale 1ns/1ps

module tb_ram_1rw1r;
	parameter DEPTH = 1536;
	parameter NRAND = 5000;

	localparam AW    = $clog2(DEPTH);
	localparam NBANK = DEPTH / 512;
	localparam [AW:0] LIMIT = DEPTH[AW:0];

	reg           clk;
	reg           en0, we0, en1;
	reg  [3:0]    be0;
	reg  [AW-1:0] addr0, addr1;
	reg  [31:0]   wdata0;
	wire [31:0]   rdata0, rdata1;

	reg  [31:0]   model [0:DEPTH-1];
	reg  [31:0]   exp0, exp1;
	reg           v0, v1, live;
	integer       errors, checks, reads, writes, i, n, a, op;

	ram_1rw1r #(.DEPTH(DEPTH)) dut (
		.clk(clk),
		.en0(en0), .we0(we0), .be0(be0), .addr0(addr0), .wdata0(wdata0), .rdata0(rdata0),
		.en1(en1), .addr1(addr1), .rdata1(rdata1)
	);

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

	task check_and_record;
		begin
			if (live) begin
				if (v0) begin
					checks = checks + 1;
					if (rdata0 !== exp0) begin
						errors = errors + 1;
						if (errors <= 10) $display("FAIL t=%0t port0: got %h, expected %h", $time, rdata0, exp0);
					end
				end
				if (v1) begin
					checks = checks + 1;
					if (rdata1 !== exp1) begin
						errors = errors + 1;
						if (errors <= 10) $display("FAIL t=%0t port1: got %h, expected %h", $time, rdata1, exp1);
					end
				end
`ifndef VERILATOR
				if (!v0 && rdata0 !== 32'bx) begin
					errors = errors + 1;
					if (errors <= 10) $display("FAIL t=%0t port0: got %h, expected X", $time, rdata0);
				end
				if (!v1 && rdata1 !== 32'bx) begin
					errors = errors + 1;
					if (errors <= 10) $display("FAIL t=%0t port1: got %h, expected X", $time, rdata1);
				end
`endif
			end

			v0 = en0 && !we0 && ({1'b0, addr0} < LIMIT);
			v1 = en1 && ({1'b0, addr1} < LIMIT) && !(en0 && we0 && addr0 == addr1);
			exp0 = v0 ? model[addr0] : 32'h0;
			exp1 = v1 ? model[addr1] : 32'h0;
			if (en0 && !we0) reads = reads + 1;
			if (en1)         reads = reads + 1;

			if (en0 && we0) begin
				writes = writes + 1;
				if ({1'b0, addr0} < LIMIT)
					for (i = 0; i < 4; i = i + 1)
						if (be0[i]) model[addr0][i*8 +: 8] = wdata0[i*8 +: 8];
			end
			live = 1'b1;
		end
	endtask

	task drive(input integer e0, input integer w0, input integer b0, input integer a0,
	           input integer d0, input integer e1, input integer a1);
		begin
			@(posedge clk);
			check_and_record;
			if (a0 < 0 || a0 >= (1 << AW) || a1 < 0 || a1 >= (1 << AW) || b0 < 0 || b0 > 15)
				$fatal(1, "drive: argument out of range");
			@(negedge clk);
			en0    = (e0 != 0);
			we0    = (w0 != 0);
			be0    = b0[3:0];
			addr0  = a0[AW-1:0];
			wdata0 = d0;
			en1    = (e1 != 0);
			addr1  = a1[AW-1:0];
		end
	endtask

	task idle;
		drive(0, 0, 0, 0, 0, 0, 0);
	endtask

	task readback_all;
		for (a = 0; a < DEPTH; a = a + 1)
			drive(1, 0, 0, a, 0, 1, DEPTH - 1 - a);
	endtask

	task boundary(input integer ba);
		begin
			drive(1, 1, 15, ba, $random, 0, 0);
			drive(1, 0, 0, ba, 0, 1, ba);
			drive(1, 1, 5, ba, $random, 1, ba ^ 1);
			drive(0, 0, 0, 0, 0, 1, ba);
		end
	endtask

	task random_traffic;
		integer ra0, ra1;
		begin
			for (n = 0; n < NRAND; n = n + 1) begin
				op  = {$random} % 3;
				ra0 = {$random} % DEPTH;
				ra1 = {$random} % DEPTH;
				if (op == 1 && ra1 == ra0) ra1 = (ra1 + 1) % DEPTH;
				drive((op != 0) ? 1 : 0, (op == 1) ? 1 : 0, $random & 15, ra0, $random, {$random} % 2, ra1);
			end
		end
	endtask

	initial begin
		$dumpfile("waveforms/ram_1rw1r.vcd");
		$dumpvars(0, tb_ram_1rw1r);

		en0 = 0; we0 = 0; be0 = 0; addr0 = 0; wdata0 = 0; en1 = 0; addr1 = 0;
		v0 = 0; v1 = 0; live = 0; exp0 = 0; exp1 = 0;
		errors = 0; checks = 0; reads = 0; writes = 0;
		for (a = 0; a < DEPTH; a = a + 1) model[a] = 32'h0;

`ifdef USE_SRAM_MACRO
		$display("ram_1rw1r DEPTH=%0d (%0d bank(s)), mode: sky130 macro", DEPTH, NBANK);
`else
		$display("ram_1rw1r DEPTH=%0d (%0d bank(s)), mode: behavioral", DEPTH, NBANK);
`endif

		for (a = 0; a < DEPTH; a = a + 1)
			drive(1, 1, 15, a, $random, 0, 0);
		readback_all;

		boundary(0);
		for (n = 1; n < NBANK; n = n + 1) begin
			boundary(n*512 - 1);
			boundary(n*512);
		end
		boundary(DEPTH - 1);

		random_traffic;
		readback_all;

		if (DEPTH < (1 << AW)) begin
			drive(1, 1, 15, DEPTH, 32'hDEADBEEF, 0, 0);
			drive(1, 1, 15, (1 << AW) - 1, 32'hCAFEF00D, 0, 0);
			drive(1, 0, 0, DEPTH, 0, 1, (1 << AW) - 1);
			readback_all;
		end

`ifndef USE_SRAM_MACRO
		drive(1, 1, 15, 7, $random, 1, 7);
		drive(0, 0, 0, 0, 0, 1, 7);
`endif

		idle;
		idle;
		idle;

		if (errors != 0) $fatal(1, "FAIL: %0d error(s)", errors);
		$display("PASS: %0d reads, %0d writes, %0d data checks", reads, writes, checks);
		$finish;
	end
endmodule
