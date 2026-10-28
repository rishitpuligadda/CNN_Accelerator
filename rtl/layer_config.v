module layer_config #(
    parameter EAW     = 16,
    parameter ADDR    = 11,
    parameter DEPTH_F = 1536,
    parameter DEPTH_W = 1024
) (
    input                          clk,
    input                          rst_n,
    input                          start,
    input                          ctrl_busy,

    input      [EAW-1:0]           img_ext_base,
    input      [EAW-1:0]           wgt_ext_base,
    input      [7:0]               in_h,
    input      [7:0]               in_w,
    input      [7:0]               in_c,
    input      [7:0]               n_filt,
    input      [2:0]               k_h,
    input      [2:0]               k_w,
    input      [2:0]               pad,
    input      [2:0]               stride,
    input      [ADDR-1:0]          out_base,

    output reg                     busy,
    output reg                     go,
    output reg                     bad,
    output reg [6:0]               err,

    output reg [EAW-1:0]           l_img_ext_base,
    output reg [EAW-1:0]           l_wgt_ext_base,
    output reg [ADDR:0]            l_img_words,
    output reg [10:0]              l_m,
    output reg [6:0]               l_n_groups,
    output reg [3:0]               l_last_cols,
    output reg [7:0]               l_in_h,
    output reg [7:0]               l_in_w,
    output reg [2:0]               l_kh_max,
    output reg [2:0]               l_kw_max,
    output reg [7:0]               l_c_max,
    output reg [2:0]               l_pad,
    output reg [2:0]               l_stride,
    output reg signed [ADDR+2:0]   l_step_kh,
    output reg signed [ADDR+2:0]   l_step_c,
    output reg signed [ADDR+2:0]   l_tile_addr0,
    output reg [ADDR+1:0]          l_row_step,
    output reg [7:0]               l_out_h,
    output reg [7:0]               l_out_w,
    output reg [ADDR-1:0]          l_out_base,
    output reg [ADDR-1:0]          l_out_rp_w,
    output reg [ADDR-1:0]          l_out_ch_pitch
);
	localparam S_IDLE = 3'd0;
	localparam S_MUL  = 3'd1;
	localparam S_DIVH = 3'd2;
	localparam S_DIVW = 3'd3;
	localparam S_MUL2 = 3'd4;
	localparam S_CHK  = 3'd5;

	reg  [2:0]  state;
	reg  [3:0]  st;
	reg  [7:0]  r_h, r_w, r_c, r_f;
	reg  [2:0]  r_kh, r_kw, r_pad, r_s;
	reg  [8:0]  rp;
	reg  [15:0] ch, kk, och;
	reg  [ADDR+2:0] khrp, padrp;
	reg  [12:0] sp;
	reg  [13:0] m_full;
	reg  [23:0] cbytes, owords;
	reg  [9:0]  rem;
	reg  [7:0]  q;
	reg         geo_bad;

	reg  [7:0]  ma;
	reg  [15:0] mb;
	wire [23:0] prod = ma * mb;

	wire        zero_bad = (in_h == 8'd0) || (in_w == 8'd0) || (in_c == 8'd0) || (n_filt == 8'd0) ||
	                       (k_h == 3'd0) || (k_w == 3'd0);
	wire        s_bad    = (stride == 3'd0) || (stride > 3'd4);
	wire        p_bad    = (pad > 3'd3) || (pad >= k_h) || (pad >= k_w);

	wire [9:0]  span_h = {2'b00, r_h} + {6'd0, r_pad, 1'b0};
	wire [9:0]  span_w = {2'b00, r_w} + {6'd0, r_pad, 1'b0};
	wire [8:0]  orp9   = ({1'b0, q} + 9'd4) >> 2;
	wire [6:0]      n_grp   = {1'b0, r_f[7:2]} + {6'd0, |r_f[1:0]};
	wire [ADDR+2:0] kw_ext  = {{ADDR{1'b0}}, r_kw};
	wire [ADDR+2:0] one_ext = {{(ADDR+2){1'b0}}, 1'b1};
	wire [ADDR+2:0] sk_v    = {{(ADDR-6){1'b0}}, rp} - kw_ext + one_ext;
	wire [ADDR+2:0] sc_v    = ch[ADDR+2:0] - khrp - kw_ext + one_ext;
	wire [ADDR+2:0] ta_v    = {{(ADDR){1'b0}}, 3'd4} - padrp - {{ADDR{1'b0}}, r_pad};
	wire [24:0] out_end = {14'd0, l_out_base} + {1'b0, owords};
	localparam [24:0] OUT_SPACE = 25'd1 << ADDR;

	always @* begin
		ma = 8'd0;
		mb = 16'd0;
		case (state)
			S_MUL: case (st)
				4'd0: begin ma = r_h;            mb = {7'd0, rp};  end
				4'd1: begin ma = {5'd0, r_kh};   mb = {13'd0, r_kw}; end
				4'd2: begin ma = r_c;            mb = kk;          end
				4'd3: begin ma = {5'd0, r_kh - 3'd1}; mb = {7'd0, rp}; end
				4'd4: begin ma = {5'd0, r_pad};  mb = {7'd0, rp};  end
				4'd5: begin ma = {5'd0, r_s};    mb = {7'd0, rp};  end
				default: begin ma = r_c;         mb = ch;          end
			endcase
			S_MUL2: case (st)
				4'd0:    begin ma = l_out_h;     mb = {5'd0, l_out_rp_w}; end
				default: begin ma = r_f;         mb = och;         end
			endcase
			default: begin ma = 8'd0; mb = 16'd0; end
		endcase
	end

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			state <= S_IDLE; st <= 4'd0; busy <= 1'b0; go <= 1'b0; bad <= 1'b0; err <= 7'd0;
			r_h <= 8'd0; r_w <= 8'd0; r_c <= 8'd0; r_f <= 8'd0;
			r_kh <= 3'd0; r_kw <= 3'd0; r_pad <= 3'd0; r_s <= 3'd0;
			rp <= 9'd0; ch <= 16'd0; kk <= 16'd0; khrp <= {(ADDR+3){1'b0}}; padrp <= {(ADDR+3){1'b0}}; sp <= 13'd0; och <= 16'd0;
			m_full <= 14'd0; cbytes <= 24'd0; owords <= 24'd0; rem <= 10'd0; q <= 8'd0; geo_bad <= 1'b0;
			l_img_ext_base <= {EAW{1'b0}}; l_wgt_ext_base <= {EAW{1'b0}}; l_img_words <= {(ADDR+1){1'b0}};
			l_m <= 11'd0; l_n_groups <= 7'd0; l_last_cols <= 4'd0; l_in_h <= 8'd0; l_in_w <= 8'd0;
			l_kh_max <= 3'd0; l_kw_max <= 3'd0; l_c_max <= 8'd0; l_pad <= 3'd0; l_stride <= 3'd0;
			l_step_kh <= {(ADDR+3){1'b0}}; l_step_c <= {(ADDR+3){1'b0}}; l_tile_addr0 <= {(ADDR+3){1'b0}};
			l_row_step <= {(ADDR+2){1'b0}}; l_out_h <= 8'd0; l_out_w <= 8'd0; l_out_base <= {ADDR{1'b0}};
			l_out_rp_w <= {ADDR{1'b0}}; l_out_ch_pitch <= {ADDR{1'b0}};
		end
		else begin
			go  <= 1'b0;
			bad <= 1'b0;
			case (state)
				S_IDLE: begin
					if (start && !ctrl_busy) begin
						busy <= 1'b1;
						err  <= 7'd0;
						if (zero_bad || s_bad || p_bad) begin
							err   <= {4'd0, p_bad, s_bad, zero_bad};
							bad   <= 1'b1;
							busy  <= 1'b0;
						end
						else begin
							r_h <= in_h; r_w <= in_w; r_c <= in_c; r_f <= n_filt;
							r_kh <= k_h; r_kw <= k_w; r_pad <= pad; r_s <= stride;
							rp  <= ({1'b0, in_w} + 9'd3) & 9'h1FC;
							l_img_ext_base <= img_ext_base;
							l_wgt_ext_base <= wgt_ext_base;
							l_out_base     <= out_base;
							st    <= 4'd0;
							state <= S_MUL;
						end
					end
				end

				S_MUL: begin
					case (st)
						4'd0: ch     <= prod[15:0];
						4'd1: kk     <= prod[15:0];
						4'd2: m_full <= prod[13:0];
						4'd3: khrp   <= prod[ADDR+2:0];
						4'd4: padrp  <= prod[ADDR+2:0];
						4'd5: sp     <= prod[12:0];
						default: cbytes <= prod;
					endcase
					if (st == 4'd6) begin
						geo_bad <= (span_h < {7'd0, r_kh}) || (span_w < {7'd0, r_kw});
						rem     <= span_h - {7'd0, r_kh};
						q       <= 8'd0;
						state   <= S_DIVH;
					end
					st <= st + 1'b1;
				end

				S_DIVH: begin
					if (geo_bad) begin
						state <= S_CHK;
					end
					else if (rem >= {7'd0, r_s}) begin
						rem <= rem - {7'd0, r_s};
						q   <= q + 1'b1;
					end
					else begin
						l_out_h <= q + 1'b1;
						rem     <= span_w - {7'd0, r_kw};
						q       <= 8'd0;
						state   <= S_DIVW;
					end
				end

				S_DIVW: begin
					if (rem >= {7'd0, r_s}) begin
						rem <= rem - {7'd0, r_s};
						q   <= q + 1'b1;
					end
					else begin
						l_out_w    <= q + 1'b1;
						l_out_rp_w <= {{(ADDR-9){1'b0}}, orp9};
						st         <= 4'd0;
						state      <= S_MUL2;
					end
				end

				S_MUL2: begin
					if (st == 4'd0) och <= prod[15:0];
					else begin
						owords <= prod;
						state  <= S_CHK;
					end
					st <= st + 1'b1;
				end

				S_CHK: begin
					busy <= 1'b0;
					if (geo_bad || m_full + 14'd4 > DEPTH_W || cbytes > (4 * DEPTH_F - 4) || out_end > OUT_SPACE) begin
						err <= {out_end > OUT_SPACE, cbytes > (4 * DEPTH_F - 4), m_full + 14'd4 > DEPTH_W, geo_bad, 3'b000};
						bad <= 1'b1;
					end
					else begin
						go             <= 1'b1;
						l_img_words    <= cbytes[ADDR+2:2] + 1'b1;
						l_m            <= m_full[10:0];
						l_n_groups     <= n_grp;
						l_last_cols    <= (r_f[1:0] == 2'd0) ? 4'b1111 :
						                  (r_f[1:0] == 2'd1) ? 4'b0001 :
						                  (r_f[1:0] == 2'd2) ? 4'b0011 : 4'b0111;
						l_in_h         <= r_h;
						l_in_w         <= r_w;
						l_kh_max       <= r_kh - 3'd1;
						l_kw_max       <= r_kw - 3'd1;
						l_c_max        <= r_c - 8'd1;
						l_pad          <= r_pad;
						l_stride       <= r_s;
						l_step_kh      <= sk_v;
						l_step_c       <= sc_v;
						l_tile_addr0   <= ta_v;
						l_row_step     <= sp[ADDR+1:0];
						l_out_ch_pitch <= och[ADDR-1:0];
					end
					state <= S_IDLE;
				end

				default: state <= S_IDLE;
			endcase
		end
	end
endmodule
