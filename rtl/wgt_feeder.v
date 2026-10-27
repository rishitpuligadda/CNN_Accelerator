module wgt_feeder #(
    parameter WIDTH   = 32,
    parameter ADDR    = 10,
    parameter OUT_REG = 1
) (
    input                  clk,
    input                  rst_n,
    input                  start,
    input      [ADDR-1:0]  base,
    input                  adv,
    input      [WIDTH-1:0] mem_rdata,
    output                 mem_en,
    output     [ADDR-1:0]  mem_addr,
    output reg [WIDTH-1:0] lanes,
    output reg             valid
);
	reg  [ADDR-1:0] ptr;
	reg             q_slot;
	wire            p_slot;
	wire [WIDTH-1:0] d;

	assign mem_en   = adv;
	assign mem_addr = ptr;

	generate
		if (OUT_REG != 0) begin : OREG
			reg             r_slot;
			reg [WIDTH-1:0] r_d;

			always @(posedge clk or negedge rst_n) begin
				if (!rst_n) begin
					r_slot <= 1'b0;
					r_d    <= {WIDTH{1'b0}};
				end
				else begin
					r_slot <= q_slot;
					r_d    <= mem_rdata;
				end
			end

			assign p_slot = r_slot;
			assign d      = r_d;
		end
		else begin : NOREG
			assign p_slot = q_slot;
			assign d      = mem_rdata;
		end
	endgenerate

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			ptr    <= {ADDR{1'b0}};
			q_slot <= 1'b0;
			lanes  <= {WIDTH{1'b0}};
			valid  <= 1'b0;
		end
		else begin
			q_slot <= adv;
			valid  <= p_slot;
			lanes  <= p_slot ? d : {WIDTH{1'b0}};
			if (start)    ptr <= base;
			else if (adv) ptr <= ptr + 1'b1;
		end
	end
endmodule
