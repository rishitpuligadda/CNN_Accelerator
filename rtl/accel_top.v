module accel_top #(
    parameter EAW     = 16,
    parameter N       = 4,
    parameter ADDR    = 11,
    parameter OUT_REG = 1,
    parameter PKT_Q   = 8
) (
`ifdef USE_POWER_PINS
    inout                     vccd1,
    inout                     vssd1,
`endif
    input                     clk,
    input                     rst_n,
    input                     start,
    output                    busy,
    output                    done,
    output                    err_valid,
    output     [6:0]          err,

    input      [EAW-1:0]      tbl_base,

    output                    rd_req_valid,
    input                     rd_req_ready,
    output     [EAW-1:0]      rd_req_addr,
    input                     rd_resp_valid,
    input      [31:0]         rd_resp_data,
    output                    rd_resp_ready,

    output                    wr_req_valid,
    input                     wr_req_ready,
    output     [EAW-1:0]      wr_req_addr,
    output     [31:0]         wr_req_data
);
	wire                    rst_s;

	// layer sequencer: reads the layer table, configures and starts each layer
	wire                    seq_busy, seq_done, seq_mem, seq_layer_start, sel;
	wire                    seq_rd_valid, seq_rd_ready_out;
	wire [EAW-1:0]          seq_rd_addr;
	wire                    vcfg_we;
	wire [9:0]              vcfg_addr;
	wire [31:0]             vcfg_data;
	wire [7:0]              in_h, in_w, in_c, n_filt, unused_layer_idx;
	wire [2:0]              k_h, k_w, pad, stride;
	wire [1:0]              pool;
	wire                    load_img;
	wire [EAW-1:0]          img_ext_base, wgt_ext_base;
	wire [ADDR-1:0]         out_base;
	wire                    wb_start, wb_done, unused_wb_busy, wb_en;
	wire [ADDR-1:0]         wb_src, wb_addr;
	wire [ADDR:0]           wb_words;
	wire [EAW-1:0]          wb_ext_base;
	wire [31:0]             wb_rdata;
	wire                    dma_rd_valid, dma_rd_resp_ready;
	wire [EAW-1:0]          dma_rd_addr;

	wire                    unused_cfg_busy, cfg_go;
	wire [EAW-1:0]          c_img_ext_base, c_wgt_ext_base;
	wire [ADDR:0]           c_img_words;
	wire [10:0]             c_m;
	wire [6:0]              c_n_groups;
	wire [3:0]              c_last_cols;
	wire [7:0]              c_in_h, c_in_w, c_c_max, c_out_h, c_out_w;
	wire [2:0]              c_kh_max, c_kw_max, c_pad, c_stride;
	wire signed [ADDR+2:0]  c_step_kh, c_step_c, c_tile_addr0;
	wire [ADDR+1:0]         c_row_step;
	wire [ADDR-1:0]         c_out_base, c_out_rp_w, c_out_ch_pitch;

	wire                    ctrl_busy, ctrl_done, img_phase;
	wire                    dma_start, dma_done;
	wire [EAW-1:0]          dma_ext_base;
	wire [ADDR-1:0]         dma_sram_base;
	wire [ADDR:0]           dma_nwords;
	wire                    dma_wr_en;
	wire [ADDR-1:0]         dma_wr_addr;
	wire [31:0]             dma_wr_data;

	wire                    feed_start;
	wire [9:0]              wgt_base;
	wire signed [ADDR+2:0]  tile_addr;
	wire signed [9:0]       y0, x0;
	wire [3:0]              lane_on;

	wire                    act_busy, act_mem_en, act_iss, act_valid, act_first, act_last;
	wire [ADDR-1:0]         act_addr0, act_addr1;
	wire [31:0]             act_rdata0, act_rdata1, act_lanes;

	wire                    wgt_mem_en, wgt_valid;
	wire [9:0]              wgt_mem_addr;
	wire [31:0]             wgt_rdata, wgt_lanes;

	wire [N*8-1:0]          act_sk, wgt_sk;
	wire [N*32-1:0]         c_col;
	wire [N*2-1:0]          c_row;
	wire [N-1:0]            c_valid;

	wire                    desc_push, desc_full;
	wire                    col_valid, col_last;
	wire [N*32-1:0]         col_data;
	wire [ADDR-1:0]         col_addr;
	wire [N-1:0]            col_be;
	wire                    unused_fifo_full;
	wire [7:0]              desc_row, desc_col, desc_chan;
	wire [7:0]              col_row, col_col, col_chan;

	// packets from the FIFO to the vector unit
	wire                    pkt_valid, pkt_ready, pkt_last;
	wire [N*32-1:0]         pkt_data;
	wire [ADDR-1:0]         pkt_addr;
	wire [N-1:0]            pkt_be;
	wire [7:0]              pkt_row, pkt_col, pkt_chan;
	wire                    pkt_pop = pkt_valid && pkt_ready;

	// vector unit
	wire                    vu_busy, vu_done;
	wire                    st_en;
	wire [ADDR-1:0]         st_addr;
	wire [N-1:0]            st_be;
	wire [N*8-1:0]          st_data;
	wire [31:0]             unused_ob_rdata0;
	wire                    bias_rd;
	wire [9:0]              bias_addr;
	wire [N*32-1:0]         bias;
	wire [ADDR-1:0]         desc_addr;
	wire [3:0]              desc_cols;

	wire [31:0]             unused_wgt_rdata0;
	wire                    unused_dma_busy;

	assign busy = seq_busy;
	assign done = seq_done;

	layer_seq #(.EAW(EAW), .ADDR(ADDR)) u_seq (
		.clk(clk), .rst_n(rst_s), .start(start), .tbl_base(tbl_base), .busy(seq_busy), .done(seq_done),
		.mem_own(seq_mem), .rd_req_valid(seq_rd_valid), .rd_req_ready(rd_req_ready), .rd_req_addr(seq_rd_addr),
		.rd_resp_valid(rd_resp_valid), .rd_resp_data(rd_resp_data), .rd_resp_ready(seq_rd_ready_out),
		.vcfg_we(vcfg_we), .vcfg_addr(vcfg_addr), .vcfg_data(vcfg_data),
		.in_h(in_h), .in_w(in_w), .in_c(in_c), .n_filt(n_filt), .k_h(k_h), .k_w(k_w), .pad(pad), .stride(stride),
		.pool(pool), .load_img(load_img), .wgt_ext_base(wgt_ext_base), .img_ext_base(img_ext_base),
		.out_base(out_base), .layer_start(seq_layer_start), .layer_done(vu_done), .layer_err(err_valid),
		.wb_start(wb_start), .wb_src(wb_src), .wb_words(wb_words), .wb_ext_base(wb_ext_base), .wb_done(wb_done),
		.sel(sel), .layer_idx(unused_layer_idx)
	);

	// external memory: the sequencer reads the table between layers, the DMA reads images and weights
	assign rd_req_valid  = seq_mem ? seq_rd_valid     : dma_rd_valid;
	assign rd_req_addr   = seq_mem ? seq_rd_addr      : dma_rd_addr;
	assign rd_resp_ready = seq_mem ? seq_rd_ready_out : dma_rd_resp_ready;

	writeback #(.EAW(EAW), .ADDR(ADDR)) u_wb (
		.clk(clk), .rst_n(rst_s), .start(wb_start), .src(wb_src), .nwords(wb_words), .ext_base(wb_ext_base),
		.done(wb_done), .busy(unused_wb_busy),
		.buf_en(wb_en), .buf_addr(wb_addr), .buf_rdata(wb_rdata),
		.wr_req_valid(wr_req_valid), .wr_req_ready(wr_req_ready), .wr_req_addr(wr_req_addr), .wr_req_data(wr_req_data)
	);

	reset_sync u_rst (
		.rst_sync(rst_s), .rst_async(rst_n), .clk(clk)
	);

	layer_config #(.EAW(EAW), .ADDR(ADDR), .DEPTH_F(1536), .DEPTH_W(1024)) u_cfg (
		.clk(clk), .rst_n(rst_s), .start(seq_layer_start), .ctrl_busy(ctrl_busy || vu_busy),
		.img_ext_base(img_ext_base), .wgt_ext_base(wgt_ext_base),
		.in_h(in_h), .in_w(in_w), .in_c(in_c), .n_filt(n_filt),
		.k_h(k_h), .k_w(k_w), .pad(pad), .stride(stride), .pool(pool), .out_base(out_base),
		.busy(unused_cfg_busy), .go(cfg_go), .bad(err_valid), .err(err),
		.l_img_ext_base(c_img_ext_base), .l_wgt_ext_base(c_wgt_ext_base), .l_img_words(c_img_words),
		.l_m(c_m), .l_n_groups(c_n_groups), .l_last_cols(c_last_cols),
		.l_in_h(c_in_h), .l_in_w(c_in_w), .l_kh_max(c_kh_max), .l_kw_max(c_kw_max), .l_c_max(c_c_max),
		.l_pad(c_pad), .l_stride(c_stride), .l_step_kh(c_step_kh), .l_step_c(c_step_c),
		.l_tile_addr0(c_tile_addr0), .l_row_step(c_row_step), .l_out_h(c_out_h), .l_out_w(c_out_w),
		.l_out_base(c_out_base), .l_out_rp_w(c_out_rp_w), .l_out_ch_pitch(c_out_ch_pitch)
	);

	layer_controller #(.EAW(EAW), .ADDR(ADDR), .N(N), .CREDITS(PKT_Q)) u_ctrl (
		.clk(clk), .rst_n(rst_s), .go(cfg_go), .busy(ctrl_busy), .done(ctrl_done), .img_phase(img_phase), .load_img(load_img),
		.img_ext_base(c_img_ext_base), .img_words(c_img_words), .wgt_ext_base(c_wgt_ext_base),
		.m(c_m), .n_groups(c_n_groups), .last_cols(c_last_cols),
		.out_h(c_out_h), .out_w(c_out_w), .pad(c_pad), .stride(c_stride),
		.tile_addr0(c_tile_addr0), .row_step(c_row_step),
		.out_base(c_out_base), .out_rp_w(c_out_rp_w), .out_ch_pitch(c_out_ch_pitch),
		.dma_start(dma_start), .dma_ext_base(dma_ext_base), .dma_sram_base(dma_sram_base),
		.dma_nwords(dma_nwords), .dma_done(dma_done),
		.feed_start(feed_start), .wgt_base(wgt_base), .tile_addr(tile_addr), .y0(y0), .x0(x0),
		.lane_on(lane_on), .act_busy(act_busy),
		.desc_push(desc_push), .desc_addr(desc_addr), .desc_cols(desc_cols), .desc_full(desc_full),
		.desc_row(desc_row), .desc_col(desc_col), .desc_chan(desc_chan),
		.pkt_pop(pkt_pop), .pkt_last(pkt_last && pkt_pop),
		.bias_rd(bias_rd), .bias_addr(bias_addr), .wgt_rdata(wgt_rdata), .bias(bias)
	);

	dma #(.EAW(EAW), .SAW(ADDR)) u_dma (
		.clk(clk), .rst_n(rst_s),
		.start(dma_start), .ext_base(dma_ext_base), .sram_base(dma_sram_base), .nwords(dma_nwords),
		.busy(unused_dma_busy), .done(dma_done),
		.rd_req_valid(dma_rd_valid), .rd_req_ready(rd_req_ready && !seq_mem), .rd_req_addr(dma_rd_addr),
		.rd_resp_valid(rd_resp_valid && !seq_mem), .rd_resp_data(rd_resp_data), .rd_resp_ready(dma_rd_resp_ready),
		.wr_en(dma_wr_en), .wr_addr(dma_wr_addr), .wr_data(dma_wr_data)
	);

	// ---------------------------------------------------------------- feature buffers A and B, ping-pong
	// sel = 0: A is the layer's input (DMA image load, act_feeder reads), B its output (vector unit writes,
	// write-back reads); sel = 1: the other way round. The sequencer flips sel after every layer.
	wire        in_en0  = img_phase ? dma_wr_en : act_mem_en;
	wire        in_we0  = img_phase && dma_wr_en;
	wire [ADDR-1:0] in_a0 = img_phase ? dma_wr_addr : act_addr0;
	wire [31:0] fa_rdata0, fa_rdata1, fb_rdata0, fb_rdata1;

	assign act_rdata0 = sel ? fb_rdata0 : fa_rdata0;
	assign act_rdata1 = sel ? fb_rdata1 : fa_rdata1;
	assign wb_rdata   = sel ? fa_rdata1 : fb_rdata1;
	assign unused_ob_rdata0 = sel ? fa_rdata0 : fb_rdata0;

	ram_1rw1r #(.DEPTH(1536)) u_feat (
