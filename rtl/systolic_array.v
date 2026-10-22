module systolic_array #(
	parameter TILE_MAX = 4,
	parameter WIDTH    = 8
)(
	output reg signed [TILE_MAX*4*WIDTH-1:0]          c_col,
	output reg        [TILE_MAX*$clog2(TILE_MAX)-1:0] c_row,
	output reg        [TILE_MAX-1:0]                  c_valid,
	output            [TILE_MAX*TILE_MAX-1:0]         pe_done,
	output                                            done,
	input  signed     [TILE_MAX*WIDTH-1:0]            a,
	input  signed     [TILE_MAX*WIDTH-1:0]            b,
	input                                             clk, rst_n,
	input                                             en
);
	localparam ACC_W = 4*WIDTH;
	localparam ROW_W = $clog2(TILE_MAX);
	localparam NDIAG = 2*TILE_MAX - 1;

	wire signed [WIDTH-1:0] south  [0:TILE_MAX-1][0:TILE_MAX-1];
	wire signed [WIDTH-1:0] east   [0:TILE_MAX-1][0:TILE_MAX-1];
	wire signed [ACC_W-1:0] result [0:TILE_MAX-1][0:TILE_MAX-1];
	wire        [NDIAG-1:0] en_d;
	wire                    rst_n_sync;
	reg         [NDIAG-1:1] en_pipe;

	reset_sync RST_SYNC (.rst_sync(rst_n_sync), .rst_async(rst_n), .clk(clk));

	assign en_d = {en_pipe, en};
	assign done = pe_done[TILE_MAX*TILE_MAX-1];

	always @(posedge clk or negedge rst_n_sync) begin
		if (!rst_n_sync) en_pipe <= {(NDIAG-1){1'b0}};
		else             en_pipe <= en_d[NDIAG-2:0];
	end

	genvar i, j;
	generate
		for (i = 0; i < TILE_MAX; i = i + 1) begin : ROW
			for (j = 0; j < TILE_MAX; j = j + 1) begin : COL
				wire signed [WIDTH-1:0] n_in, w_in;

				if (i == 0) begin : N_EDGE
					assign n_in = a[j*WIDTH +: WIDTH];
				end else begin : N_INNER
					assign n_in = south[i-1][j];
				end

				if (j == 0) begin : W_EDGE
					assign w_in = b[i*WIDTH +: WIDTH];
				end else begin : W_INNER
					assign w_in = east[i][j-1];
				end

				Processing_Element #(.WIDTH(WIDTH)) PE (
					.clk(clk), .rst_n(rst_n_sync), .en(en_d[i+j]),
					.N(n_in), .W(w_in), .E(east[i][j]), .S(south[i][j]),
					.result(result[i][j]),
					.done(pe_done[i*TILE_MAX + j])
				);
			end
		end
	endgenerate

	integer r, cl;
	always @* begin
		c_col   = {(TILE_MAX*ACC_W){1'b0}};
		c_row   = {(TILE_MAX*ROW_W){1'b0}};
		c_valid = {TILE_MAX{1'b0}};
		for (cl = 0; cl < TILE_MAX; cl = cl + 1)
			for (r = 0; r < TILE_MAX; r = r + 1)
				if (pe_done[r*TILE_MAX + cl]) begin
					c_col[cl*ACC_W +: ACC_W] = c_col[cl*ACC_W +: ACC_W] | result[r][cl];
					c_row[cl*ROW_W +: ROW_W] = r;
					c_valid[cl] = 1'b1;
				end
	end
endmodule
