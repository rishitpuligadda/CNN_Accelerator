module result_collector #(
    parameter N     = 4,
    parameter ACC_W = 32,
    parameter ADDR  = 11,
    parameter QD    = 4
) (
    input                          clk,
    input                          rst_n,
    input      [N*ACC_W-1:0]       c_col,
    input      [N*$clog2(N)-1:0]   c_row,
    input      [N-1:0]             c_valid,
    input      [ADDR-1:0]          ch_pitch,
    input                          desc_push,
    input      [ADDR-1:0]          desc_addr,
    input      [N-1:0]             desc_lanes,
    input      [N-1:0]             desc_cols,
    output                         desc_full,
    output reg                     pkt_valid,
    output reg [N*ACC_W-1:0]       pkt_data,
    output reg [ADDR-1:0]          pkt_addr,
    output reg [N-1:0]             pkt_be,
    output reg                     pkt_last
);
	localparam RW = $clog2(N);
	localparam QW = $clog2(QD);
	localparam integer LASTI = N - 1;

	reg  [ADDR-1:0]      q_addr  [0:QD-1];
	reg  [N-1:0]         q_lanes [0:QD-1];
	reg  [N-1:0]         q_cols  [0:QD-1];
	reg  [QW-1:0]        rd_ptr, wr_ptr;
	reg  [QW:0]          count;

	wire [ADDR-1:0]      h_addr  = q_addr[rd_ptr];
	wire [N-1:0]         h_lanes = q_lanes[rd_ptr];
	wire [N-1:0]         h_cols  = q_cols[rd_ptr];

	wire [N-1:0]         fin;
	wire [N-1:0]         is_last;
	wire [N*ACC_W-1:0]   word   [0:N-1];
	wire [N*ADDR-1:0]    pmul;
	reg  [N*ACC_W-1:0]   sel_data;
	reg  [ADDR-1:0]      sel_addr;
	reg                  sel_en, sel_last;
	wire                 pop = fin[N-1];
	integer              jj;

	assign desc_full = (count == QD);

	genvar j;
	generate
		for (j = 0; j < N; j = j + 1) begin : COL
			reg [(N-1)*ACC_W-1:0] hold;
			wire [RW-1:0]         row = c_row[j*RW +: RW];

			reg [ADDR-1:0] pm;

			always @(posedge clk or negedge rst_n) begin
				if (!rst_n) pm <= {ADDR{1'b0}};
				else        pm <= ch_pitch * j;
			end

			assign pmul[j*ADDR +: ADDR] = pm;

			assign fin[j]  = c_valid[j] && (row == LASTI[RW-1:0]);
			assign word[j] = {c_col[j*ACC_W +: ACC_W], hold};

			if (j == N-1) begin : TOP
				assign is_last[j] = h_cols[j];
			end
			else begin : BELOW
				assign is_last[j] = h_cols[j] && !(|h_cols[N-1:j+1]);
			end

			always @(posedge clk or negedge rst_n) begin
				if (!rst_n)
					hold <= {((N-1)*ACC_W){1'b0}};
				else if (c_valid[j] && row != LASTI[RW-1:0])
					hold[row*ACC_W +: ACC_W] <= c_col[j*ACC_W +: ACC_W];
			end
		end
	endgenerate

	always @* begin
		sel_data = {(N*ACC_W){1'b0}};
		sel_addr = {ADDR{1'b0}};
		sel_en   = 1'b0;
		sel_last = 1'b0;
		for (jj = 0; jj < N; jj = jj + 1) begin
			if (fin[jj]) begin
				sel_data = sel_data | word[jj];
				sel_addr = sel_addr | (h_addr + pmul[jj*ADDR +: ADDR]);
				sel_en   = sel_en   | h_cols[jj];
				sel_last = sel_last | is_last[jj];
			end
		end
	end

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			rd_ptr    <= {QW{1'b0}};
			wr_ptr    <= {QW{1'b0}};
			count     <= {(QW+1){1'b0}};
			pkt_valid <= 1'b0;
			pkt_data  <= {(N*ACC_W){1'b0}};
			pkt_addr  <= {ADDR{1'b0}};
			pkt_be    <= {N{1'b0}};
			pkt_last  <= 1'b0;
		end
		else begin
			if (desc_push && !desc_full) begin
				q_addr[wr_ptr]  <= desc_addr;
				q_lanes[wr_ptr] <= desc_lanes;
				q_cols[wr_ptr]  <= desc_cols;
				wr_ptr          <= wr_ptr + 1'b1;
			end
			if (pop)
				rd_ptr <= rd_ptr + 1'b1;
			if ((desc_push && !desc_full) && !pop)
				count <= count + 1'b1;
			else if (!(desc_push && !desc_full) && pop)
				count <= count - 1'b1;

			pkt_valid <= sel_en;
			pkt_data  <= sel_en ? sel_data : {(N*ACC_W){1'b0}};
			pkt_addr  <= sel_en ? sel_addr : {ADDR{1'b0}};
			pkt_be    <= sel_en ? h_lanes  : {N{1'b0}};
			pkt_last  <= sel_en && sel_last;
		end
	end

`ifndef SYNTHESIS
	always @(negedge clk) begin
		if ((fin & (fin - 1'b1)) != {N{1'b0}})
			$display("ERROR %m t=%0t: two columns finished in the same cycle (%b)", $time, fin);
		if (|fin && count == 0)
			$display("ERROR %m t=%0t: results arrived with no tile descriptor", $time);
	end
`endif
endmodule
