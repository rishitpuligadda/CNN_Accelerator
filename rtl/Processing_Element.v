module Processing_Element #(
	parameter WIDTH = 8
)(
	output reg signed [WIDTH-1:0]   E, S,
	output     signed [4*WIDTH-1:0] result,
	output reg                      done,
	input      signed [WIDTH-1:0]   N, W,
	input                           clk, rst_n,
	input                           en,
	input                           first,
	input                           last
);
	wire signed [2*WIDTH-1:0] prod;
	wire signed [4*WIDTH-1:0] prod_ext;
	reg  signed [4*WIDTH-1:0] acc;

	assign prod     = N * W;
	assign prod_ext = {{(2*WIDTH){prod[2*WIDTH-1]}}, prod};
	assign result   = acc;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			acc  <= {4*WIDTH{1'b0}};
			E    <= {WIDTH{1'b0}};
			S    <= {WIDTH{1'b0}};
			done <= 1'b0;
		end
		else begin
			done <= en && last;
			if (en) begin
				if (first) acc <= prod_ext;
				else       acc <= acc + prod_ext;
				E <= W;
				S <= N;
			end
		end
	end
endmodule
