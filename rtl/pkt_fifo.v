module pkt_fifo #(
    parameter W     = 144,
    parameter DEPTH = 8
) (
    input              clk,
    input              rst_n,
    input              push,
    input  [W-1:0]     din,
    output             out_valid,
    input              out_ready,
    output [W-1:0]     dout,
    output             full
);
	localparam AW = $clog2(DEPTH);

	reg  [W-1:0]  mem [0:DEPTH-1];
	reg  [AW-1:0] rd_ptr, wr_ptr;
	reg  [AW:0]   count;
	wire          pop = out_valid && out_ready;

	assign out_valid = (count != {(AW+1){1'b0}});
	assign full      = (count == DEPTH[AW:0]);
	assign dout      = mem[rd_ptr];

	always @(posedge clk) begin
		if (push && !full) mem[wr_ptr] <= din;
	end

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			rd_ptr <= {AW{1'b0}};
			wr_ptr <= {AW{1'b0}};
			count  <= {(AW+1){1'b0}};
		end
		else begin
			if (push && !full) wr_ptr <= wr_ptr + 1'b1;
			if (pop)           rd_ptr <= rd_ptr + 1'b1;
			if ((push && !full) && !pop)      count <= count + 1'b1;
			else if (!(push && !full) && pop) count <= count - 1'b1;
		end
	end

`ifndef SYNTHESIS
	always @(negedge clk) begin
		if (push && full)
			$display("ERROR %m t=%0t: packet pushed into a full FIFO (credits failed)", $time);
	end
`endif
endmodule
