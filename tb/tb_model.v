`timescale 1ns/1ps

// The trained model on the chip: run_flow.py trains, quantizes and compiles a CNN; this testbench loads
// the compiled memory image, runs every test image through the RTL (one start per image), and compares
// every layer's stored int8 map and the 10 written-back probabilities with the Python golden model.
module tb_model;
	localparam EAW    = 16;
	localparam N      = 4;
	localparam ADDR   = 11;
	localparam EWORDS = 1 << EAW;
	localparam IMG_EB = 0;
	localparam TBL_EB = 49152;
	localparam WB_EB  = 57344;

	`include "model/model_params.vh"

	localparam PER_IMG_MAP = MAP_BYTES;   // bytes of all stored maps of one image
	localparam IMG_RP = (IMG_W + 3) / 4 * 4;
	localparam WIDE   = (IMG_W > 16);                      // one character per pixel for big images
	localparam COLW   = WIDE ? IMG_W + 4 : 2 * IMG_W + 4;  // gallery column width
	localparam PER_ROW = (120 / COLW < 1) ? 1 : ((120 / COLW > 6) ? 6 : 120 / COLW);

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

	reg  [31:0]         ext_mem  [0:EWORDS-1];
	reg  [31:0]         images   [0:NIMG*IMG_WORDS-1];
	reg  [31:0]         expected [0:NIMG*(NCLASS+2)-1];
	reg  [7:0]          expmaps  [0:NIMG*PER_IMG_MAP-1];

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

	// ---------------------------------------------------------------- external memory (latency 1..3, always ready)
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

	// ---------------------------------------------------------------- every store of the vector unit, per layer
	reg  [7:0]  hw_map [0:7][0:6143];
	integer     hw_wr  [0:7][0:6143];

	initial begin : snoop
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

	// position of value (c, y, x) of layer l in its output buffer: guard word, planar, rows padded to 4 bytes
	function integer bufpos(input integer l, input integer c, input integer y, input integer x);
		integer rp;
		begin
			if (lay_mode(l) == 4) bufpos = (1 + c) * 4;
			else begin
				rp = (lay_w(l) + 3) / 4;
				bufpos = (1 + c * lay_h(l) * rp + y * rp + x / 4) * 4 + x % 4;
			end
		end
	endfunction

	// ---------------------------------------------------------------- running every test image
	integer img, i, l, c, y, x, k, mapoff, nmap_err, nprob_err, hw_correct, gold_correct, agree, t0, cycles_total;
	integer pred, label, gpred, best;
	integer res_pred  [0:NIMG-1];
	integer res_label [0:NIMG-1];
	integer res_cyc   [0:NIMG-1];
	reg [7:0] res_prob [0:NIMG*NCLASS-1];
	reg signed [7:0] hv, ev;


	// one row of the gallery: digits side by side, with label, chip prediction and top-2 outputs (channel 0 drawn)
	function [15:0] pix2(input integer n, input integer yy, input integer xx);
		integer b;
		reg signed [7:0] px;
		begin
			b  = 4 + yy * IMG_RP + xx;
			px = images[n * IMG_WORDS + b / 4][(b % 4) * 8 +: 8];
			if (px > 90)      pix2 = WIDE ? " #" : "##";
			else if (px > 45) pix2 = WIDE ? " +" : "++";
			else if (px > 12) pix2 = WIDE ? " ." : "..";
			else              pix2 = "  ";
		end
	endfunction

	task spaces(input integer fd, input integer n);
		integer t;
		for (t = 0; t < n; t = t + 1) $fwrite(fd, " ");
	endtask

	task gallery_row(input integer fd, input integer list_n, input integer only_wrong, inout integer from, input integer upto);
		integer sel [0:5];
		integer ns, j, yy, xx, b1, b2, m;
		reg [15:0] pc;
		begin
			ns = 0;
			while (ns < PER_ROW && from < upto) begin
				if (only_wrong == 0 || res_pred[from] != res_label[from]) begin
					sel[ns] = from;
					ns = ns + 1;
				end
				from = from + 1;
			end
			if (ns != 0) begin
				for (j = 0; j < ns; j = j + 1) begin
					$fwrite(fd, "  image %4d", sel[j]);
					spaces(fd, COLW - 12);
				end
				$fwrite(fd, "\n");
				for (yy = 0; yy < IMG_H; yy = yy + 1) begin
					for (j = 0; j < ns; j = j + 1) begin
						$fwrite(fd, "  ");
						for (xx = 0; xx < IMG_W; xx = xx + 1) begin
							pc = pix2(sel[j], yy, xx);
							if (WIDE) $fwrite(fd, "%c", pc[7:0]);
							else      $fwrite(fd, "%s", pc);
						end
						$fwrite(fd, "  ");
					end
					$fwrite(fd, "\n");
				end
				for (j = 0; j < ns; j = j + 1) begin
					$fwrite(fd, "  label %0d chip %0d %0s", res_label[sel[j]], res_pred[sel[j]],
					        (res_pred[sel[j]] == res_label[sel[j]]) ? "   " : " <-");
					spaces(fd, COLW - 20);
				end
				$fwrite(fd, "\n");
				for (j = 0; j < ns; j = j + 1) begin
					b1 = 0; b2 = 1;                       // the two largest outputs
					for (m = 0; m < NCLASS; m = m + 1)
						if ($signed(res_prob[sel[j] * NCLASS + m]) > $signed(res_prob[sel[j] * NCLASS + b1])) b1 = m;
					if (b2 == b1) b2 = 0;
					for (m = 0; m < NCLASS; m = m + 1)
						if (m != b1 && $signed(res_prob[sel[j] * NCLASS + m]) > $signed(res_prob[sel[j] * NCLASS + b2])) b2 = m;
					if (SOFTMAX)
						$fwrite(fd, "  %0d:%4.2f  %0d:%4.2f  ", b1, res_prob[sel[j] * NCLASS + b1] / 128.0,
						        b2, res_prob[sel[j] * NCLASS + b2] / 128.0);
					else
						$fwrite(fd, "  %0d:%4d  %0d:%4d  ", b1, $signed(res_prob[sel[j] * NCLASS + b1]),
						        b2, $signed(res_prob[sel[j] * NCLASS + b2]));
					spaces(fd, COLW - 18);
				end
				$fwrite(fd, "\n\n");
			end
		end
	endtask

	task gallery(input integer fd, input integer only_wrong, input integer upto);
		integer from;
		begin
			from = 0;
			while (from < upto) gallery_row(fd, 0, only_wrong, from, upto);
		end
	endtask

	integer fd_res, show_n, n_wrong;

	initial begin
		if ($test$plusargs("vcd")) begin
			$dumpfile("waveforms/model.vcd");
			$dumpvars(0, tb_model);
		end
		for (i = 0; i < EWORDS; i = i + 1) ext_mem[i] = 32'd0;
		$readmemh("model/model_mem.hex", ext_mem);
		$readmemh("model/images.hex", images);
		$readmemh("model/expected.hex", expected);
		$readmemh("model/expmaps.hex", expmaps);

		start = 1'b0; tbl_base = TBL_EB; cyc = 0; mem_on = 1'b0;
		sq_head = 0; sq_tail = 0; sq_count = 0;
		nmap_err = 0; nprob_err = 0; hw_correct = 0; gold_correct = 0; agree = 0; cycles_total = 0;
		rst_n = 1'b0;
		repeat (3) @(negedge clk);
		rst_n = 1'b1;
		repeat (10) @(negedge clk);
		mem_on = 1'b1;

		$display("");
		$display("The trained CNN on the chip: %0d layers, %0d test images (%0dx%0dx%0d), one start per image.", NL, NIMG, IMG_H, IMG_W, IMG_C);
		$display("Every layer's stored int8 map and the written-back probabilities are compared with the Python golden model.");
		$display("");

		mapoff = 0;
		for (img = 0; img < NIMG; img = img + 1) begin
			for (i = 0; i < IMG_WORDS; i = i + 1) ext_mem[IMG_EB + i] = images[img * IMG_WORDS + i];
			for (i = 0; i <= NCLASS; i = i + 1) ext_mem[WB_EB + i] = 32'hDEADBEEF;
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
			if (err_valid) $fatal(1, "image %0d: a layer was rejected, err = %b", img, err);
			cycles_total = cycles_total + (cyc - t0);
			repeat (2) @(negedge clk);

			// every layer's map
			for (l = 0; l < NL; l = l + 1)
				for (c = 0; c < lay_c(l); c = c + 1)
					for (y = 0; y < lay_h(l); y = y + 1)
						for (x = 0; x < lay_w(l); x = x + 1) begin
							k  = bufpos(l, c, y, x);
							hv = hw_map[l][k];
							ev = expmaps[mapoff];
							mapoff = mapoff + 1;
							if (hw_wr[l][k] != 1 || hv != ev) begin
								nmap_err = nmap_err + 1;
								if (nmap_err <= 5) $display("FAIL image %0d layer %0d (%0d,%0d,%0d): chip %0d, golden %0d", img, l, c, y, x, hv, ev);
							end
						end

			// the written-back probabilities and the prediction
			label = expected[img * (NCLASS + 2) + NCLASS];
			gpred = expected[img * (NCLASS + 2) + NCLASS + 1];
			best  = 0;
			for (i = 0; i < NCLASS; i = i + 1) begin
				hv = ext_mem[WB_EB + 1 + i][7:0];
				ev = expected[img * (NCLASS + 2) + i][7:0];
				if (hv != ev) begin
					nprob_err = nprob_err + 1;
					if (nprob_err <= 5) $display("FAIL image %0d class %0d: chip %0d, golden %0d", img, i, hv, ev);
				end
				if ($signed(ext_mem[WB_EB + 1 + i][7:0]) > $signed(ext_mem[WB_EB + 1 + best][7:0])) best = i;   // first largest
			end
			pred = best;
			if (pred == label) hw_correct = hw_correct + 1;
			if (gpred == label) gold_correct = gold_correct + 1;
			if (pred == gpred) agree = agree + 1;

			res_pred[img]  = pred;
			res_label[img] = label;
			res_cyc[img]   = cyc - t0;
			for (i = 0; i < NCLASS; i = i + 1) res_prob[img * NCLASS + i] = ext_mem[WB_EB + 1 + i][7:0];
			if (img % 60 == 59)
				$display("    ... %0d images done, running accuracy %0d/%0d", img + 1, hw_correct, img + 1);
		end

		// the gallery: the first images (or all with +all), then every misclassified one; everything in a file
		show_n = ($test$plusargs("all") || NIMG < 60) ? NIMG : 60;
		$display("");
		$display("The first %0d test images as the chip saw them (%0dx%0d, # dark . faint), with label, chip prediction", show_n, IMG_H, IMG_W);
		$display("and the chip's two largest %0s (<- marks a misclassified digit):", SOFTMAX ? "probabilities" : "logits");
		$display("");
		gallery(32'h8000_0001, 0, show_n);
		n_wrong = 0;
		for (i = 0; i < NIMG; i = i + 1) if (res_pred[i] != res_label[i]) n_wrong = n_wrong + 1;
		$display("All %0d misclassified images:", n_wrong);
		$display("");
		gallery(32'h8000_0001, 1, NIMG);

		fd_res = $fopen("outputs/model_results.txt", "w");
		$fdisplay(fd_res, "All %0d test images: label, chip prediction, cycles, and all %0d probabilities (x128 / 128)", NIMG, NCLASS);
		for (img = 0; img < NIMG; img = img + 1) begin
			$fwrite(fd_res, "image %3d  label %0d  chip %0d %0s  %5d cycles  probabilities:", img, res_label[img], res_pred[img],
			        (res_pred[img] == res_label[img]) ? " ok   " : " WRONG", res_cyc[img]);
			for (i = 0; i < NCLASS; i = i + 1) $fwrite(fd_res, " %0d:%4.2f", i, res_prob[img * NCLASS + i] / 128.0);
			$fwrite(fd_res, "\n");
		end
		$fdisplay(fd_res, "");
		gallery(fd_res, 0, NIMG);
		$fclose(fd_res);
		$display("Every image with all its probabilities, and the full gallery: outputs/model_results.txt");

		$display("");
		$display("Accuracy on %0d test images:", NIMG);
		$display("    float model (Python)              %0d.%02d%%", FLOAT_ACC_X10000 / 100, FLOAT_ACC_X10000 % 100);
		$display("    integer golden model (Python)     %0d.%02d%%  (%0d of the %0d the chip ran)", INT_ACC_X10000 / 100, INT_ACC_X10000 % 100, gold_correct, NIMG);
		$display("    the chip (RTL)                    %0d correct = %0d.%02d%%", hw_correct,
		         hw_correct * 100 / NIMG, (hw_correct * 10000 / NIMG) % 100);
		$display("    chip and golden model predict the same class on %0d of %0d images", agree, NIMG);
		$display("    %0d layer-map bytes and %0d probabilities differ from the golden model", nmap_err, nprob_err);
		$display("    %0d cycles per image on average (%0.1f us at 100 MHz)", cycles_total / NIMG, cycles_total / NIMG / 100.0);
		$display("    (accuracies of the Python models are over all their test images; the chip's over the %0d it ran)", NIMG);
		$display("");
		if (nmap_err + nprob_err != 0 || agree != NIMG) $fatal(1, "FAIL");
		$display("PASS: the chip computes exactly what the golden model computes, on every layer of every image");
		$finish;
	end
endmodule
