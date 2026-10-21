module Processing_Element #(
	parameter WIDTH = 8
)(
	output reg signed [WIDTH-1:0]   E, S,
	output reg signed [4*WIDTH-1:0] result,
	output reg                      done,
	input      signed [WIDTH-1:0]   N, W,
	input                           clk, rst_n,
	input                           en
);
	wire signed [2*WIDTH-1:0] prod;
	wire signed [4*WIDTH-1:0] prod_ext;
	wire                      start, finish;
	reg  signed [4*WIDTH-1:0] acc;
	reg                       en_q;

	assign prod     = N * W;
	assign prod_ext = {{(2*WIDTH){prod[2*WIDTH-1]}}, prod};
	assign start    = en & ~en_q;
	assign finish   = ~en & en_q;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			acc    <= {4*WIDTH{1'b0}};
			result <= {4*WIDTH{1'b0}};
			E      <= {WIDTH{1'b0}};
			S      <= {WIDTH{1'b0}};
			en_q   <= 1'b0;
			done   <= 1'b0;
		end
		else begin
			en_q <= en;
			done <= finish;
			if (en) begin
				if (start) acc <= prod_ext;
				else       acc <= acc + prod_ext;
				E <= W;
				S <= N;
			end
			if (finish) result <= acc;
		end
	end
endmodule