`ifdef USE_POWER_PINS
		.vccd1(vccd1), .vssd1(vssd1),
`endif
		.clk(clk),
		.en0(sel ? st_en : in_en0), .we0(sel ? st_en : in_we0), .be0(sel ? st_be : 4'hF),
		.addr0(sel ? st_addr : in_a0), .wdata0(sel ? st_data : dma_wr_data), .rdata0(fa_rdata0),
		.en1(sel ? wb_en : act_mem_en), .addr1(sel ? wb_addr : act_addr1), .rdata1(fa_rdata1)
	);

	ram_1rw1r #(.DEPTH(1024)) u_wgt (
`ifdef USE_POWER_PINS
		.vccd1(vccd1), .vssd1(vssd1),
`endif
		.clk(clk),
		.en0(!img_phase && dma_wr_en), .we0(!img_phase && dma_wr_en), .be0(4'hF),
		.addr0(dma_wr_addr[9:0]), .wdata0(dma_wr_data), .rdata0(unused_wgt_rdata0),
		.en1(wgt_mem_en || bias_rd), .addr1(bias_rd ? bias_addr : wgt_mem_addr), .rdata1(wgt_rdata)
	);

	act_feeder #(.ADDR(ADDR), .DIMW(8), .KW_W(3), .CW(8), .OUT_REG(OUT_REG)) u_act (
		.clk(clk), .rst_n(rst_s), .start(feed_start),
		.tile_addr(tile_addr), .y0(y0), .x0(x0), .lane_on(lane_on),
		.in_h(c_in_h), .in_w(c_in_w), .kh_max(c_kh_max), .kw_max(c_kw_max), .c_max(c_c_max),
		.stride(c_stride), .step_kh(c_step_kh), .step_c(c_step_c),
		.mem_rdata0(act_rdata0), .mem_rdata1(act_rdata1),
		.busy(act_busy), .mem_en(act_mem_en), .mem_addr0(act_addr0), .mem_addr1(act_addr1),
		.iss(act_iss), .lanes(act_lanes), .valid(act_valid), .first(act_first), .last(act_last)
	);

	wgt_feeder #(.WIDTH(32), .ADDR(10), .OUT_REG(OUT_REG)) u_wgtf (
		.clk(clk), .rst_n(rst_s), .start(feed_start), .base(wgt_base), .adv(act_iss),
		.mem_rdata(wgt_rdata), .mem_en(wgt_mem_en), .mem_addr(wgt_mem_addr),
		.lanes(wgt_lanes), .valid(wgt_valid)
	);

	skew_buffer #(.LANES(N), .WIDTH(8)) u_skew_act (
		.clk(clk), .rst_n(rst_s), .din(act_lanes), .dout(act_sk)
	);

	skew_buffer #(.LANES(N), .WIDTH(8)) u_skew_wgt (
		.clk(clk), .rst_n(rst_s), .din(wgt_lanes), .dout(wgt_sk)
	);

	systolic_array #(.TILE_MAX(N), .WIDTH(8)) u_array (
		.c_col(c_col), .c_row(c_row), .c_valid(c_valid),
		.a(wgt_sk), .b(act_sk), .clk(clk), .rst_n(rst_s),
		.en(act_valid && wgt_valid), .first(act_first), .last(act_last), .bias(bias)
	);

	result_collector #(.N(N), .ACC_W(32), .ADDR(ADDR), .QD(4)) u_coll (
		.clk(clk), .rst_n(rst_s),
		.c_col(c_col), .c_row(c_row), .c_valid(c_valid), .ch_pitch(c_out_ch_pitch),
		.desc_push(desc_push), .desc_addr(desc_addr), .desc_lanes(lane_on), .desc_cols(desc_cols),
		.desc_row(desc_row), .desc_col(desc_col), .desc_chan(desc_chan),
		.desc_full(desc_full),
		.pkt_valid(col_valid), .pkt_data(col_data), .pkt_addr(col_addr), .pkt_be(col_be), .pkt_last(col_last),
		.pkt_row(col_row), .pkt_col(col_col), .pkt_chan(col_chan)
	);

	pkt_fifo #(.W(N*32 + ADDR + N + 1 + 24), .DEPTH(PKT_Q)) u_pktq (
		.clk(clk), .rst_n(rst_s),
		.push(col_valid), .din({col_chan, col_col, col_row, col_last, col_be, col_addr, col_data}),
		.out_valid(pkt_valid), .out_ready(pkt_ready),
		.dout({pkt_chan, pkt_col, pkt_row, pkt_last, pkt_be, pkt_addr, pkt_data}),
		.full(unused_fifo_full)
	);

	// ---------------------------------------------------------------- vector unit configuration bus
	// 0x000-0x03F program memory, 0x040-0x050 section registers, 0x100-0x1FF lookup table
	reg  [5:0]  vs_pro_s, vs_body_s, vs_epi_s, vs_e1_s, vs_e2_s, vs_e3_s;
	reg  [6:0]  vs_pro_l, vs_body_l, vs_epi_l, vs_e1_l, vs_e2_l, vs_e3_l;
	reg  [8:0]  vs_pro_c, vs_epi_c, vs_e1_c, vs_e2_c, vs_e3_c;

	always @(posedge clk or negedge rst_s) begin
		if (!rst_s) begin
			vs_pro_s <= 6'd0; vs_body_s <= 6'd0; vs_epi_s <= 6'd0; vs_e1_s <= 6'd0; vs_e2_s <= 6'd0; vs_e3_s <= 6'd0;
			vs_pro_l <= 7'd0; vs_body_l <= 7'd0; vs_epi_l <= 7'd0; vs_e1_l <= 7'd0; vs_e2_l <= 7'd0; vs_e3_l <= 7'd0;
			vs_pro_c <= 9'd0; vs_epi_c <= 9'd0; vs_e1_c <= 9'd0; vs_e2_c <= 9'd0; vs_e3_c <= 9'd0;
		end
		else if (vcfg_we && vcfg_addr[9:6] == 4'b0001)
			case (vcfg_addr[4:0])
				5'd0:  vs_pro_s  <= vcfg_data[5:0];
				5'd1:  vs_pro_l  <= vcfg_data[6:0];
				5'd2:  vs_pro_c  <= vcfg_data[8:0];
				5'd3:  vs_body_s <= vcfg_data[5:0];
				5'd4:  vs_body_l <= vcfg_data[6:0];
				5'd5:  vs_epi_s  <= vcfg_data[5:0];
				5'd6:  vs_epi_l  <= vcfg_data[6:0];
				5'd7:  vs_epi_c  <= vcfg_data[8:0];
				5'd8:  vs_e1_s   <= vcfg_data[5:0];
				5'd9:  vs_e1_l   <= vcfg_data[6:0];
				5'd10: vs_e1_c   <= vcfg_data[8:0];
				5'd11: vs_e2_s   <= vcfg_data[5:0];
				5'd12: vs_e2_l   <= vcfg_data[6:0];
				5'd13: vs_e2_c   <= vcfg_data[8:0];
				5'd14: vs_e3_s   <= vcfg_data[5:0];
				5'd15: vs_e3_l   <= vcfg_data[6:0];
				5'd16: vs_e3_c   <= vcfg_data[8:0];
				default: begin end
			endcase
	end

	vector_unit #(.LANES(N), .ADDR(ADDR), .PM_AW(6)) u_vu (
		.clk(clk), .rst_n(rst_s),
		.pm_we(vcfg_we && vcfg_addr[9:6] == 4'b0000), .pm_waddr(vcfg_addr[5:0]), .pm_wdata(vcfg_data),
		.lut_we(vcfg_we && vcfg_addr[9:8] == 2'b01), .lut_waddr(vcfg_addr[7:0]), .lut_wdata(vcfg_data[15:0]),
		.pro_start(vs_pro_s), .pro_len(vs_pro_l), .body_start(vs_body_s), .body_len(vs_body_l),
		.epi_start(vs_epi_s), .epi_len(vs_epi_l),
		.pro_cnt(vs_pro_c), .epi_cnt(vs_epi_c),
		.epi1_start(vs_e1_s), .epi1_len(vs_e1_l), .epi1_cnt(vs_e1_c),
		.epi2_start(vs_e2_s), .epi2_len(vs_e2_l), .epi2_cnt(vs_e2_c),
		.epi3_start(vs_e3_s), .epi3_len(vs_e3_l), .epi3_cnt(vs_e3_c),
		.layer_start(cfg_go), .layer_end(ctrl_done), .busy(vu_busy), .done(vu_done),
		.pkt_valid(pkt_valid), .pkt_ready(pkt_ready), .pkt_data(pkt_data), .pkt_addr(pkt_addr), .pkt_be(pkt_be),
		.pkt_row(pkt_row), .pkt_col(pkt_col), .pkt_chan(pkt_chan), .pkt_last(pkt_last),
		.st_en(st_en), .st_addr(st_addr), .st_be(st_be), .st_data(st_data)
	);

	ram_1rw1r #(.DEPTH(1536)) u_featb (
`ifdef USE_POWER_PINS
		.vccd1(vccd1), .vssd1(vssd1),
`endif
		.clk(clk),
		.en0(sel ? in_en0 : st_en), .we0(sel ? in_we0 : st_en), .be0(sel ? 4'hF : st_be),
		.addr0(sel ? in_a0 : st_addr), .wdata0(sel ? dma_wr_data : st_data), .rdata0(fb_rdata0),
		.en1(sel ? act_mem_en : wb_en), .addr1(sel ? act_addr1 : wb_addr), .rdata1(fb_rdata1)
	);

`ifndef SYNTHESIS
	reg [3:0] settle;

	always @(posedge clk or negedge rst_s) begin
		if (!rst_s)              settle <= 4'd0;
		else if (settle != 4'd8) settle <= settle + 1'b1;
	end

	always @(negedge clk) begin
		if (settle == 4'd8) begin
			if (act_valid !== wgt_valid)
				$display("ASSERT %m t=%0t: activation and weight valid differ", $time);
			if (!img_phase && dma_wr_en && wgt_mem_en && dma_wr_addr[9] == wgt_mem_addr[9])
				$display("ASSERT %m t=%0t: DMA writes the weight half the feeder is reading", $time);
			if (bias_rd && wgt_mem_en)
				$display("ASSERT %m t=%0t: bias load and weight feeder use the weight RAM read port together", $time);
			if (img_phase && act_mem_en)
				$display("ASSERT %m t=%0t: feeder reads the feature buffer while the image is loading", $time);
		end
	end
`endif
endmodule
