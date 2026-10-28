`timescale 1ns/1ps

module tb_dma;
	localparam EAW    = 16;
	localparam SAW    = 11;
	localparam DEPTH  = 1536;
	localparam EWORDS = 1 << EAW;
	localparam QD     = 32;

	reg            clk, rst_n, start;
	reg  [EAW-1:0] ext_base;
	reg  [SAW-1:0] sram_base;
	reg  [SAW:0]   nwords;
	wire           busy, done;
	wire           rd_req_valid, rd_req_ready, rd_resp_valid, rd_resp_ready;
	wire [EAW-1:0] rd_req_addr;
	wire [31:0]    rd_resp_data;
	wire           wr_en;
	wire [SAW-1:0] wr_addr;
	wire [31:0]    wr_data;

	reg            rb_en0, rb_en1;
	reg  [SAW-1:0] rb_addr0, rb_addr1;
	wire           en0;
	wire [SAW-1:0] addr0;
	wire [31:0]    rdata0, rdata1;

	reg  [31:0]    ext_mem [0:EWORDS-1];
	reg  [31:0]    model   [0:DEPTH-1];

	reg  [EAW-1:0] q_addr [0:QD-1];
	integer        q_due  [0:QD-1];
	integer        q_head, q_tail, q_count;
	integer        lat_min, lat_max, rdy_pct;
	reg            rdy_r;

	integer        errors, checks, writes, dones, accepted, reqs, resps;
	integer        a, n, lat, rb_err, cyc;
	reg            trace, quiet, exact;

	wire           req_fire  = rd_req_valid && rd_req_ready;
	wire           resp_fire = rd_resp_valid && rd_resp_ready;

	dma #(.EAW(EAW), .SAW(SAW)) dut (
		.clk(clk), .rst_n(rst_n),
		.start(start), .ext_base(ext_base), .sram_base(sram_base), .nwords(nwords),
		.busy(busy), .done(done),
		.rd_req_valid(rd_req_valid), .rd_req_ready(rd_req_ready), .rd_req_addr(rd_req_addr),
		.rd_resp_valid(rd_resp_valid), .rd_resp_data(rd_resp_data), .rd_resp_ready(rd_resp_ready),
		.wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data)
	);

	assign en0   = wr_en | rb_en0;
	assign addr0 = wr_en ? wr_addr : rb_addr0;

	ram_1rw1r #(.DEPTH(DEPTH)) u_ram (
		.clk(clk),
		.en0(en0), .we0(wr_en), .be0(4'hF), .addr0(addr0), .wdata0(wr_data), .rdata0(rdata0),
		.en1(rb_en1), .addr1(rb_addr1), .rdata1(rdata1)
	);

	assign rd_req_ready  = rdy_r && (q_count < QD);
	assign rd_resp_valid = (q_count != 0) && (q_due[q_head] <= cyc);
	assign rd_resp_data  = ext_mem[q_addr[q_head]];

	always @(posedge clk) begin
		cyc   <= cyc + 1;
		rdy_r <= ({$random} % 100) < rdy_pct;

		if (req_fire) begin
			q_addr[q_tail] <= rd_req_addr;
			q_due[q_tail]  <= cyc + lat_min + ({$random} % (lat_max - lat_min + 1));
			q_tail         <= (q_tail + 1) % QD;
			reqs           <= reqs + 1;
		end
		if (resp_fire) begin
			q_head <= (q_head + 1) % QD;
			resps  <= resps + 1;
		end
		if (req_fire && !resp_fire)      q_count <= q_count + 1;
		else if (!req_fire && resp_fire) q_count <= q_count - 1;

		if (wr_en) writes <= writes + 1;
		if (done)  dones  <= dones + 1;

		if (trace) begin
			$write("  %4d |  %b   |    %b       %b     %04h  |     %b        %b     ",
			       cyc, busy, rd_req_valid, rd_req_ready, rd_req_addr, rd_resp_valid, rd_resp_ready);
			if (rd_resp_valid) $write("%08h", rd_resp_data);
			else               $write("   --   ");
			if (wr_en) $display(" |  %b    %4d  |  %b", wr_en, wr_addr, done);
			else       $display(" |  %b      --  |  %b", wr_en, done);
		end
	end

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

	task source(input integer lmin, input integer lmax, input integer rpct);
		begin
			@(negedge clk);
			lat_min = lmin;
			lat_max = lmax;
			rdy_pct = rpct;
			exact   = (lmin == 1 && lmax == 1 && rpct == 100);
			if (lmin == lmax)
				$display("   source: latency %0d cycle(s), accepts requests %0d%% of cycles", lmin, rpct);
			else
				$display("   source: latency %0d..%0d cycles (random), accepts requests %0d%% of cycles", lmin, lmax, rpct);
		end
	endtask

	task run(input integer eb, input integer sb, input integer nw);
		integer i, r0, s0;
		begin
			if (eb < 0 || eb + nw > EWORDS || sb < 0 || sb + nw > DEPTH || nw < 0 || nw > DEPTH)
				$fatal(1, "run: argument out of range");
			r0 = reqs;
			s0 = resps;
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
				if (lat > 50 * DEPTH) $fatal(1, "run: done never arrived");
			end

			checks = checks + 2;
			if (reqs - r0 != nw || resps - s0 != nw) begin
				errors = errors + 1;
				$display("FAIL: %0d words requested, %0d responses accepted, expected %0d of each",
				         reqs - r0, resps - s0, nw);
			end
			if (exact && lat != ((nw == 0) ? 2 : nw + 3)) begin
				errors = errors + 1;
				$display("FAIL latency for %0d words: %0d cycles, expected %0d", nw, lat, (nw == 0) ? 2 : nw + 3);
			end

			if (!quiet) begin
				if (nw == 0)
					$display("  T%0d: ext[%h] -> sram[%0d], 0 words, done after %0d cycles", accepted + 1, eb[EAW-1:0], sb, lat);
				else if (exact)
					$display("  T%0d: ext[%h..%h] -> sram[%0d..%0d], %0d words, %0d cycles (expected %0d)   ok",
					         accepted + 1, eb[EAW-1:0], EAW'(eb + nw - 1), sb, sb + nw - 1, nw, lat, nw + 3);
				else
					$display("  T%0d: ext[%h..%h] -> sram[%0d..%0d], %0d words, %0d cycles",
					         accepted + 1, eb[EAW-1:0], EAW'(eb + nw - 1), sb, sb + nw - 1, nw, lat);
			end

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

	task random_transfers(input integer count);
		begin
			for (n = 0; n < count; n = n + 1)
				run({$random} % (EWORDS - 64), {$random} % (DEPTH - 64), 1 + {$random} % 63);
		end
	endtask

	initial begin
		$dumpfile("waveforms/dma.vcd");
		$dumpvars(0, tb_dma);

		errors = 0; checks = 0; writes = 0; dones = 0; accepted = 0; reqs = 0; resps = 0;
		cyc = 0; trace = 1'b0; quiet = 1'b0; exact = 1'b0;
		q_head = 0; q_tail = 0; q_count = 0;
		lat_min = 1; lat_max = 1; rdy_pct = 100; rdy_r = 1'b1;
		start = 1'b0; ext_base = 0; sram_base = 0; nwords = 0;
		rb_en0 = 1'b0; rb_en1 = 1'b0; rb_addr0 = 0; rb_addr1 = 0;
		for (a = 0; a < EWORDS; a = a + 1) ext_mem[a] = $random;
		for (a = 0; a < QD; a = a + 1) begin
			q_addr[a] = {EAW{1'b0}};
			q_due[a]  = 0;
		end
		for (a = 0; a < DEPTH; a = a + 1) model[a] = 32'h0;

`ifdef USE_SRAM_MACRO
		$display("dma (valid/ready) -> ram_1rw1r DEPTH=%0d, mode: sky130 macro", DEPTH);
