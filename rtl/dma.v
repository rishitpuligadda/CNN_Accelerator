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
	output               ext_rd_en,
	output     [EAW-1:0] ext_addr,
	input      [31:0]    ext_rdata,
	output reg           wr_en,
	output reg [SAW-1:0] wr_addr,
	output     [31:0]    wr_data
);
	reg [EAW-1:0] ext_ptr;
	reg [SAW-1:0] sram_ptr;
	reg [SAW:0]   left;
	reg           last_q;

	assign ext_rd_en = busy;
	assign ext_addr  = ext_ptr;
	assign wr_data   = ext_rdata;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			busy     <= 1'b0;
			done     <= 1'b0;
			wr_en    <= 1'b0;
			wr_addr  <= {SAW{1'b0}};
			ext_ptr  <= {EAW{1'b0}};
			sram_ptr <= {SAW{1'b0}};
			left     <= {(SAW+1){1'b0}};
			last_q   <= 1'b0;
		end
		else begin
			done    <= (wr_en && last_q) || (start && !busy && nwords == 0);
			wr_en   <= busy;
			wr_addr <= sram_ptr;
			last_q  <= busy && left == 1;
			if (busy) begin
				ext_ptr  <= ext_ptr + 1'b1;
				sram_ptr <= sram_ptr + 1'b1;
				left     <= left - 1'b1;
				if (left == 1) busy <= 1'b0;
			end
			else if (start && nwords != 0) begin
				busy     <= 1'b1;
				ext_ptr  <= ext_base;
				sram_ptr <= sram_base;
				left     <= nwords;
			end
		end
	end
endmodule
