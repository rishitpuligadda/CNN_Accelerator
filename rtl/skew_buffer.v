module skew_buffer #(
	parameter LANES = 4,
	parameter WIDTH = 8
)(
	input                    clk,
	input                    rst_n,
	input  [LANES*WIDTH-1:0] din,
	output [LANES*WIDTH-1:0] dout
);
	assign dout[WIDTH-1:0] = din[WIDTH-1:0];

	genvar i;
	generate
		for (i = 1; i < LANES; i = i + 1) begin : LANE
			reg [i*WIDTH-1:0] sr;

			if (i == 1) begin : D1
				always @(posedge clk or negedge rst_n) begin
					if (!rst_n) sr <= {WIDTH{1'b0}};
					else        sr <= din[WIDTH +: WIDTH];
				end
			end
			else begin : DN
				always @(posedge clk or negedge rst_n) begin
					if (!rst_n) sr <= {(i*WIDTH){1'b0}};
					else        sr <= {sr[(i-1)*WIDTH-1:0], din[i*WIDTH +: WIDTH]};
				end
			end

			assign dout[i*WIDTH +: WIDTH] = sr[i*WIDTH-1 -: WIDTH];
		end
	endgenerate
endmodule
