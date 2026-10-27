module accel_top #(
    parameter EAW  = 16,
    parameter N    = 4,
    parameter ADDR = 11,
    parameter DIMW = 8
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

    input      [EAW-1:0]      img_ext_base,
    input      [ADDR:0]       img_words,
    input      [EAW-1:0]      wgt_ext_base,
    input      [10:0]         m,
    input      [7:0]          n_groups,
    input      [3:0]          last_cols,
    input      [DIMW-1:0]     in_h,
    input      [DIMW-1:0]     in_w,
    input      [2:0]          kh_max,
    input      [2:0]          kw_max,
    input      [7:0]          c_max,
    input      [2:0]          pad,
    input  signed [ADDR+2:0]  step_kh,
    input  signed [ADDR+2:0]  step_c,
    input  signed [ADDR+2:0]  tile_addr0,
    input      [ADDR+1:0]     act_rp,
    input      [DIMW-1:0]     out_h,
    input      [DIMW-1:0]     out_w,
    input      [ADDR-1:0]     out_base,
    input      [ADDR-1:0]     out_rp_w,
    input      [ADDR-1:0]     out_ch_pitch,

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

	wire                    dma_start, dma_busy, dma_done;
	wire [EAW-1:0]          dma_ext_base;
	wire [ADDR-1:0]         dma_sram_base;
	wire [ADDR:0]           dma_nwords;
	wire                    dma_wr_en;
	wire [ADDR-1:0]         dma_wr_addr;
	wire [31:0]             dma_wr_data;
	wire                    img_phase;

	wire                    feed_start;
	wire [9:0]              wgt_base;
	wire signed [ADDR+2:0]  tile_addr;
	wire signed [DIMW+1:0]  y0, x0;
	wire [3:0]              lane_on;

	wire                    act_busy, act_mem_en, act_valid;
	wire [ADDR-1:0]         act_addr0, act_addr1;
	wire [31:0]             act_rdata0, act_rdata1, act_lanes;

	wire                    wgt_busy, wgt_mem_en, wgt_valid;
	wire [9:0]              wgt_mem_addr;
	wire [31:0]             wgt_rdata, wgt_lanes;

	wire [N*8-1:0]          act_sk, wgt_sk;
	wire [N*32-1:0]         c_col;
	wire [N*2-1:0]          c_row;
	wire [N-1:0]            c_valid;

	wire                    desc_push, desc_full;
	wire [ADDR-1:0]         desc_addr;
	wire [3:0]              desc_cols;

	wire [31:0]             unused_wgt_rdata0;
	wire [N*N-1:0]          unused_pe_done;
	wire                    unused_arr_done;
	wire                    unused_dma_busy = dma_busy;

	reset_sync u_rst (
		.rst_sync(rst_s), .rst_async(rst_n), .clk(clk)
	);

	layer_controller #(.EAW(EAW), .SAW(ADDR), .ADDR(ADDR), .DIMW(DIMW)) u_ctrl (
		.clk(clk), .rst_n(rst_s), .start(start), .busy(busy), .done(done), .img_phase(img_phase),
		.img_ext_base(img_ext_base), .img_words(img_words), .wgt_ext_base(wgt_ext_base),
		.m(m), .n_groups(n_groups), .last_cols(last_cols),
		.out_h(out_h), .out_w(out_w), .pad(pad), .tile_addr0(tile_addr0), .act_rp(act_rp),
		.out_base(out_base), .out_rp_w(out_rp_w), .out_ch_pitch(out_ch_pitch),
		.dma_start(dma_start), .dma_ext_base(dma_ext_base), .dma_sram_base(dma_sram_base),
		.dma_nwords(dma_nwords), .dma_done(dma_done),
		.feed_start(feed_start), .wgt_base(wgt_base), .tile_addr(tile_addr), .y0(y0), .x0(x0),
		.lane_on(lane_on), .act_busy(act_busy), .wgt_busy(wgt_busy),
		.desc_push(desc_push), .desc_addr(desc_addr), .desc_cols(desc_cols), .desc_full(desc_full),
		.pkt_last(pkt_last)
	);

	dma #(.EAW(EAW), .SAW(ADDR)) u_dma (
		.clk(clk), .rst_n(rst_s),
		.start(dma_start), .ext_base(dma_ext_base), .sram_base(dma_sram_base), .nwords(dma_nwords),
		.busy(dma_busy), .done(dma_done),
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
		.en1(wgt_mem_en), .addr1(wgt_mem_addr), .rdata1(wgt_rdata)
	);

	act_feeder #(.ADDR(ADDR), .DIMW(DIMW), .KW_W(3), .CW(8)) u_act (
		.clk(clk), .rst_n(rst_s), .start(feed_start),
		.tile_addr(tile_addr), .y0(y0), .x0(x0), .lane_on(lane_on),
		.in_h(in_h), .in_w(in_w), .kh_max(kh_max), .kw_max(kw_max), .c_max(c_max),
		.step_kh(step_kh), .step_c(step_c),
		.mem_rdata0(act_rdata0), .mem_rdata1(act_rdata1),
		.busy(act_busy), .mem_en(act_mem_en), .mem_addr0(act_addr0), .mem_addr1(act_addr1),
		.lanes(act_lanes), .valid(act_valid)
	);

	wgt_feeder #(.WIDTH(32), .ADDR(10)) u_wgtf (
		.clk(clk), .rst_n(rst_s), .start(feed_start), .base(wgt_base), .m(m),
		.mem_rdata(wgt_rdata), .busy(wgt_busy), .mem_en(wgt_mem_en), .mem_addr(wgt_mem_addr),
		.lanes(wgt_lanes), .valid(wgt_valid)
	);

	skew_buffer #(.LANES(N), .WIDTH(8)) u_skew_act (
		.clk(clk), .rst_n(rst_s), .din(act_lanes), .dout(act_sk)
	);

	skew_buffer #(.LANES(N), .WIDTH(8)) u_skew_wgt (
		.clk(clk), .rst_n(rst_s), .din(wgt_lanes), .dout(wgt_sk)
	);

	systolic_array #(.TILE_MAX(N), .WIDTH(8)) u_array (
		.c_col(c_col), .c_row(c_row), .c_valid(c_valid), .pe_done(unused_pe_done), .done(unused_arr_done),
		.a(wgt_sk), .b(act_sk), .clk(clk), .rst_n(rst_s), .en(act_valid && wgt_valid)
	);

	result_collector #(.N(N), .ACC_W(32), .ADDR(ADDR), .QD(4)) u_coll (
		.clk(clk), .rst_n(rst_s),
		.c_col(c_col), .c_row(c_row), .c_valid(c_valid), .ch_pitch(out_ch_pitch),
		.desc_push(desc_push), .desc_addr(desc_addr), .desc_lanes(lane_on), .desc_cols(desc_cols),
		.desc_full(desc_full),
		.pkt_valid(pkt_valid), .pkt_data(pkt_data), .pkt_addr(pkt_addr), .pkt_be(pkt_be), .pkt_last(pkt_last)
	);
endmodule
