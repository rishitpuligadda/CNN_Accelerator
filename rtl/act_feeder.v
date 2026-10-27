module act_feeder #(
    parameter ADDR = 11,
    parameter DIMW = 8,
    parameter KW_W = 3,
    parameter CW   = 8
) (
    input                          clk,
    input                          rst_n,
    input                          start,
    input  signed [ADDR+2:0]       tile_addr,
    input  signed [DIMW+1:0]       y0,
    input  signed [DIMW+1:0]       x0,
    input         [3:0]            lane_on,
    input         [DIMW-1:0]       in_h,
    input         [DIMW-1:0]       in_w,
    input         [KW_W-1:0]       kh_max,
    input         [KW_W-1:0]       kw_max,
    input         [CW-1:0]         c_max,
    input  signed [ADDR+2:0]       step_kh,
    input  signed [ADDR+2:0]       step_c,
    input         [31:0]           mem_rdata0,
    input         [31:0]           mem_rdata1,
    output reg                     busy,
    output                         mem_en,
    output        [ADDR-1:0]       mem_addr0,
    output        [ADDR-1:0]       mem_addr1,
    output reg    [31:0]           lanes,
    output reg                     valid
);
	reg signed [ADDR+2:0] s;
	reg signed [DIMW+1:0] y, x, x0_l, y0_l;
	reg        [3:0]      lane_on_l;
	reg        [KW_W-1:0] kw, kh;
	reg        [CW-1:0]   c;
	reg                   slot_q;
	reg        [1:0]      off_q;
	reg        [3:0]      mask_q;

	wire signed [DIMW+1:0] h_s = $signed({2'b00, in_h});
	wire signed [DIMW+1:0] w_s = $signed({2'b00, in_w});
	wire                   row_ok = (y >= 0) && (y < h_s);
	wire        [3:0]      mask;
	wire        [63:0]     pair = {mem_rdata1, mem_rdata0};
	wire        [31:0]     picked;

	assign mem_en    = busy && row_ok;
	assign mem_addr0 = s[ADDR+1:2];
	assign mem_addr1 = s[ADDR+1:2] + 1'b1;

	genvar i;
	generate
		for (i = 0; i < 4; i = i + 1) begin : LANE
			localparam signed [DIMW+1:0] OFS = i;
			wire signed [DIMW+1:0] xi  = x + OFS;
			wire        [2:0]      sel = {1'b0, off_q} + i[2:0];

			assign mask[i] = row_ok && lane_on_l[i] && (xi >= 0) && (xi < w_s);
			assign picked[i*8 +: 8] = pair[sel*8 +: 8];
		end
	endgenerate

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			busy      <= 1'b0;
			s         <= {(ADDR+3){1'b0}};
			y         <= {(DIMW+2){1'b0}};
			x         <= {(DIMW+2){1'b0}};
			x0_l      <= {(DIMW+2){1'b0}};
			y0_l      <= {(DIMW+2){1'b0}};
			lane_on_l <= 4'b0000;
			kw        <= {KW_W{1'b0}};
			kh        <= {KW_W{1'b0}};
			c         <= {CW{1'b0}};
			slot_q    <= 1'b0;
			off_q     <= 2'b00;
			mask_q    <= 4'b0000;
			lanes     <= 32'h0;
			valid     <= 1'b0;
		end
		else begin
			slot_q <= busy;
			off_q  <= s[1:0];
			mask_q <= busy ? mask : 4'b0000;
			valid  <= slot_q;
			lanes  <= picked & {{8{slot_q && mask_q[3]}}, {8{slot_q && mask_q[2]}},
			                    {8{slot_q && mask_q[1]}}, {8{slot_q && mask_q[0]}}};

			if (busy) begin
				if (kw != kw_max) begin
					kw <= kw + 1'b1;
					s  <= s + 1'b1;
					x  <= x + 1'b1;
				end
				else if (kh != kh_max) begin
					kw <= {KW_W{1'b0}};
					kh <= kh + 1'b1;
					s  <= s + step_kh;
					x  <= x0_l;
					y  <= y + 1'b1;
				end
				else begin
					kw <= {KW_W{1'b0}};
					kh <= {KW_W{1'b0}};
					c  <= c + 1'b1;
					s  <= s + step_c;
					x  <= x0_l;
					y  <= y0_l;
					if (c == c_max) busy <= 1'b0;
				end
			end
			else if (start) begin
				busy      <= 1'b1;
				s         <= tile_addr;
				y         <= y0;
				x         <= x0;
				x0_l      <= x0;
				y0_l      <= y0;
				lane_on_l <= lane_on;
				kw        <= {KW_W{1'b0}};
				kh        <= {KW_W{1'b0}};
				c         <= {CW{1'b0}};
			end
		end
	end
endmodule
