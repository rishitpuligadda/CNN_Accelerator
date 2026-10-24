`timescale 1ns/1ps

module tb_dma;
	localparam EAW   = 16;
	localparam SAW   = 11;
	localparam DEPTH = 1536;
	localparam EWORDS = 1 << EAW;

	reg            clk, rst_n, start;
	reg  [EAW-1:0] ext_base;
	reg  [SAW-1:0] sram_base;
	reg  [SAW:0]   nwords;
	wire           busy, done, ext_rd_en, wr_en;
	wire [EAW-1:0] ext_addr;
	wire [SAW-1:0] wr_addr;
	wire [31:0]    wr_data;
	reg  [31:0]    ext_rdata;

	reg            rb_en0, rb_en1;
	reg  [SAW-1:0] rb_addr0, rb_addr1;
	wire           en0;
	wire [SAW-1:0] addr0;
	wire [31:0]    rdata0, rdata1;

	reg  [31:0]    ext_mem [0:EWORDS-1];
	reg  [31:0]    model   [0:DEPTH-1];
	integer        errors, checks, writes, dones, accepted, a, n, lat, rb_err, cyc;
	reg            trace, quiet;

	dma #(.EAW(EAW), .SAW(SAW)) dut (
		.clk(clk), .rst_n(rst_n),
		.start(start), .ext_base(ext_base), .sram_base(sram_base), .nwords(nwords),
		.busy(busy), .done(done),
		.ext_rd_en(ext_rd_en), .ext_addr(ext_addr), .ext_rdata(ext_rdata),
		.wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data)
	);

	assign en0   = wr_en | rb_en0;
	assign addr0 = wr_en ? wr_addr : rb_addr0;

	ram_1rw1r #(.DEPTH(DEPTH)) u_ram (
		.clk(clk),
		.en0(en0), .we0(wr_en), .be0(4'hF), .addr0(addr0), .wdata0(wr_data), .rdata0(rdata0),
		.en1(rb_en1), .addr1(rb_addr1), .rdata1(rdata1)
	);

	always @(posedge clk) begin
		if (ext_rd_en) ext_rdata <= ext_mem[ext_addr];
		else           ext_rdata <= 32'h0;
	end

	always @(posedge clk) begin
		if (wr_en) writes <= writes + 1;
		if (done)  dones  <= dones + 1;
		cyc <= cyc + 1;
		if (trace)
			$display("  %4d |   %b    %b  |    %b      %04h    %08h |   %b    %4d   %08h |  %b",
			         cyc, start, busy, ext_rd_en, ext_addr, ext_rdata, wr_en, wr_addr, wr_data, done);
	end

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

	task run(input integer eb, input integer sb, input integer nw);
		integer i;
		begin
			if (eb < 0 || eb + nw > EWORDS || sb < 0 || sb + nw > DEPTH || nw < 0 || nw > DEPTH)
				$fatal(1, "run: argument out of range");
			@(negedge clk);
			start     = 1'b1;
			ext_base  = eb[EAW-1:0];
			sram_base = sb[SAW-1:0];
			nwords    = nw[SAW:0];
			@(negedge clk);
			start     = 1'b0;
			lat       = 1;
			while (!done) begin
				@(negedge clk);
				lat = lat + 1;
				if (lat > DEPTH + 10) $fatal(1, "run: done never arrived");
			end
			checks = checks + 1;
			if (!quiet) begin
				if (nw == 0)
					$write("  T%0d: ext[%h] -> sram[%0d], 0 words, latency %0d cycle(s) (expected 1)",
					       accepted + 1, eb[EAW-1:0], sb, lat);
				else
					$write("  T%0d: ext[%h..%h] -> sram[%0d..%0d], %0d words, latency %0d cycles (expected %0d)",
					       accepted + 1, eb[EAW-1:0], EAW'(eb + nw - 1), sb, sb + nw - 1, nw, lat, nw + 2);
			end
			if (lat != ((nw == 0) ? 1 : nw + 2)) begin
				errors = errors + 1;
				$display("   <- WRONG LATENCY");
			end
			else if (!quiet)
				$display("   ok");
			for (i = 0; i < nw; i = i + 1)
				model[sb + i] = ext_mem[eb + i];
			accepted = accepted + 1;
		end
	endtask

	task readback;
		begin
			rb_err = errors;
			for (a = 0; a < DEPTH; a = a + 2) begin
				@(negedge clk);
				rb_en0   = 1'b1;
				rb_addr0 = a[SAW-1:0];
				rb_en1   = 1'b1;
				rb_addr1 = a[SAW-1:0] + 1'b1;
				@(posedge clk);
				@(negedge clk);
				rb_en0 = 1'b0;
				rb_en1 = 1'b0;
				@(posedge clk);
				checks = checks + 2;
				if (rdata0 !== model[a]) begin
					errors = errors + 1;
					if (errors <= 10) $display("FAIL sram[%0d] = %h, expected %h", a, rdata0, model[a]);
				end
				if (rdata1 !== model[a+1]) begin
					errors = errors + 1;
					if (errors <= 10) $display("FAIL sram[%0d] = %h, expected %h", a+1, rdata1, model[a+1]);
				end
			end
			$display("  readback: all %0d SRAM words compared with the expected contents, %0d mismatches", DEPTH, errors - rb_err);
		end
	endtask

	initial begin
		$dumpfile("dma.vcd");
		$dumpvars(0, tb_dma);

		errors = 0; checks = 0; writes = 0; dones = 0; accepted = 0; cyc = 0; trace = 1'b0; quiet = 1'b0;
		start = 1'b0; ext_base = 0; sram_base = 0; nwords = 0;
		rb_en0 = 1'b0; rb_en1 = 1'b0; rb_addr0 = 0; rb_addr1 = 0;
		for (a = 0; a < EWORDS; a = a + 1) ext_mem[a] = $random;
		for (a = 0; a < DEPTH; a = a + 1)  model[a]   = 32'h0;

`ifdef USE_SRAM_MACRO
		$display("dma -> ram_1rw1r DEPTH=%0d, mode: sky130 macro", DEPTH);
