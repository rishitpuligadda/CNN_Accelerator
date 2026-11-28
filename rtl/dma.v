// Reads from external memory into an on-chip buffer: nblk blocks of nwords words each; block k starts at
// ext_base + k * ext_stride, and the blocks land one after another in the buffer from sram_base on.
// (nblk = 1: one contiguous copy, as for weights.) Requests are issued as fast as the memory accepts them;
// done pulses once the last response has been written.
module dma #(
	parameter EAW = 24,
	parameter SAW = 11
)(
	input                clk,
	input                rst_n,
	input                start,
	input      [EAW-1:0] ext_base,
	input      [EAW-1:0] ext_stride,
	input      [SAW-1:0] sram_base,
	input      [SAW:0]   nwords,
	input      [7:0]     nblk,
	output reg           busy,
	output reg           done,
	output               rd_req_valid,
	input                rd_req_ready,
	output     [EAW-1:0] rd_req_addr,
	input                rd_resp_valid,
	input      [31:0]    rd_resp_data,
	output               rd_resp_ready,
	output reg           wr_en,
	output reg [SAW-1:0] wr_addr,
	output reg [31:0]    wr_data
);
	reg  [EAW-1:0] req_ptr, blk_ptr, stride_q;
	reg  [SAW:0]   req_left, words_q;     // words left to request in this block; block length
	reg  [7:0]     blk_left;              // blocks left to request after this one
	reg            req_fin;               // every request issued
	reg  [SAW+8:0] pend;                  // requests issued but not answered yet
	reg  [SAW-1:0] wr_ptr;
	reg            last_q;
	wire           req_fire, resp_fire;

	assign rd_req_valid  = busy && !req_fin;
	assign rd_req_addr   = req_ptr;
	assign rd_resp_ready = busy;

	assign req_fire  = rd_req_valid && rd_req_ready;
	assign resp_fire = rd_resp_valid && rd_resp_ready;

	wire           blk_end  = (req_left == {{SAW{1'b0}}, 1'b1});
	wire [SAW+8:0] pend_nx  = pend + {{(SAW+8){1'b0}}, req_fire} - {{(SAW+8){1'b0}}, resp_fire};

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			busy     <= 1'b0;
			done     <= 1'b0;
			last_q   <= 1'b0;
			wr_en    <= 1'b0;
			wr_addr  <= {SAW{1'b0}};
			wr_data  <= 32'h0;
			req_ptr  <= {EAW{1'b0}};
			blk_ptr  <= {EAW{1'b0}};
			stride_q <= {EAW{1'b0}};
			req_left <= {(SAW+1){1'b0}};
			words_q  <= {(SAW+1){1'b0}};
			blk_left <= 8'd0;
			req_fin  <= 1'b0;
			pend     <= {(SAW+9){1'b0}};
			wr_ptr   <= {SAW{1'b0}};
		end
		else begin
			done    <= last_q;
			last_q  <= 1'b0;
			wr_en   <= resp_fire;
			wr_addr <= wr_ptr;
			wr_data <= rd_resp_data;

			if (!busy) begin
				if (start && (nwords == 0 || nblk == 8'd0))
					last_q <= 1'b1;
				else if (start) begin
					busy     <= 1'b1;
					req_ptr  <= ext_base;
					blk_ptr  <= ext_base;
					stride_q <= ext_stride;
					req_left <= nwords;
					words_q  <= nwords;
					blk_left <= nblk - 8'd1;
					req_fin  <= 1'b0;
					pend     <= {(SAW+9){1'b0}};
					wr_ptr   <= sram_base;
				end
			end
			else begin
				if (req_fire) begin
					if (!blk_end) begin
						req_ptr  <= req_ptr + 1'b1;
						req_left <= req_left - 1'b1;
					end
					else if (blk_left != 8'd0) begin                  // next block
						req_ptr  <= blk_ptr + stride_q;
						blk_ptr  <= blk_ptr + stride_q;
						req_left <= words_q;
						blk_left <= blk_left - 8'd1;
					end
					else
						req_fin <= 1'b1;
				end
				if (resp_fire)
					wr_ptr <= wr_ptr + 1'b1;
				pend <= pend_nx;
				if ((req_fin || (req_fire && blk_end && blk_left == 8'd0)) && pend_nx == 0) begin
					busy   <= 1'b0;
					last_q <= 1'b1;
				end
			end
		end
	end
endmodule