`else
		$display("dma (valid/ready) -> ram_1rw1r DEPTH=%0d, mode: behavioral", DEPTH);
`endif

		rst_n = 1'b0;
		repeat (2) @(negedge clk);
		rst_n = 1'b1;

		$display("");
		$display("1) Trace of a 4-word transfer, ext[0100..0103] -> sram[10..13], with a slow, stalling source:");
		source(1, 3, 60);
		$display("     ext[0100..0103] = %08h %08h %08h %08h", ext_mem[256], ext_mem[257], ext_mem[258], ext_mem[259]);
		$display("   cyc | busy | req: valid ready addr  | resp: valid ready  data    | wr_en addr | done");
		@(negedge clk);
		trace = 1'b1;
		quiet = 1'b1;
		run(256, 10, 4);
		@(negedge clk);
		trace = 1'b0;
		quiet = 1'b0;
		$display("   a request moves only when valid and ready are both 1; a word is written to SRAM");
		$display("   one cycle after its response arrives (the write is registered); done followed after %0d cycles", lat);

		$display("");
		$display("2) Ideal source (N words take N+3 cycles: request, response, registered SRAM write):");
		source(1, 1, 100);
		run(0, 0, DEPTH);
		run(1000, 100, 37);
		run(EWORDS - 1, 1535, 1);
		run(4242, 7, 0);
		run(20000, 511, 2);
		run(30000, 1023, 300);
		readback;

		$display("");
		$display("3) Variable latency:");
		source(1, 8, 100);
		random_transfers(15);
		readback;

		$display("");
		$display("4) Variable latency and a source that refuses half of the requests:");
		source(1, 8, 50);
		random_transfers(15);
		readback;

		$display("");
		$display("5) Long latency: requests keep flowing while earlier ones are still in flight");
		source(20, 20, 100);
		run(40000, 0, 300);
		$display("   300 words in %0d cycles: 20 cycles to the first response, then one word per cycle", lat);
		readback;

		$display("");
		$display("6) start while busy: 200-word transfer, then a second start 20 cycles in (must be ignored)");
		source(1, 4, 80);
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
		$display("7) Back-to-back: the second transfer starts in the cycle done is high");
		@(negedge clk);
		start = 1'b1; ext_base = 16'd100; sram_base = 11'd200; nwords = 12'd5;
		@(negedge clk);
		start = 1'b0;
		while (!done) @(negedge clk);
		start = 1'b1; ext_base = 16'd900; sram_base = 11'd205; nwords = 12'd5;
		@(negedge clk);
		start = 1'b0;
		while (!done) @(negedge clk);
		repeat (4) @(negedge clk);
		for (a = 0; a < 5; a = a + 1) begin
			model[200 + a] = ext_mem[100 + a];
			model[205 + a] = ext_mem[900 + a];
		end
		accepted = accepted + 2;
		$display("  ext[0064..0068] -> sram[200..204], then immediately ext[0384..0388] -> sram[205..209]");
		readback;

		repeat (3) @(negedge clk);
		checks = checks + 2;
		$display("");
		$display("8) Totals: %0d done pulses for %0d accepted transfers; %0d requests, %0d responses, %0d SRAM writes",
		         dones, accepted, reqs, resps, writes);
		if (dones != accepted) begin
			errors = errors + 1;
			$display("FAIL: %0d done pulses for %0d accepted transfers", dones, accepted);
		end
		if (reqs != resps || resps != writes) begin
			errors = errors + 1;
			$display("FAIL: requests, responses and writes should all be equal");
		end
		$display("");

		if (errors != 0) $fatal(1, "FAIL: %0d error(s)", errors);
		$display("PASS: %0d transfers, %0d words written, %0d checks", accepted, writes, checks);
		$finish;
	end
endmodule