`else
		$display("dma -> ram_1rw1r DEPTH=%0d, mode: behavioral", DEPTH);
`endif

		rst_n = 1'b0;
		repeat (2) @(negedge clk);
		rst_n = 1'b1;

		$display("");
		$display("1) Cycle-by-cycle trace of a 4-word transfer, ext[0100..0103] -> sram[10..13]:");
		$display("     ext[0100..0103] = %08h %08h %08h %08h", ext_mem[256], ext_mem[257], ext_mem[258], ext_mem[259]);
		$display("   cyc | start busy | ext_rd_en ext_addr ext_rdata | wr_en wr_addr wr_data  | done");
		@(negedge clk);
		trace = 1'b1;
		quiet = 1'b1;
		run(256, 10, 4);
		@(negedge clk);
		trace = 1'b0;
		quiet = 1'b0;
		$display("   each word is read in one cycle and written to SRAM the next: one word per cycle,");
		$display("   done pulses after the last write, %0d cycles after start (4 words + 2)", lat);

		$display("");
		$display("2) Fill the whole SRAM:");
		run(0, 0, DEPTH);
		readback;

		$display("");
		$display("3) Edge cases: bank boundaries, last address, single word, zero words:");
		run(1000, 100, 37);
		run(EWORDS - 1, 1535, 1);
		run(4242, 7, 0);
		run(20000, 511, 2);
		run(30000, 1023, 300);
		readback;

		$display("");
		$display("4) 40 random transfers:");
		for (n = 0; n < 40; n = n + 1)
			run({$random} % (EWORDS - 64), {$random} % (DEPTH - 64), {$random} % 64);
		readback;

		$display("");
		$display("5) start while busy: 200-word transfer, then a second start 20 cycles in (must be ignored)");
		@(negedge clk);
		start = 1'b1; ext_base = 16'd50000; sram_base = 11'd0; nwords = 12'd200;
		@(negedge clk);
		start = 1'b0;
		repeat (20) @(negedge clk);
		start = 1'b1; ext_base = 16'd60000; sram_base = 11'd0; nwords = 12'd10;
		@(negedge clk);
		start = 1'b0;
		while (!done) @(negedge clk);
		for (a = 0; a < 200; a = a + 1) model[a] = ext_mem[50000 + a];
		accepted = accepted + 1;
		$display("  ext[c350..c417] -> sram[0..199] finished; the readback below confirms sram[0..9]");
		$display("  holds ext[c350..] and not ext[ea60..] from the ignored request");

		$display("");
		$display("6) Back-to-back: second transfer starts the moment busy drops");
		@(negedge clk);
		start = 1'b1; ext_base = 16'd100; sram_base = 11'd200; nwords = 12'd5;
		@(negedge clk);
		start = 1'b0;
		while (busy) @(negedge clk);
		start = 1'b1; ext_base = 16'd900; sram_base = 11'd205; nwords = 12'd5;
		@(negedge clk);
		start = 1'b0;
		while (busy || !done) @(negedge clk);
		repeat (4) @(negedge clk);
		for (a = 0; a < 5; a = a + 1) begin
			model[200 + a] = ext_mem[100 + a];
			model[205 + a] = ext_mem[900 + a];
		end
		accepted = accepted + 2;
		$display("  ext[0064..0068] -> sram[200..204], then immediately ext[0384..0388] -> sram[205..209]");
		readback;

		repeat (3) @(negedge clk);
		checks = checks + 1;
		$display("");
		$display("7) done pulses seen: %0d, transfers accepted: %0d (ignored start produced no done)", dones, accepted);
		if (dones != accepted) begin
			errors = errors + 1;
			$display("FAIL: %0d done pulses for %0d accepted transfers", dones, accepted);
		end
		$display("");

		if (errors != 0) $fatal(1, "FAIL: %0d error(s)", errors);
		$display("PASS: %0d transfers, %0d words written, %0d checks", accepted, writes, checks);
		$finish;
	end
endmodule
