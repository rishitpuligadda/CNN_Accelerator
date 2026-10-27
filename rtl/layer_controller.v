module layer_controller #(
    parameter EAW  = 16,
    parameter ADDR = 11,
    parameter N    = 4
) (
    input                          clk,
    input                          rst_n,
    input                          go,
    output reg                     busy,
    output reg                     done,
    output reg                     img_phase,

    input      [EAW-1:0]           img_ext_base,
    input      [ADDR:0]            img_words,
    input      [EAW-1:0]           wgt_ext_base,
    input      [10:0]              m,
    input      [6:0]               n_groups,
    input      [3:0]               last_cols,
    input      [7:0]               out_h,
    input      [7:0]               out_w,
    input      [2:0]               pad,
    input      [2:0]               stride,
    input  signed [ADDR+2:0]       tile_addr0,
    input      [ADDR+1:0]          row_step,
    input      [ADDR-1:0]          out_base,
    input      [ADDR-1:0]          out_rp_w,
    input      [ADDR-1:0]          out_ch_pitch,

    output                         dma_start,
    output     [EAW-1:0]           dma_ext_base,
    output     [ADDR-1:0]          dma_sram_base,
    output     [ADDR:0]            dma_nwords,
    input                          dma_done,

    output                         feed_start,
    output     [9:0]               wgt_base,
    output signed [ADDR+2:0]       tile_addr,
    output signed [9:0]            y0,
    output signed [9:0]            x0,
    output     [3:0]               lane_on,
    input                          act_busy,

    output                         desc_push,
    output     [ADDR-1:0]          desc_addr,
    output     [3:0]               desc_cols,
    input                          desc_full,
    input                          pkt_last
);
	localparam S_IDLE   = 4'd0;
	localparam S_IMG    = 4'd1;
	localparam S_IMG_W  = 4'd2;
	localparam S_WLOAD  = 4'd3;
	localparam S_WLOADW = 4'd4;
	localparam S_PREF   = 4'd5;
	localparam S_ISSUE  = 4'd6;
	localparam S_WAIT   = 4'd7;
	localparam S_GEND   = 4'd8;
	localparam S_DRAIN  = 4'd9;


	reg  [3:0]             state;
	reg  [6:0]             g;
	reg                    half, dbuf, wpend;
	reg  [2:0]             since_end;
	reg  [EAW-1:0]         wptr;
	reg  [7:0]             oh, ow;
	reg  [ADDR+1:0]        tx;
	reg  signed [ADDR+2:0] row_addr;
	reg  signed [9:0]      y0_r;
	reg  [ADDR-1:0]        o_grp_base, o_row_base;
	reg  [15:0]            tiles_issued, tiles_done;

	localparam integer     NM1        = N - 1;
	wire        [2:0]      need       = ({21'd0, m} >= NM1) ? 3'd0 : NM1[2:0] - m[2:0];
	wire                   issue      = (state == S_ISSUE) && !act_busy && !desc_full && (since_end >= need);
	wire                   last_ow    = ({1'b0, ow} + 9'd4) >= {1'b0, out_w};
	wire                   last_oh    = (oh == out_h - 1'b1);
	wire                   last_group = (g == n_groups - 1'b1);
	wire                   pref_go    = dbuf && ({1'b0, g} + 8'd1 < {1'b0, n_groups});
	wire signed [9:0]      pad_s      = $signed({7'd0, pad});
	wire        [ADDR+1:0] x_step     = {{(ADDR-3){1'b0}}, stride, 2'b00};

	assign dma_start     = (state == S_IMG) || (state == S_WLOAD) || (state == S_PREF && pref_go);
	assign dma_ext_base  = (state == S_IMG) ? img_ext_base : wptr;
	assign dma_sram_base = (state == S_IMG)   ? {ADDR{1'b0}} :
	                       (state == S_WLOAD) ? {{(ADDR-10){1'b0}}, half, 9'd0} :
	                                            {{(ADDR-10){1'b0}}, ~half, 9'd0};
	assign dma_nwords    = (state == S_IMG) ? img_words : {{(ADDR-10){1'b0}}, m};

	assign feed_start = issue;
	assign wgt_base   = {half, 9'd0};
	assign tile_addr  = row_addr + $signed({1'b0, tx});
	assign y0         = y0_r;
	assign x0         = $signed({1'b0, tx[8:0]}) - pad_s;

	genvar i;
	generate
		for (i = 0; i < 4; i = i + 1) begin : LN
			localparam [8:0] OFS = i;
			assign lane_on[i] = ({1'b0, ow} + OFS) < {1'b0, out_w};
		end
	endgenerate

	assign desc_push = issue;
	assign desc_addr = o_row_base + {{(ADDR-6){1'b0}}, ow[7:2]};
	assign desc_cols = last_group ? last_cols : 4'hF;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			state        <= S_IDLE;
			busy         <= 1'b0;
			done         <= 1'b0;
			img_phase    <= 1'b0;
			g            <= 7'd0;
			half         <= 1'b0;
			dbuf         <= 1'b0;
			wpend        <= 1'b0;
			since_end    <= 3'd7;
			wptr         <= {EAW{1'b0}};
			oh           <= 8'd0;
			ow           <= 8'd0;
			tx           <= {(ADDR+2){1'b0}};
			row_addr     <= {(ADDR+3){1'b0}};
			y0_r         <= 10'd0;
			o_grp_base   <= {ADDR{1'b0}};
			o_row_base   <= {ADDR{1'b0}};
			tiles_issued <= 16'd0;
			tiles_done   <= 16'd0;
		end
		else begin
			done <= 1'b0;
			if (pkt_last) tiles_done <= tiles_done + 1'b1;
			if (dma_done) wpend <= 1'b0;
			if (act_busy)               since_end <= 3'd0;
			else if (since_end != 3'd7) since_end <= since_end + 1'b1;

			case (state)
				S_IDLE: begin
					if (go) begin
						busy         <= 1'b1;
						img_phase    <= 1'b1;
						g            <= 7'd0;
						half         <= 1'b0;
						dbuf         <= (m <= 11'd512);
						wpend        <= 1'b0;
						wptr         <= wgt_ext_base;
						o_grp_base   <= out_base;
						tiles_issued <= 16'd0;
						tiles_done   <= 16'd0;
						state        <= S_IMG;
					end
				end

				S_IMG: state <= S_IMG_W;

				S_IMG_W: begin
					if (dma_done) begin
						img_phase <= 1'b0;
						state     <= S_WLOAD;
					end
				end

				S_WLOAD: begin
					wptr  <= wptr + {{(EAW-11){1'b0}}, m};
					state <= S_WLOADW;
				end

				S_WLOADW: if (dma_done) state <= S_PREF;

				S_PREF: begin
					oh         <= 8'd0;
					ow         <= 8'd0;
					tx         <= {(ADDR+2){1'b0}};
					row_addr   <= tile_addr0;
					y0_r       <= -pad_s;
					o_row_base <= o_grp_base;
					if (pref_go) begin
						wptr  <= wptr + {{(EAW-11){1'b0}}, m};
						wpend <= 1'b1;
					end
					state <= S_ISSUE;
				end

				S_ISSUE: begin
					if (issue) begin
						tiles_issued <= tiles_issued + 1'b1;
						if (!last_ow) begin
							ow    <= ow + 8'd4;
							tx    <= tx + x_step;
							state <= S_WAIT;
						end
						else begin
							ow         <= 8'd0;
							tx         <= {(ADDR+2){1'b0}};
							oh         <= oh + 1'b1;
							y0_r       <= y0_r + $signed({7'd0, stride});
							row_addr   <= row_addr + $signed({1'b0, row_step});
							o_row_base <= o_row_base + out_rp_w;
							state      <= last_oh ? S_GEND : S_WAIT;
						end
					end
				end

				S_WAIT: if (!act_busy) state <= S_ISSUE;

				S_GEND: begin
					if (!act_busy) begin
						if (last_group)
							state <= S_DRAIN;
						else if (!dbuf) begin
							g          <= g + 1'b1;
							o_grp_base <= o_grp_base + (out_ch_pitch << 2);
							state      <= S_WLOAD;
						end
						else if (!wpend) begin
							g          <= g + 1'b1;
							half       <= ~half;
							o_grp_base <= o_grp_base + (out_ch_pitch << 2);
							state      <= S_PREF;
						end
					end
				end

				S_DRAIN: begin
					if (tiles_done == tiles_issued) begin
						busy  <= 1'b0;
						done  <= 1'b1;
						state <= S_IDLE;
					end
				end

				default: state <= S_IDLE;
			endcase
		end
	end
endmodule
