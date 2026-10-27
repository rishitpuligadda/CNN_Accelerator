module dma #(
	parameter EAW = 16,
	parameter SAW = 11
)(
	input                clk,
	input                rst_n,
	input                start,
	input      [EAW-1:0] ext_base,
	input      [SAW-1:0] sram_base,
	input      [SAW:0]   nwords,
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
	reg  [EAW-1:0] req_ptr;
	reg  [SAW:0]   req_left;
	reg  [SAW-1:0] wr_ptr;
	reg  [SAW:0]   wr_left;
	reg            last_q;
	wire           req_fire, resp_fire;

	assign rd_req_valid  = busy && req_left != 0;
	assign rd_req_addr   = req_ptr;
	assign rd_resp_ready = busy;

	assign req_fire  = rd_req_valid && rd_req_ready;
	assign resp_fire = rd_resp_valid && rd_resp_ready;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			busy     <= 1'b0;
			done     <= 1'b0;
			last_q   <= 1'b0;
			wr_en    <= 1'b0;
			wr_addr  <= {SAW{1'b0}};
			wr_data  <= 32'h0;
			req_ptr  <= {EAW{1'b0}};
			req_left <= {(SAW+1){1'b0}};
			wr_ptr   <= {SAW{1'b0}};
			wr_left  <= {(SAW+1){1'b0}};
		end
		else begin
			done    <= last_q;
			last_q  <= 1'b0;
			wr_en   <= resp_fire;
			wr_addr <= wr_ptr;
			wr_data <= rd_resp_data;

			if (!busy) begin
				if (start && nwords == 0)
					last_q <= 1'b1;
				else if (start) begin
					busy     <= 1'b1;
					req_ptr  <= ext_base;
					req_left <= nwords;
					wr_ptr   <= sram_base;
					wr_left  <= nwords;
				end
			end
			else begin
				if (req_fire) begin
					req_ptr  <= req_ptr + 1'b1;
					req_left <= req_left - 1'b1;
				end
				if (resp_fire) begin
					wr_ptr  <= wr_ptr + 1'b1;
					wr_left <= wr_left - 1'b1;
					if (wr_left == 1) begin
						busy   <= 1'b0;
						last_q <= 1'b1;
					end
				end
			end
		end
	end
endmodule
