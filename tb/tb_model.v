`timescale 1ns/1ps

// The compiled model on the chip. This testbench only plays the chip's surroundings:
//   - the external memory (with the compiled model from model_mem.hex, and each input image),
//   - the host (writes the image, pulses start, waits for done),
//   - a probe recording what the vector unit stores in each layer.
// It knows no expected values. It writes everything the chip produced to outputs/chip_results.hex;
// python/check_results.py compares that with the golden model afterwards.
module tb_model;
	localparam EAW    = 16;
	localparam N      = 4;
	localparam ADDR   = 11;
	localparam EWORDS = 1 << EAW;
	localparam IMG_EB = 0;
	localparam TBL_EB = 49152;
	localparam WB_EB  = 57344;

	`include "model/model_params.vh"

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
	reg  [31:0]         images  [0:NIMG*IMG_WORDS-1];

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

	// ---------------------------------------------------------------- external memory: latency 1..3 cycles
	reg  [EAW-1:0]      q_addr [0:31];
	integer             q_due  [0:31];
	integer             sq_head, sq_tail, sq_count, cyc;
	reg                 mem_on;
	wire                req_fire  = rd_req_valid && rd_req_ready;
	wire                resp_fire = rd_resp_valid && rd_resp_ready;

	assign rd_req_ready  = mem_on && (sq_count < 32);
	assign rd_resp_valid = mem_on && (sq_count != 0) && (q_due[sq_head] <= cyc);
	assign rd_resp_data  = ext_mem[q_addr[sq_head]];
	assign wr_req_ready  = mem_on;

	always @(posedge clk) begin
		cyc <= cyc + 1;
		if (!mem_on) begin
			sq_head <= 0; sq_tail <= 0; sq_count <= 0;
		end
		else begin
			if (req_fire) begin
				q_addr[sq_tail] <= rd_req_addr;
				q_due[sq_tail]  <= cyc + 1 + ({$random} % 3);
				sq_tail         <= (sq_tail + 1) % 32;
			end
			if (resp_fire) sq_head <= (sq_head + 1) % 32;
			if (req_fire && !resp_fire)      sq_count <= sq_count + 1;
			else if (!req_fire && resp_fire) sq_count <= sq_count - 1;
		end
	end

	initial begin
		forever begin
			@(posedge clk);
			if (wr_req_valid && wr_req_ready) ext_mem[wr_req_addr] = wr_req_data;
		end
	end

	// ---------------------------------------------------------------- probe: every byte the vector unit stores, per layer
	reg  [7:0]  hw_map [0:7][0:6143];
	integer     hw_wr  [0:7][0:6143];

	initial begin : probe
		integer i, l;
		forever begin
			@(posedge clk);
			if (mem_on && dut.st_en) begin
				l = dut.u_seq.layer_idx;
				for (i = 0; i < N; i = i + 1)
					if (dut.st_be[i]) begin
						hw_map[l][dut.st_addr * 4 + i] = dut.st_data[i*8 +: 8];
						hw_wr[l][dut.st_addr * 4 + i]  = hw_wr[l][dut.st_addr * 4 + i] + 1;
					end
			end
		end
	end

	// ---------------------------------------------------------------- run every image, dump what the chip produced
	integer img, i, l, b, t0, wd, fd, total;

	initial begin
		if ($test$plusargs("vcd")) begin
			$dumpfile("waveforms/model.vcd");
			$dumpvars(0, tb_model);
		end
		for (i = 0; i < EWORDS; i = i + 1) ext_mem[i] = 32'd0;
		$readmemh("model/model_mem.hex", ext_mem);       // the compiled model, as it would sit in external memory
		$readmemh("model/images.hex", images);
		start = 1'b0; tbl_base = TBL_EB; cyc = 0; mem_on = 1'b0; total = 0;
		sq_head = 0; sq_tail = 0; sq_count = 0;
		rst_n = 1'b0;
		repeat (3) @(negedge clk);
		rst_n = 1'b1;
		repeat (10) @(negedge clk);
		mem_on = 1'b1;
		fd = $fopen("outputs/chip_results.hex", "w");
		$fdisplay(fd, "// chip results: per image 'image <n> <cycles>', the written-back words, then per layer the probe's");
		$fdisplay(fd, "// bytes as 'vvc' (value, number of times written: 0, 1, or 2 for twice or more)");

		$display("");
		$display("Running %0d images on the chip, %0d layers each (one start per image).", NIMG, NL);
		for (img = 0; img < NIMG; img = img + 1) begin
			// the host: put the image into memory, clear the result area, start the chip
			for (i = 0; i < IMG_WORDS; i = i + 1) ext_mem[IMG_EB + i] = images[img * IMG_WORDS + i];
			for (i = 0; i < WB_WORDS; i = i + 1) ext_mem[WB_EB + i] = 32'hDEADBEEF;
			for (l = 0; l < NL; l = l + 1) for (i = 0; i < 6144; i = i + 1) hw_wr[l][i] = 0;
			t0 = cyc;
			@(negedge clk);
			start = 1'b1;
			@(negedge clk);
			start = 1'b0;
			i = 0;
			while (!done) begin
				@(negedge clk);
				i = i + 1;
				if (i > 5000000) $fatal(1, "image %0d never finished", img);
			end
			if (err_valid) $fatal(1, "image %0d: the chip rejected a layer, err = %b", img, err);
			repeat (2) @(negedge clk);
			total = total + (cyc - t0);

			// what the chip produced: the result it wrote to memory, and the probe's per-layer stores
			$fdisplay(fd, "image %0d %0d", img, cyc - t0);
			for (i = 0; i < WB_WORDS; i = i + 1) $fdisplay(fd, "%08x", ext_mem[WB_EB + i]);
			for (l = 0; l < NL; l = l + 1)
				for (b = 0; b < lay_words(l) * 4; b = b + 1) begin
					wd = (hw_wr[l][b] > 2) ? 2 : hw_wr[l][b];
					$fdisplay(fd, "%02x%0d", hw_map[l][b], wd);
				end
			if (img < 5 || img % 50 == 49) $display("    image %0d: done after %0d cycles", img, cyc - t0);
		end
		$fclose(fd);
		$display("");
		$display("%0d images, %0d cycles per image on average. Everything the chip produced: outputs/chip_results.hex", NIMG, total / NIMG);
		$finish;
	end
endmodule
