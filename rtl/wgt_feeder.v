module wgt_feeder #(
    parameter WIDTH = 32,
    parameter ADDR  = 10
) (
    input                  clk,
    input                  rst_n,
    input                  start,
    input      [ADDR-1:0]  base,
    input      [ADDR:0]    m,
    input      [WIDTH-1:0] mem_rdata,
    output reg             busy,
    output                 mem_en,
    output     [ADDR-1:0]  mem_addr,
    output reg [WIDTH-1:0] lanes,
    output reg             valid
);
	reg [ADDR-1:0] mem_ptr;
	reg [ADDR:0]   left;
	reg            rd_q;

	assign mem_en   = busy;
	assign mem_addr = mem_ptr;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			busy    <= 1'b0;
			mem_ptr <= {ADDR{1'b0}};
			left    <= {(ADDR+1){1'b0}};
			rd_q    <= 1'b0;
			lanes   <= {WIDTH{1'b0}};
			valid   <= 1'b0;
		end
		else begin
			rd_q  <= busy;
			valid <= rd_q;
			lanes <= rd_q ? mem_rdata : {WIDTH{1'b0}};

			if (busy) begin
				mem_ptr <= mem_ptr + 1'b1;
				left    <= left - 1'b1;
				if (left == 1) busy <= 1'b0;
			end
			else if (start && m != 0) begin
				busy    <= 1'b1;
				mem_ptr <= base;
				left    <= m;
			end
		end
	end
endmodule
