module act_feeder #(
    parameter ADDR    = 11,
    parameter DIMW    = 8,
    parameter KW_W    = 3,
    parameter CW      = 8,
    parameter OUT_REG = 1
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
    input         [2:0]            stride,
    input  signed [ADDR+2:0]       step_kh,
    input  signed [ADDR+2:0]       step_c,
    input         [31:0]           mem_rdata0,
    input         [31:0]           mem_rdata1,
    output reg                     busy,
    output                         mem_en,
    output        [ADDR-1:0]       mem_addr0,
    output        [ADDR-1:0]       mem_addr1,
    output                         iss,
    output reg    [31:0]           lanes,
    output reg                     valid,
    output reg                     first,
    output reg                     last
);
	reg signed [ADDR+2:0] s;
	reg signed [DIMW+1:0] y, x, x0_l, y0_l;
	reg        [3:0]      lane_on_l;
	reg        [KW_W-1:0] kw, kh;
	reg        [CW-1:0]   c;
	reg                   half;

	wire signed [DIMW+1:0] h_s    = $signed({2'b00, in_h});
	wire signed [DIMW+1:0] w_s    = $signed({2'b00, in_w});
	wire        [3:0]      s1     = {1'b0, stride};
	wire        [3:0]      s3     = s1 + {s1[2:0], 1'b0};
	wire                   row_ok = (y >= 0) && (y < h_s);
	wire        [1:0]      off    = s[1:0];
	wire        [4:0]      span   = {3'b000, off} + {1'b0, s3};
	wire                   two    = row_ok && (span >= 5'd8);
	wire                   k_first = (c == {CW{1'b0}}) && (kh == {KW_W{1'b0}}) && (kw == {KW_W{1'b0}});
	wire                   k_last  = (c == c_max) && (kh == kh_max) && (kw == kw_max);
	wire        [ADDR-1:0] w0     = s[ADDR+1:2];
	wire        [3:0]      mask;

	assign iss       = busy && (!two || half);
	assign mem_en    = busy && row_ok;
	assign mem_addr0 = w0 + {{(ADDR-2){1'b0}}, half, 1'b0};
	assign mem_addr1 = w0 + {{(ADDR-2){1'b0}}, half, 1'b1};

	genvar i;
	generate
		for (i = 0; i < 4; i = i + 1) begin : LMASK
			localparam [3:0] MUL = i;
			wire [5:0]             step = MUL[1:0] == 2'd0 ? 6'd0 :
			                              MUL[1:0] == 2'd1 ? {2'b00, s1} :
			                              MUL[1:0] == 2'd2 ? {1'b0, s1, 1'b0} : {2'b00, s3};
			wire signed [DIMW+1:0] xi   = x + $signed({{(DIMW-4){1'b0}}, step});

			assign mask[i] = row_ok && lane_on_l[i] && (xi >= 0) && (xi < w_s);
		end
	endgenerate

	reg        q_slot, q_iss, q_two, q_first, q_last;
	reg  [1:0] q_off;
	reg  [3:0] q_mask, q_sel_s1;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			q_slot   <= 1'b0;
			q_iss    <= 1'b0;
			q_two    <= 1'b0;
			q_first  <= 1'b0;
			q_last   <= 1'b0;
			q_off    <= 2'b00;
			q_mask   <= 4'b0000;
			q_sel_s1 <= 4'd0;
		end
		else begin
			q_slot   <= busy;
			q_iss    <= iss;
			q_two    <= two;
			q_first  <= k_first;
			q_last   <= k_last;
			q_off    <= off;
			q_mask   <= iss ? mask : 4'b0000;
			q_sel_s1 <= s1;
		end
	end

	wire        p_slot, p_iss, p_two, p_first, p_last;
	wire [1:0]  p_off;
	wire [3:0]  p_mask, p_s1;
	wire [31:0] d0, d1;

	generate
		if (OUT_REG != 0) begin : OREG
			reg        r_slot, r_iss, r_two, r_first, r_last;
			reg  [1:0] r_off;
			reg  [3:0] r_mask, r_s1;
			reg [31:0] r_d0, r_d1;

			always @(posedge clk or negedge rst_n) begin
				if (!rst_n) begin
					r_slot  <= 1'b0;
					r_iss   <= 1'b0;
					r_two   <= 1'b0;
					r_first <= 1'b0;
					r_last  <= 1'b0;
					r_off   <= 2'b00;
					r_mask  <= 4'b0000;
					r_s1    <= 4'd0;
					r_d0    <= 32'h0;
					r_d1    <= 32'h0;
				end
				else begin
					r_slot  <= q_slot;
					r_iss   <= q_iss;
					r_two   <= q_two;
					r_first <= q_first;
					r_last  <= q_last;
					r_off   <= q_off;
					r_mask  <= q_mask;
					r_s1    <= q_sel_s1;
					r_d0    <= mem_rdata0;
					r_d1    <= mem_rdata1;
				end
			end

			assign p_slot  = r_slot;
			assign p_iss   = r_iss;
			assign p_two   = r_two;
			assign p_first = r_first;
			assign p_last  = r_last;
			assign p_off   = r_off;
			assign p_mask  = r_mask;
			assign p_s1    = r_s1;
			assign d0      = r_d0;
			assign d1      = r_d1;
		end
		else begin : NOREG
			assign p_slot  = q_slot;
			assign p_iss   = q_iss;
			assign p_two   = q_two;
			assign p_first = q_first;
			assign p_last  = q_last;
			assign p_off   = q_off;
			assign p_mask  = q_mask;
			assign p_s1    = q_sel_s1;
			assign d0      = mem_rdata0;
			assign d1      = mem_rdata1;
		end
	endgenerate

	reg  [63:0]  lo;
	wire [127:0] win = p_two ? {d1, d0, lo} : {64'h0, d1, d0};
	wire [3:0]   p_s3 = p_s1 + {p_s1[2:0], 1'b0};
	wire [31:0]  picked;

	generate
		for (i = 0; i < 4; i = i + 1) begin : PICK
			localparam [1:0] LI = i;
			wire [3:0] stepb = LI == 2'd0 ? 4'd0 :
			                   LI == 2'd1 ? p_s1 :
			                   LI == 2'd2 ? {p_s1[2:0], 1'b0} : p_s3;
			wire [3:0] sel   = {2'b00, p_off} + stepb;

			assign picked[i*8 +: 8] = win[sel*8 +: 8] & {8{p_mask[i]}};
		end
	endgenerate

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			lo    <= 64'h0;
			lanes <= 32'h0;
			valid <= 1'b0;
			first <= 1'b0;
			last  <= 1'b0;
		end
		else begin
			if (p_slot && !p_iss) lo <= {d1, d0};
			valid <= p_slot && p_iss;
			first <= p_slot && p_iss && p_first;
			last  <= p_slot && p_iss && p_last;
			lanes <= (p_slot && p_iss) ? picked : 32'h0;
		end
	end

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
			half      <= 1'b0;
		end
		else if (busy) begin
			if (!iss)
				half <= 1'b1;
			else begin
				half <= 1'b0;
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
			half      <= 1'b0;
		end
	end
endmodule
