module layer_seq #(
    parameter EAW  = 16,
    parameter ADDR = 11
) (
    input                      clk,
    input                      rst_n,

    input                      start,
    input      [EAW-1:0]       tbl_base,
    output reg                 busy,
    output reg                 done,

    // external memory reads while fetching the table (the DMA is idle then)
    output reg                 mem_own,
    output                     rd_req_valid,
    input                      rd_req_ready,
    output     [EAW-1:0]       rd_req_addr,
    input                      rd_resp_valid,
    input      [31:0]          rd_resp_data,
    output                     rd_resp_ready,

    // vector unit configuration bus
    output reg                 vcfg_we,
    output reg [9:0]           vcfg_addr,
    output reg [31:0]          vcfg_data,

    // the current layer
    output reg [7:0]           in_h,
    output reg [7:0]           in_w,
    output reg [7:0]           in_c,
    output reg [7:0]           n_filt,
    output reg [2:0]           k_h,
    output reg [2:0]           k_w,
    output reg [2:0]           pad,
    output reg [2:0]           stride,
    output reg [1:0]           pool,
    output reg                 load_img,
    output reg [EAW-1:0]       wgt_ext_base,
    output reg [EAW-1:0]       img_ext_base,
    output reg [ADDR-1:0]      out_base,
    output reg                 layer_start,
    input                      layer_done,
    input                      layer_err,

    // write-back of the last layer's result
    output reg                 wb_start,
    output reg [ADDR-1:0]      wb_src,
    output reg [ADDR:0]        wb_words,
    output reg [EAW-1:0]       wb_ext_base,
    input                      wb_done,

    output reg                 sel,
    output reg [7:0]           layer_idx
);
	localparam S_IDLE  = 4'd0;
	localparam S_REQ   = 4'd1;
	localparam S_RSP   = 4'd2;
	localparam S_SECT  = 4'd3;
	localparam S_RUN   = 4'd4;
	localparam S_WAIT  = 4'd5;
	localparam S_WB    = 4'd6;
	localparam S_WBW   = 4'd7;
	localparam S_NEXT  = 4'd8;
	localparam S_FIN   = 4'd9;


	reg  [3:0]           state;
	reg  [EAW-1:0]       ptr;           // first word of the current entry
	reg  [9:0]           widx;          // word index inside the entry
	reg  [6:0]           n_prog;
	reg  [8:0]           n_lut;
	reg                  wb_flag, last_flag;
	reg  [21:0]          sect [0:5];
	reg  [4:0]           sidx;
	reg                  lut_hi;        // second entry of a lookup-table word still to write
	reg  [15:0]          lut_hold;
	reg  [8:0]           lidx;          // next lookup-table entry

	wire [9:0]           n_lutw  = ({1'b0, n_lut} + 10'd1) >> 1;
	wire [2:0]           sidx_f  = widx[2:0] - 3'd6;      // header words 6..11 -> sections 0..5
	wire [9:0]           n_words = 10'd12 + {3'd0, n_prog} + n_lutw;

	assign rd_req_valid  = (state == S_REQ) && !lut_hi;
	assign rd_req_addr   = ptr + {{(EAW-10){1'b0}}, widx};
	assign rd_resp_ready = (state == S_RSP);

	// section registers: index n -> vcfg 0x40 + n (pro 0..2, body 3..4, epi0 5..7, epi1 8..10, epi2 11..13, epi3 14..16)
	reg  [9:0]           s_addr;
	reg  [31:0]          s_data;
	always @* begin
		case (sidx)
			5'd0:    begin s_addr = 10'h040; s_data = {26'd0, sect[0][5:0]};   end
			5'd1:    begin s_addr = 10'h041; s_data = {25'd0, sect[0][12:6]};  end
			5'd2:    begin s_addr = 10'h042; s_data = {23'd0, sect[0][21:13]}; end
			5'd3:    begin s_addr = 10'h043; s_data = {26'd0, sect[1][5:0]};   end
			5'd4:    begin s_addr = 10'h044; s_data = {25'd0, sect[1][12:6]};  end
			5'd5:    begin s_addr = 10'h045; s_data = {26'd0, sect[2][5:0]};   end
			5'd6:    begin s_addr = 10'h046; s_data = {25'd0, sect[2][12:6]};  end
			5'd7:    begin s_addr = 10'h047; s_data = {23'd0, sect[2][21:13]}; end
			5'd8:    begin s_addr = 10'h048; s_data = {26'd0, sect[3][5:0]};   end
			5'd9:    begin s_addr = 10'h049; s_data = {25'd0, sect[3][12:6]};  end
			5'd10:   begin s_addr = 10'h04A; s_data = {23'd0, sect[3][21:13]}; end
			5'd11:   begin s_addr = 10'h04B; s_data = {26'd0, sect[4][5:0]};   end
			5'd12:   begin s_addr = 10'h04C; s_data = {25'd0, sect[4][12:6]};  end
			5'd13:   begin s_addr = 10'h04D; s_data = {23'd0, sect[4][21:13]}; end
			5'd14:   begin s_addr = 10'h04E; s_data = {26'd0, sect[5][5:0]};   end
			5'd15:   begin s_addr = 10'h04F; s_data = {25'd0, sect[5][12:6]};  end
			default: begin s_addr = 10'h050; s_data = {23'd0, sect[5][21:13]}; end
		endcase
	end

	integer k;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			state        <= S_IDLE;
			busy         <= 1'b0;
			done         <= 1'b0;
			mem_own      <= 1'b0;
			ptr          <= {EAW{1'b0}};
			widx         <= 10'd0;
			n_prog       <= 7'd0;
			n_lut        <= 9'd0;
			wb_flag      <= 1'b0;
			last_flag    <= 1'b0;
			sidx         <= 5'd0;
			lut_hi       <= 1'b0;
			lut_hold     <= 16'd0;
			lidx         <= 9'd0;
			vcfg_we      <= 1'b0;
			vcfg_addr    <= 10'd0;
			vcfg_data    <= 32'd0;
			in_h <= 8'd0; in_w <= 8'd0; in_c <= 8'd0; n_filt <= 8'd0;
			k_h <= 3'd0; k_w <= 3'd0; pad <= 3'd0; stride <= 3'd0; pool <= 2'd0; load_img <= 1'b0;
			wgt_ext_base <= {EAW{1'b0}};
			img_ext_base <= {EAW{1'b0}};
			out_base     <= {ADDR{1'b0}};
			layer_start  <= 1'b0;
			wb_start     <= 1'b0;
			wb_src       <= {ADDR{1'b0}};
			wb_words     <= {(ADDR+1){1'b0}};
			wb_ext_base  <= {EAW{1'b0}};
			sel          <= 1'b0;
			layer_idx    <= 8'd0;
			for (k = 0; k < 6; k = k + 1) sect[k] <= 22'd0;
		end
		else begin
			done        <= 1'b0;
			vcfg_we     <= 1'b0;
			layer_start <= 1'b0;
			wb_start    <= 1'b0;

			case (state)
				S_IDLE: begin
					if (start) begin
						busy      <= 1'b1;
						ptr       <= tbl_base;
						widx      <= 10'd0;
						sel       <= 1'b0;
						layer_idx <= 8'd0;
						mem_own   <= 1'b1;
						state     <= S_REQ;
					end
				end

				// fetch the entry one word at a time
				S_REQ: begin
					if (lut_hi) begin
						// the second lookup-table entry held from the previous word
						vcfg_we   <= 1'b1;
						vcfg_addr <= 10'h100 + {1'b0, lidx};
						vcfg_data <= {16'd0, lut_hold};
						lidx      <= lidx + 1'b1;
						lut_hi    <= 1'b0;
						if (widx == n_words) state <= S_SECT;
					end
					else if (rd_req_ready)
						state <= S_RSP;
				end

				S_RSP: begin
					if (rd_resp_valid) begin
						case (widx)
							10'd0: begin
								in_h <= rd_resp_data[7:0];   in_w <= rd_resp_data[15:8];
								in_c <= rd_resp_data[23:16]; n_filt <= rd_resp_data[31:24];
							end
							10'd1: begin
								k_h <= rd_resp_data[2:0]; k_w <= rd_resp_data[5:3]; pad <= rd_resp_data[8:6];
								stride <= rd_resp_data[11:9]; pool <= rd_resp_data[13:12];
								load_img <= rd_resp_data[16]; wb_flag <= rd_resp_data[17]; last_flag <= rd_resp_data[18];
							end
							10'd2: begin
								wgt_ext_base <= rd_resp_data[EAW-1:0];
								out_base     <= rd_resp_data[16 +: ADDR];
							end
							10'd3: begin
								img_ext_base <= rd_resp_data[EAW-1:0];
								wb_ext_base  <= rd_resp_data[16 +: EAW];
							end
							10'd4: begin
								wb_src   <= rd_resp_data[ADDR-1:0];
								wb_words <= rd_resp_data[12 +: ADDR+1];
							end
							10'd5: begin
								n_prog <= rd_resp_data[6:0];
								n_lut  <= rd_resp_data[16:8];
								lidx   <= 9'd0;
							end
							10'd6, 10'd7, 10'd8, 10'd9, 10'd10, 10'd11:
								sect[sidx_f] <= rd_resp_data[21:0];
							default: begin
								vcfg_we <= 1'b1;
								if (widx < 10'd12 + {3'd0, n_prog}) begin
									vcfg_addr <= widx - 10'd12;                // program word
									vcfg_data <= rd_resp_data;
								end
								else begin
									vcfg_addr <= 10'h100 + {1'b0, lidx};     // two lookup-table entries
									vcfg_data <= {16'd0, rd_resp_data[15:0]};
									lut_hold  <= rd_resp_data[31:16];
									lut_hi    <= ({1'b0, lidx} + 10'd1 < {1'b0, n_lut});
									lidx      <= lidx + 1'b1;
								end
							end
						endcase
						widx <= widx + 1'b1;
						if (widx + 10'd1 >= 10'd12 && widx + 10'd1 == n_words &&
						    !(widx >= 10'd12 + {3'd0, n_prog} && {1'b0, lidx} + 10'd1 < {1'b0, n_lut}))
							state <= S_SECT;
						else
							state <= S_REQ;
					end
				end

				// write the section registers, one per cycle
				S_SECT: begin
					mem_own   <= 1'b0;
					vcfg_we   <= 1'b1;
					vcfg_addr <= s_addr;
					vcfg_data <= s_data;
					sidx      <= sidx + 1'b1;
					if (sidx == 5'd16) begin
						sidx  <= 5'd0;
						state <= S_RUN;
					end
				end

				S_RUN: begin
					layer_start <= 1'b1;
					state       <= S_WAIT;
				end

				S_WAIT: begin
					if (layer_err) begin
						done  <= 1'b1;
						busy  <= 1'b0;
						state <= S_IDLE;
					end
					else if (layer_done) begin
						if (wb_flag) state <= S_WB;
						else         state <= S_NEXT;
					end
				end

				S_WB: begin
					wb_start <= 1'b1;
					state    <= S_WBW;
				end

				S_WBW: if (wb_done) state <= S_NEXT;

				S_NEXT: begin
					if (last_flag) state <= S_FIN;
					else begin
						sel       <= ~sel;
						layer_idx <= layer_idx + 1'b1;
						ptr       <= ptr + {{(EAW-10){1'b0}}, n_words};
						widx      <= 10'd0;
						mem_own   <= 1'b1;
						state     <= S_REQ;
					end
				end

				S_FIN: begin
					done  <= 1'b1;
					busy  <= 1'b0;
					state <= S_IDLE;
				end

				default: state <= S_IDLE;
			endcase
		end
	end
endmodule
