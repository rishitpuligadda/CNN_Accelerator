module systolic_array #(
	parameter TILE_MAX = 4,
	parameter WIDTH    = 8
)(
	output reg signed [TILE_MAX*4*WIDTH-1:0]          c_col,
	output reg        [TILE_MAX*$clog2(TILE_MAX)-1:0] c_row,
	output reg        [TILE_MAX-1:0]                  c_valid,
	input  signed     [TILE_MAX*WIDTH-1:0]            a,
	input  signed     [TILE_MAX*WIDTH-1:0]            b,
	input                                             clk, rst_n,
	input                                             en,
	input                                             first,
	input                                             last,
	input  signed     [TILE_MAX*4*WIDTH-1:0]          bias
);
	localparam ACC_W = 4*WIDTH;
	localparam ROW_W = $clog2(TILE_MAX);
	localparam NDIAG = 2*TILE_MAX - 1;

	wire signed [WIDTH-1:0] south  [0:TILE_MAX-1][0:TILE_MAX-1];
	wire signed [WIDTH-1:0] east   [0:TILE_MAX-1][0:TILE_MAX-1];
	wire signed [ACC_W-1:0] result [0:TILE_MAX-1][0:TILE_MAX-1];
	wire        [TILE_MAX*TILE_MAX-1:0] pe_done;
	wire        [NDIAG-1:0] en_d, first_d, last_d;
	reg         [NDIAG-1:1] en_pipe, first_pipe, last_pipe;

	assign en_d    = {en_pipe, en};
	assign first_d = {first_pipe, first};
	assign last_d  = {last_pipe, last};

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			en_pipe    <= {(NDIAG-1){1'b0}};
			first_pipe <= {(NDIAG-1){1'b0}};
			last_pipe  <= {(NDIAG-1){1'b0}};
		end
		else begin
			en_pipe    <= en_d[NDIAG-2:0];
			first_pipe <= first_d[NDIAG-2:0];
			last_pipe  <= last_d[NDIAG-2:0];
		end
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
					.clk(clk), .rst_n(rst_n),
					.en(en_d[i+j]), .first(first_d[i+j]), .last(last_d[i+j]),
					.bias(bias[j*ACC_W +: ACC_W]),
					.N(n_in), .W(w_in), .E(east[i][j]), .S(south[i][j]),
					.result(result[i][j]),
					.done(pe_done[i*TILE_MAX + j])
				);
			end
		end
	endgenerate

	reg signed [TILE_MAX*ACC_W-1:0] col_n;
	reg        [TILE_MAX*ROW_W-1:0] row_n;
	reg        [TILE_MAX-1:0]       val_n;
	integer r, cl;

	always @* begin
		col_n = {(TILE_MAX*ACC_W){1'b0}};
		row_n = {(TILE_MAX*ROW_W){1'b0}};
		val_n = {TILE_MAX{1'b0}};
		for (cl = 0; cl < TILE_MAX; cl = cl + 1)
			for (r = 0; r < TILE_MAX; r = r + 1)
				if (pe_done[r*TILE_MAX + cl]) begin
					col_n[cl*ACC_W +: ACC_W] = col_n[cl*ACC_W +: ACC_W] | result[r][cl];
					row_n[cl*ROW_W +: ROW_W] = r[ROW_W-1:0];
					val_n[cl] = 1'b1;
				end
	end

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			c_col   <= {(TILE_MAX*ACC_W){1'b0}};
			c_row   <= {(TILE_MAX*ROW_W){1'b0}};
			c_valid <= {TILE_MAX{1'b0}};
		end
		else begin
			c_col   <= col_n;
			c_row   <= row_n;
			c_valid <= val_n;
		end
	end
endmodule
