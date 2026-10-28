module accel_top #(
    parameter EAW     = 16,
    parameter N       = 4,
    parameter ADDR    = 11,
    parameter OUT_REG = 1
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

    input      [EAW-1:0]      img_ext_base,
    input      [EAW-1:0]      wgt_ext_base,
    input      [7:0]          in_h,
    input      [7:0]          in_w,
    input      [7:0]          in_c,
    input      [7:0]          n_filt,
    input      [2:0]          k_h,
    input      [2:0]          k_w,
    input      [2:0]          pad,
    input      [2:0]          stride,
    input      [ADDR-1:0]     out_base,

    output                    rd_req_valid,
    input                     rd_req_ready,
    output     [EAW-1:0]      rd_req_addr,
    input                     rd_resp_valid,
    input      [31:0]         rd_resp_data,
    output                    rd_resp_ready,

    output                    pkt_valid,
    output     [N*32-1:0]     pkt_data,
    output     [ADDR-1:0]     pkt_addr,
    output     [N-1:0]        pkt_be,
    output                    pkt_last
);
	wire                    rst_s;

	wire                    cfg_busy, cfg_go;
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
	wire                    bias_rd;
	wire [9:0]              bias_addr;
	wire [N*32-1:0]         bias;
	wire [ADDR-1:0]         desc_addr;
	wire [3:0]              desc_cols;

	wire [31:0]             unused_wgt_rdata0;
	wire                    unused_dma_busy;

	assign busy = cfg_busy || ctrl_busy;
	assign done = ctrl_done || err_valid;

	reset_sync u_rst (
		.rst_sync(rst_s), .rst_async(rst_n), .clk(clk)
	);

	layer_config #(.EAW(EAW), .ADDR(ADDR), .DEPTH_F(1536), .DEPTH_W(1024)) u_cfg (
		.clk(clk), .rst_n(rst_s), .start(start), .ctrl_busy(ctrl_busy),
		.img_ext_base(img_ext_base), .wgt_ext_base(wgt_ext_base),
		.in_h(in_h), .in_w(in_w), .in_c(in_c), .n_filt(n_filt),
		.k_h(k_h), .k_w(k_w), .pad(pad), .stride(stride), .out_base(out_base),
		.busy(cfg_busy), .go(cfg_go), .bad(err_valid), .err(err),
		.l_img_ext_base(c_img_ext_base), .l_wgt_ext_base(c_wgt_ext_base), .l_img_words(c_img_words),
		.l_m(c_m), .l_n_groups(c_n_groups), .l_last_cols(c_last_cols),
		.l_in_h(c_in_h), .l_in_w(c_in_w), .l_kh_max(c_kh_max), .l_kw_max(c_kw_max), .l_c_max(c_c_max),
		.l_pad(c_pad), .l_stride(c_stride), .l_step_kh(c_step_kh), .l_step_c(c_step_c),
		.l_tile_addr0(c_tile_addr0), .l_row_step(c_row_step), .l_out_h(c_out_h), .l_out_w(c_out_w),
		.l_out_base(c_out_base), .l_out_rp_w(c_out_rp_w), .l_out_ch_pitch(c_out_ch_pitch)
	);

	layer_controller #(.EAW(EAW), .ADDR(ADDR), .N(N)) u_ctrl (
		.clk(clk), .rst_n(rst_s), .go(cfg_go), .busy(ctrl_busy), .done(ctrl_done), .img_phase(img_phase),
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
		.pkt_last(pkt_last),
		.bias_rd(bias_rd), .bias_addr(bias_addr), .wgt_rdata(wgt_rdata), .bias(bias)
	);

	dma #(.EAW(EAW), .SAW(ADDR)) u_dma (
		.clk(clk), .rst_n(rst_s),
		.start(dma_start), .ext_base(dma_ext_base), .sram_base(dma_sram_base), .nwords(dma_nwords),
		.busy(unused_dma_busy), .done(dma_done),
		.rd_req_valid(rd_req_valid), .rd_req_ready(rd_req_ready), .rd_req_addr(rd_req_addr),
		.rd_resp_valid(rd_resp_valid), .rd_resp_data(rd_resp_data), .rd_resp_ready(rd_resp_ready),
		.wr_en(dma_wr_en), .wr_addr(dma_wr_addr), .wr_data(dma_wr_data)
	);

	ram_1rw1r #(.DEPTH(1536)) u_feat (
`ifdef USE_POWER_PINS
		.vccd1(vccd1), .vssd1(vssd1),
`endif
		.clk(clk),
		.en0(img_phase ? dma_wr_en : act_mem_en), .we0(img_phase && dma_wr_en), .be0(4'hF),
		.addr0(img_phase ? dma_wr_addr : act_addr0), .wdata0(dma_wr_data), .rdata0(act_rdata0),
		.en1(act_mem_en), .addr1(act_addr1), .rdata1(act_rdata1)
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
		.desc_full(desc_full),
		.pkt_valid(pkt_valid), .pkt_data(pkt_data), .pkt_addr(pkt_addr), .pkt_be(pkt_be), .pkt_last(pkt_last)
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
