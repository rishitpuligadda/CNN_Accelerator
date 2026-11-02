module vector_unit #(
    parameter LANES = 4,
    parameter ADDR  = 11,
    parameter PM_AW = 6,
    parameter LM_AW = 8
) (
    input                        clk,
    input                        rst_n,

    input                        pm_we,
    input      [PM_AW-1:0]       pm_waddr,
    input      [31:0]            pm_wdata,

    input                        lut_we,
    input      [7:0]             lut_waddr,
    input      [15:0]            lut_wdata,

    input      [PM_AW-1:0]       pro_start,
    input      [PM_AW:0]         pro_len,
    input      [PM_AW-1:0]       body_start,
    input      [PM_AW:0]         body_len,
    input      [PM_AW-1:0]       epi_start,
    input      [PM_AW:0]         epi_len,
    input      [8:0]             pro_cnt,
    input      [8:0]             epi_cnt,
    input      [PM_AW-1:0]       epi1_start,
    input      [PM_AW:0]         epi1_len,
    input      [8:0]             epi1_cnt,
    input      [PM_AW-1:0]       epi2_start,
    input      [PM_AW:0]         epi2_len,
    input      [8:0]             epi2_cnt,
    input      [PM_AW-1:0]       epi3_start,
    input      [PM_AW:0]         epi3_len,
    input      [8:0]             epi3_cnt,

    input                        layer_start,
    input                        layer_end,
    output reg                   busy,
    output reg                   done,

    input                        pkt_valid,
    output                       pkt_ready,
    input      [LANES*32-1:0]    pkt_data,
    input      [ADDR-1:0]        pkt_addr,
    input      [LANES-1:0]       pkt_be,
    input      [7:0]             pkt_row,
    input      [7:0]             pkt_col,
    input      [7:0]             pkt_chan,
    input                        pkt_last,

    output reg                   st_en,
    output reg [ADDR-1:0]        st_addr,
    output reg [LANES-1:0]       st_be,
    output reg [LANES*8-1:0]     st_data
);
	localparam S_IDLE = 3'd0;
	localparam S_PRO  = 3'd1;
	localparam S_WAIT = 3'd2;
	localparam S_BODY = 3'd3;
	localparam S_EPI  = 3'd4;
	localparam S_FIN  = 3'd5;

	localparam OP_NOP   = 6'h00;
	localparam OP_LI    = 6'h01;
	localparam OP_LUI   = 6'h02;
	localparam OP_ORI   = 6'h03;
	localparam OP_ADDS  = 6'h04;
	localparam OP_ADDIS = 6'h05;
	localparam OP_SHLS  = 6'h06;
	localparam OP_SHRS  = 6'h07;
	localparam OP_TAG   = 6'h08;
	localparam OP_SETP  = 6'h0C;
	localparam OP_ANDIS = 6'h0D;
	localparam OP_RCP   = 6'h0B;
	localparam OP_MULS  = 6'h0E;
	localparam OP_SLLV  = 6'h0F;
	localparam OP_SETR  = 6'h14;
	localparam OP_ST8A  = 6'h39;
	localparam OP_LUTW  = 6'h3D;
	localparam OP_LUT   = 6'h23;
	localparam OP_RMAX  = 6'h32;
	localparam OP_RADD  = 6'h33;
	localparam OP_LDS   = 6'h3B;
	localparam OP_STS   = 6'h3C;
	localparam OP_LDS8  = 6'h3E;
	localparam OP_STS8  = 6'h3F;
	localparam OP_SETQ  = 6'h09;
	localparam OP_SETC  = 6'h0A;
	localparam OP_MOV   = 6'h10;
	localparam OP_VLI   = 6'h11;
	localparam OP_BCAST = 6'h12;
	localparam OP_IDX   = 6'h13;
	localparam OP_CMPGT = 6'h28;
	localparam OP_CMPEQ = 6'h29;
	localparam OP_SEL   = 6'h2A;
	localparam OP_MBE   = 6'h2B;
	localparam OP_MAXP  = 6'h30;
	localparam OP_ADDP  = 6'h31;
	localparam OP_PERM  = 6'h34;
	localparam OP_PERMS = 6'h35;

	localparam PB       = (LANES <= 2) ? 1 : ((LANES <= 4) ? 2 : 3);
	localparam LB       = PB;           // log2(LANES): pixels per output word = LANES
	localparam OP_ADD   = 6'h18;
	localparam OP_SUB   = 6'h19;
	localparam OP_ADDI  = 6'h1A;
	localparam OP_MAX   = 6'h1B;
	localparam OP_MIN   = 6'h1C;
	localparam OP_SHL   = 6'h1D;
	localparam OP_SHR   = 6'h1E;
	localparam OP_SHRR  = 6'h1F;
	localparam OP_MUL   = 6'h20;
	localparam OP_REQ   = 6'h21;
	localparam OP_CLAMP = 6'h22;
	localparam OP_ST8   = 6'h38;

	localparam L_PASS   = 4'd0;
	localparam L_ADD    = 4'd1;
	localparam L_SUB    = 4'd2;
	localparam L_MAX    = 4'd3;
	localparam L_MIN    = 4'd4;
	localparam L_SHL    = 4'd5;
	localparam L_SHR    = 4'd6;
	localparam L_SHRR   = 4'd7;
	localparam L_CLAMP  = 4'd8;
	localparam L_CLAMP8 = 4'd9;
	localparam L_MUL    = 4'd10;
	localparam L_REQ    = 4'd11;

	reg  [31:0]          pm [0:(1<<PM_AW)-1];
	reg  [2:0]           state;
	reg  [PM_AW-1:0]     pc;
	reg  [PM_AW:0]       left;
	reg  [2:0]           sec;          // 0 prologue, 1..4 epilogue 0..3
	reg  [8:0]           iter;

	// section table: start, length and repeat count (0 counts as 1)
	reg  [PM_AW-1:0]     t_start;
	reg  [PM_AW:0]       t_len;
	reg  [8:0]           t_cnt;
	always @* begin
		case (sec)
			3'd1:    begin t_start = epi_start;  t_len = epi_len;  t_cnt = epi_cnt;  end
			3'd2:    begin t_start = epi1_start; t_len = epi1_len; t_cnt = epi1_cnt; end
			3'd3:    begin t_start = epi2_start; t_len = epi2_len; t_cnt = epi2_cnt; end
			3'd4:    begin t_start = epi3_start; t_len = epi3_len; t_cnt = epi3_cnt; end
			default: begin t_start = pro_start;  t_len = pro_len;  t_cnt = pro_cnt;  end
		endcase
	end
	wire                 more_iter = ({1'b0, iter} + 10'd1) < ((t_cnt == 9'd0) ? 10'd1 : {1'b0, t_cnt});

	// first non-empty epilogue section from index 1, and after the current one; 0 = none
	reg  [2:0]           nx_first, nx_after;
	always @* begin
		nx_first = (epi_len  != 0) ? 3'd1 :
		           (epi1_len != 0) ? 3'd2 :
		           (epi2_len != 0) ? 3'd3 :
		           (epi3_len != 0) ? 3'd4 : 3'd0;
		nx_after = 3'd0;
		if      (sec < 3'd2 && epi1_len != 0) nx_after = 3'd2;
		else if (sec < 3'd3 && epi2_len != 0) nx_after = 3'd3;
		else if (sec < 3'd4 && epi3_len != 0) nx_after = 3'd4;
	end
	wire                 nx_waiting = (state == S_WAIT);
	reg  [PM_AW-1:0]     n_start;
	reg  [PM_AW:0]       n_len;
	always @* begin
		case (nx_waiting ? nx_first : nx_after)
			3'd2:    begin n_start = epi1_start; n_len = epi1_len; end
			3'd3:    begin n_start = epi2_start; n_len = epi2_len; end
			3'd4:    begin n_start = epi3_start; n_len = epi3_len; end
			default: begin n_start = epi_start;  n_len = epi_len;  end
		endcase
	end
	reg                  end_req;

	reg  [LANES*32-1:0]  cur_data;
	reg  [ADDR-1:0]      cur_addr;
	reg  [LANES-1:0]     cur_be;
	reg  [7:0]           cur_row, cur_col, cur_chan;
	reg                  cur_last;
	reg  [LANES-1:0]     mask;
	reg  [31:0]          ar_base;
	reg  [15:0]          ar_chp, ar_rp;
	reg  [1:0]           ar_l;
	reg  [LANES*32-1:0]  lmem [0:(1<<LM_AW)-1];
	reg  [15:0]          lut  [0:255];
	reg                  rcp_busy;
	reg  [5:0]           rcp_cnt;
	reg  [31:0]          rcp_d, rcp_q, rcp_n;
	reg  [31:0]          rcp_r;
	wire [32:0]          rcp_t = {rcp_r, rcp_n[31]};
	reg  [3:0]           rcp_dst;
	wire                 rcp_done = rcp_busy && (rcp_cnt == 6'd0);
	reg  [2:0]           pt_tag [2:7];
	reg  [1:0]           pt_op  [2:7];
	reg  [9:0]           pt_val [2:7];

	wire                 running = (state == S_PRO) || (state == S_BODY) || (state == S_EPI);
	wire [31:0]          ins     = pm[pc];
	wire [5:0]           op      = ins[31:26];
	wire [3:0]           fd      = ins[22:19];
	wire [3:0]           fa      = ins[18:15];
	wire [3:0]           fb      = ins[14:11];
	wire [10:0]          fx      = ins[10:0];
	wire [14:0]          imm15   = {fb, fx};
	wire [18:0]          imm19   = {fa, fb, fx};
	wire [2:0]           pred    = ins[25:23];
	wire [31:0]          simm15  = {{17{imm15[14]}}, imm15};
	wire [31:0]          simm19  = {{13{imm19[18]}}, imm19};

	reg  [3:0]           lop;
	reg                  vec_op, slow_op, st_op, reads_a, reads_b, writes_v;
	reg                  a_imm, a_bcast, b_imm, a_idx, a_sel, cmp_op, pairw, permw, perm_s, ld_op, st8a, a_lut;

	always @* begin
		lop = L_PASS; vec_op = 1'b0; slow_op = 1'b0; st_op = 1'b0;
		reads_a = 1'b0; reads_b = 1'b0; writes_v = 1'b0;
		a_imm = 1'b0; a_bcast = 1'b0; b_imm = 1'b0; a_idx = 1'b0; a_sel = 1'b0; cmp_op = 1'b0; pairw = 1'b0; permw = 1'b0; perm_s = 1'b0; ld_op = 1'b0; st8a = 1'b0; a_lut = 1'b0;
		case (op)
			OP_MOV:   begin vec_op = 1'b1; lop = L_PASS;  reads_a = 1'b1; writes_v = 1'b1; end
			OP_VLI:   begin vec_op = 1'b1; lop = L_PASS;  a_imm = 1'b1;   writes_v = 1'b1; end
			OP_BCAST: begin vec_op = 1'b1; lop = L_PASS;  a_bcast = 1'b1; writes_v = 1'b1; end
			OP_ADD:   begin vec_op = 1'b1; lop = L_ADD;   reads_a = 1'b1; reads_b = 1'b1; writes_v = 1'b1; end
			OP_SUB:   begin vec_op = 1'b1; lop = L_SUB;   reads_a = 1'b1; reads_b = 1'b1; writes_v = 1'b1; end
			OP_ADDI:  begin vec_op = 1'b1; lop = L_ADD;   reads_a = 1'b1; b_imm = 1'b1;   writes_v = 1'b1; end
			OP_MAX:   begin vec_op = 1'b1; lop = L_MAX;   reads_a = 1'b1; reads_b = 1'b1; writes_v = 1'b1; end
			OP_MIN:   begin vec_op = 1'b1; lop = L_MIN;   reads_a = 1'b1; reads_b = 1'b1; writes_v = 1'b1; end
			OP_SHL:   begin vec_op = 1'b1; lop = L_SHL;   reads_a = 1'b1; writes_v = 1'b1; end
			OP_SHR:   begin vec_op = 1'b1; lop = L_SHR;   reads_a = 1'b1; writes_v = 1'b1; end
			OP_SHRR:  begin vec_op = 1'b1; lop = L_SHRR;  reads_a = 1'b1; writes_v = 1'b1; end
			OP_MUL:   begin vec_op = 1'b1; lop = L_MUL;   reads_a = 1'b1; reads_b = 1'b1; writes_v = 1'b1; slow_op = 1'b1; end
			OP_REQ:   begin vec_op = 1'b1; lop = L_REQ;   reads_a = 1'b1; writes_v = 1'b1; slow_op = 1'b1; end
			OP_CLAMP: begin vec_op = 1'b1; lop = L_CLAMP; reads_a = 1'b1; writes_v = 1'b1; end
			OP_ST8:   begin vec_op = 1'b1; lop = L_CLAMP8; reads_a = 1'b1; st_op = 1'b1; end
			OP_ST8A:  begin vec_op = 1'b1; lop = L_CLAMP8; reads_a = 1'b1; st_op = 1'b1; st8a = 1'b1; end
			OP_LUT:   begin vec_op = 1'b1; lop = L_PASS;  a_lut = 1'b1;   reads_a = 1'b1; writes_v = 1'b1; end
			OP_RMAX:  begin cmp_op = 1'b1; reads_a = 1'b1; end
			OP_RADD:  begin cmp_op = 1'b1; reads_a = 1'b1; end
			OP_LDS:   begin ld_op = 1'b1; end
			OP_LDS8:  begin ld_op = 1'b1; end
			OP_STS:   begin cmp_op = 1'b1; reads_a = 1'b1; end
			OP_STS8:  begin cmp_op = 1'b1; reads_a = 1'b1; end
			OP_IDX:   begin vec_op = 1'b1; lop = L_PASS;  a_idx = 1'b1;   writes_v = 1'b1; end
			OP_SEL:   begin vec_op = 1'b1; lop = L_PASS;  a_sel = 1'b1;   reads_a = 1'b1; reads_b = 1'b1; writes_v = 1'b1; end
			OP_MAXP:  begin vec_op = 1'b1; lop = L_MAX;   pairw = 1'b1;   reads_a = 1'b1; writes_v = 1'b1; end
			OP_ADDP:  begin vec_op = 1'b1; lop = L_ADD;   pairw = 1'b1;   reads_a = 1'b1; writes_v = 1'b1; end
			OP_PERM:  if (LANES * PB <= 11) begin
			              vec_op = 1'b1; lop = L_PASS; permw = 1'b1; reads_a = 1'b1; writes_v = 1'b1;
			          end
			OP_PERMS: begin vec_op = 1'b1; lop = L_PASS;  permw = 1'b1; perm_s = 1'b1; reads_a = 1'b1; writes_v = 1'b1; end
			OP_CMPGT: begin cmp_op = 1'b1; reads_a = 1'b1; reads_b = 1'b1; end
			OP_CMPEQ: begin cmp_op = 1'b1; reads_a = 1'b1; reads_b = 1'b1; end
			OP_NOP:   begin end
			default:  begin end
		endcase
	end

	reg                  slow_q;
	reg  [2:0]           slow_dst_q;
	wire                 dep    = slow_q && ((reads_a && fa[2:0] == slow_dst_q) || (reads_b && fb[2:0] == slow_dst_q));
	wire                 stall  = running && (((vec_op || cmp_op) && dep) || rcp_busy);
	wire                 issue  = running && !stall;

	reg  [10:0]          tag_v, pv, kmask;
	reg  [3:0]           pk;
	reg                  pkt_pred;
	always @* begin
		case (pt_tag[pred])
			3'd0:    tag_v = {{(11-ADDR){1'b0}}, cur_addr};
			3'd1:    tag_v = {{(11-LANES){1'b0}}, cur_be};
			3'd2:    tag_v = {3'd0, cur_row};
			3'd3:    tag_v = {3'd0, cur_col};
			3'd4:    tag_v = {3'd0, cur_chan};
			3'd5:    tag_v = {10'd0, cur_last};
			default: tag_v = 11'd0;
		endcase
		pk    = pt_val[pred][9:6];
		pv    = {5'd0, pt_val[pred][5:0]};
		kmask = (11'd1 << pk) - 11'd1;
		case (pt_op[pred])
			2'd0:    pkt_pred = (tag_v == {1'b0, pt_val[pred]});
			2'd1:    pkt_pred = (tag_v != {1'b0, pt_val[pred]});
			2'd2:    pkt_pred = ((tag_v & kmask) == (pv & kmask));
			default: pkt_pred = ((tag_v & kmask) != (pv & kmask));
		endcase
	end

	// ---------------------------------------------------------------- address unit (spec 2.7)
	wire [31:0]          au_paddr = ar_base + {24'd0, cur_chan} * {16'd0, ar_chp}
	                              + {24'd0, (cur_row >> ar_l)} * {16'd0, ar_rp}
	                              + {24'd0, (cur_col >> (ar_l + LB))};
	reg  [LANES-1:0]     au_pv;
	wire [7:0]           au_sh    = (cur_col >> ar_l) & 8'(LANES - 1);
	wire [LANES-1:0]     au_pbe   = au_pv << au_sh;
	wire [31:0]          au_lmidx = {24'd0, 1'b0, cur_chan[1:0], 5'd0} + {24'd0, (cur_col >> LB)};
	integer              aj;
	always @* begin
		au_pv = {LANES{1'b0}};
		for (aj = 0; aj < LANES; aj = aj + 1)
			if (aj < (LANES >> ar_l)) au_pv[aj] = cur_be[((aj + 1) << ar_l) - 1];
	end

	wire                 pred_ok = (pred[2:1] == 2'b00) || pkt_pred;
	wire                 exec    = issue && pred_ok;
	wire [LANES-1:0]     wlanes  = (pred == 3'd1) ? mask : {LANES{1'b1}};
	wire                 last_i = (left == 1);

	wire [LANES*32-1:0]  vda, vdb;
	wire [31:0]          sda, sdb;
	wire [15:0]          mpos, mneg;
	wire [5:0]           sh6;
	wire [31:0]          lo, hi;

	wire [LANES*32-1:0]  r1_all, r2_all;
	wire [LANES-1:0]     v1_all, v2_all;

	reg                  f_wr_q, f_st_q;
	reg  [2:0]           f_dst_q;
	reg  [ADDR-1:0]      f_addr_q;
	reg  [LANES-1:0]     f_be_q;
	reg                  s_wr_q1, s_wr_q2;
	reg  [LANES-1:0]     f_lanes_q, s_lanes_q1, s_lanes_q2;
	reg                  ld_q1, ld_q2, ld8_q1;
	reg  [2:0]           ld_dst_q1, ld_dst_q2;
	reg  [LANES-1:0]     ld_lanes_q1, ld_lanes_q2;
	reg  [1:0]           ld_slot_q1;
	reg  [LANES*32-1:0]  ld_raw_q, ld_res_q;
	reg  [LANES*32-1:0]  ld_conv;
	integer              lk;
	always @* begin
		for (lk = 0; lk < LANES; lk = lk + 1)
			ld_conv[lk*32 +: 32] = ld8_q1 ? {{24{ld_raw_q[lk*32 + ld_slot_q1*8 + 7]}}, ld_raw_q[lk*32 + ld_slot_q1*8 +: 8]}
			                              : ld_raw_q[lk*32 +: 32];
	end
	reg  [2:0]           s_dst_q1, s_dst_q2;

	wire [31:0]          muls_p = sda * {{16{sdb[15]}}, sdb[15:0]};
	reg  [31:0]          red_max, red_sum;
	integer              rk;
	always @* begin
		red_max = 32'h80000000;
		red_sum = 32'd0;
		for (rk = 0; rk < LANES; rk = rk + 1)
			if (cur_be[rk]) begin
				if ($signed(vda[rk*32 +: 32]) > $signed(red_max)) red_max = vda[rk*32 +: 32];
				red_sum = red_sum + vda[rk*32 +: 32];
			end
	end
	reg                  sw_en;
	reg  [3:0]           sw_idx;
	reg  [31:0]          sw_data;
	reg                  q_we, c_we;

	always @* begin
		sw_en = 1'b0; sw_idx = fd; sw_data = 32'd0; q_we = 1'b0; c_we = 1'b0;
		if (rcp_done) begin
			sw_en   = 1'b1;
			sw_idx  = rcp_dst;
			sw_data = rcp_q;
		end
		else if (exec) begin
			case (op)
				OP_LI:   begin sw_en = 1'b1; sw_data = simm19; end
				OP_LUI:  begin sw_en = 1'b1; sw_data = {imm19[15:0], 16'd0}; end
				OP_ORI:  begin sw_en = 1'b1; sw_data = sda | {16'd0, imm19[15:0]}; end
				OP_TAG:  begin
					sw_en = 1'b1;
					case (fx[3:0])
						4'd0:    sw_data = {{(32-ADDR){1'b0}}, cur_addr};
						4'd1:    sw_data = {{(32-LANES){1'b0}}, cur_be};
						4'd2:    sw_data = {24'd0, cur_row};
						4'd3:    sw_data = {24'd0, cur_col};
						4'd4:    sw_data = {24'd0, cur_chan};
						4'd5:    sw_data = {31'd0, cur_last};
						4'd6:    sw_data = au_paddr;
						4'd7:    sw_data = {{(32-LANES){1'b0}}, au_pbe};
						4'd8:    sw_data = au_lmidx;
						4'd9:    sw_data = {23'd0, iter};
						default: sw_data = 32'd0;
					endcase
				end
				OP_MULS:  begin sw_en = 1'b1; sw_data = muls_p[31:0]; end
				OP_RMAX:  begin sw_en = 1'b1; sw_data = red_max; end
				OP_RADD:  begin sw_en = 1'b1; sw_data = red_sum; end
				OP_SLLV:  begin sw_en = 1'b1; sw_data = sda << sdb[4:0]; end
				OP_ADDS:  begin sw_en = 1'b1; sw_data = sda + sdb; end
				OP_ADDIS: begin sw_en = 1'b1; sw_data = sda + simm15; end
				OP_SHLS:  begin sw_en = 1'b1; sw_data = sda << fx[4:0]; end
				OP_SHRS:  begin sw_en = 1'b1; sw_data = $signed(sda) >>> fx[4:0]; end
				OP_ANDIS: begin sw_en = 1'b1; sw_data = sda & {17'd0, imm15}; end
				OP_SETQ: q_we = 1'b1;
				OP_SETC: c_we = 1'b1;
				default: begin end
			endcase
		end
	end

	vu_regs #(.LANES(LANES)) u_regs (
		.clk(clk), .rst_n(rst_n),
		.vra(fa[2:0]), .vrb(fb[2:0]), .vda(vda), .vdb(vdb), .pkt_data(cur_data),
		.vw0_en((s_wr_q2 && (&v2_all)) || ld_q2), .vw0_idx(ld_q2 ? ld_dst_q2 : s_dst_q2),
		.vw0_lanes(ld_q2 ? ld_lanes_q2 : s_lanes_q2), .vw0_data(ld_q2 ? ld_res_q : r2_all),
		.vw1_en(f_wr_q && (&v1_all)), .vw1_idx(f_dst_q), .vw1_lanes(f_lanes_q), .vw1_data(r1_all),
		.sra((op == OP_ORI || op == OP_ST8A) ? fd : fa), .srb(fb), .sda(sda), .sdb(sdb),
		.sw_en(sw_en), .sw_idx(sw_idx), .sw_data(sw_data),
		.q_we(q_we), .q_widx(fd[1:0]), .q_mpos(sda[15:0]), .q_mneg(sdb[15:0]), .q_s(fx[5:0]),
		.q_ridx(fx[1:0]), .mpos(mpos), .mneg(mneg), .s(sh6),
		.c_we(c_we), .c_widx(fd[1:0]), .c_lo(sda), .c_hi(sdb),
		.c_ridx(fx[1:0]), .lo(lo), .hi(hi)
	);

	genvar i;
	generate
		for (i = 0; i < LANES; i = i + 1) begin : LANE
			localparam [31:0] LIDX = i;
			wire [31:0] pair_a, pair_b;
			if (2 * i + 1 < LANES) begin : PAIR
				assign pair_a = vda[(2*i)*32 +: 32];
				assign pair_b = vda[(2*i+1)*32 +: 32];
			end
			else begin : NOPAIR
				assign pair_a = 32'd0;
				assign pair_b = 32'd0;
			end
			wire [PB-1:0] psel_imm, psel;
			if (i * PB + PB <= 11) begin : PIMM
				assign psel_imm = fx[i*PB +: PB];
			end
			else begin : NOPIMM
				assign psel_imm = {PB{1'b0}};
			end
			assign psel = perm_s ? sdb[i*PB +: PB] : psel_imm;
			wire [31:0] perm_v = vda[psel*32 +: 32];
			wire [15:0] lut_e  = lut[vda[i*32 +: 8]];
			wire [31:0] lut_v  = {{16{lut_e[15]}}, lut_e};
			wire [31:0] a_in = a_imm   ? simm15 :
			                   a_bcast ? sda    :
			                   a_idx   ? LIDX   :
			                   pairw   ? pair_a :
			                   permw   ? perm_v :
			                   a_lut   ? lut_v  :
			                   (a_sel && !mask[i]) ? vdb[i*32 +: 32] : vda[i*32 +: 32];
			wire [31:0] b_in = b_imm   ? simm15 :
			                   pairw   ? pair_b : vdb[i*32 +: 32];

			vu_lane u_lane (
				.clk(clk), .rst_n(rst_n), .lop(lop), .issue(exec && vec_op),
				.a(a_in), .b(b_in), .sh(fx[4:0]),
				.mpos(mpos), .mneg(mneg), .s(sh6), .lo(lo), .hi(hi),
				.r1(r1_all[i*32 +: 32]), .v1(v1_all[i]), .r2(r2_all[i*32 +: 32]), .v2(v2_all[i])
			);
		end
	endgenerate

	assign pkt_ready = (state == S_WAIT && pkt_valid) || (state == S_BODY && issue && last_i && pkt_valid);

	wire                 pipe_empty = !f_wr_q && !f_st_q && !s_wr_q1 && !s_wr_q2 && !ld_q1 && !ld_q2 && !rcp_busy;

	integer              k;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			state      <= S_IDLE;
			pc         <= {PM_AW{1'b0}};
			left       <= {(PM_AW+1){1'b0}};
			sec        <= 3'd0;
			iter       <= 9'd0;
			end_req    <= 1'b0;
			busy       <= 1'b0;
			done       <= 1'b0;
			cur_data   <= {(LANES*32){1'b0}};
			cur_addr   <= {ADDR{1'b0}};
			cur_be     <= {LANES{1'b0}};
			cur_row    <= 8'd0;
			cur_col    <= 8'd0;
			cur_chan   <= 8'd0;
			cur_last   <= 1'b0;
			mask       <= {LANES{1'b0}};
			for (k = 2; k < 8; k = k + 1) begin
				pt_tag[k] <= 3'd0;
				pt_op[k]  <= 2'd0;
				pt_val[k] <= 10'd0;
			end
			f_lanes_q  <= {LANES{1'b0}};
			rcp_busy   <= 1'b0;
			rcp_cnt    <= 6'd0;
			rcp_d      <= 32'd0;
			rcp_q      <= 32'd0;
			rcp_n      <= 32'd0;
			rcp_r      <= 32'd0;
			rcp_dst    <= 4'd0;
			ar_base    <= 32'd0;
			ar_chp     <= 16'd0;
			ar_rp      <= 16'd0;
			ar_l       <= 2'd0;
			ld_q1      <= 1'b0;
			ld_q2      <= 1'b0;
			ld8_q1     <= 1'b0;
			ld_dst_q1  <= 3'd0;
			ld_dst_q2  <= 3'd0;
			ld_lanes_q1 <= {LANES{1'b0}};
			ld_lanes_q2 <= {LANES{1'b0}};
			ld_slot_q1 <= 2'd0;
			ld_raw_q   <= {(LANES*32){1'b0}};
			ld_res_q   <= {(LANES*32){1'b0}};
			s_lanes_q1 <= {LANES{1'b0}};
			s_lanes_q2 <= {LANES{1'b0}};
			slow_q     <= 1'b0;
			slow_dst_q <= 3'd0;
			f_wr_q     <= 1'b0;
			f_st_q     <= 1'b0;
			f_dst_q    <= 3'd0;
			f_addr_q   <= {ADDR{1'b0}};
			f_be_q     <= {LANES{1'b0}};
			s_wr_q1    <= 1'b0;
			s_wr_q2    <= 1'b0;
			s_dst_q1   <= 3'd0;
			s_dst_q2   <= 3'd0;
			st_en      <= 1'b0;
			st_addr    <= {ADDR{1'b0}};
			st_be      <= {LANES{1'b0}};
			st_data    <= {(LANES*8){1'b0}};
		end
		else begin
			done <= 1'b0;
			if (layer_end) end_req <= 1'b1;

			slow_q     <= exec && (slow_op || ld_op);
			slow_dst_q <= fd[2:0];

			f_wr_q    <= exec && vec_op && !slow_op && writes_v;
			f_st_q    <= exec && st_op;
			f_dst_q   <= fd[2:0];
			f_addr_q  <= st8a ? sdb[ADDR-1:0] : cur_addr;
			f_be_q    <= (st8a ? sda[LANES-1:0] : cur_be) & wlanes;
			f_lanes_q <= wlanes;

			s_wr_q1    <= exec && slow_op;
			s_dst_q1   <= fd[2:0];
			s_lanes_q1 <= wlanes;
			s_wr_q2    <= s_wr_q1;
			s_dst_q2   <= s_dst_q1;
			s_lanes_q2 <= s_lanes_q1;

			if (exec && op == OP_CMPGT)
				for (k = 0; k < LANES; k = k + 1)
					mask[k] <= $signed(vda[k*32 +: 32]) > $signed(vdb[k*32 +: 32]);
			if (exec && op == OP_CMPEQ)
				for (k = 0; k < LANES; k = k + 1)
					mask[k] <= vda[k*32 +: 32] == vdb[k*32 +: 32];
			if (exec && op == OP_MBE)
				mask <= cur_be;
			// RCP: restoring division of 2^n by the scalar, one quotient bit per cycle (32 cycles).
			if (exec && op == OP_RCP) begin
				rcp_busy <= 1'b1;
				rcp_cnt  <= 6'd32;
				rcp_d    <= sda;
				rcp_n    <= 32'd1 << fx[4:0];
				rcp_r    <= 32'd0;
				rcp_q    <= 32'd0;
				rcp_dst  <= fd;
			end
			else if (rcp_busy && rcp_cnt != 6'd0) begin
				if (rcp_t >= {1'b0, rcp_d}) begin
					rcp_r <= rcp_t[31:0] - rcp_d;
					rcp_q <= {rcp_q[30:0], 1'b1};
				end
				else begin
					rcp_r <= rcp_t[31:0];
					rcp_q <= {rcp_q[30:0], 1'b0};
				end
				rcp_n   <= {rcp_n[30:0], 1'b0};
				rcp_cnt <= rcp_cnt - 1'b1;
			end
			else if (rcp_done) begin
				rcp_busy <= 1'b0;
			end

			if (exec && op == OP_SETR)
				case (fx[1:0])
					2'd0:    ar_base <= sda;
					2'd1:    ar_chp  <= sda[15:0];
					2'd2:    ar_rp   <= sda[15:0];
					default: ar_l    <= sda[1:0];
				endcase

			ld_q1       <= exec && ld_op && (fd[2:0] != 3'd7);
			ld8_q1      <= (op == OP_LDS8);
			ld_dst_q1   <= fd[2:0];
			ld_lanes_q1 <= wlanes;
			ld_slot_q1  <= sda[1:0];
			if (exec && ld_op)
				ld_raw_q <= lmem[(op == OP_LDS8) ? sda[LM_AW+1:2] : sda[LM_AW-1:0]];
			ld_q2       <= ld_q1;
			ld_dst_q2   <= ld_dst_q1;
			ld_lanes_q2 <= ld_lanes_q1;
			if (ld_q1) ld_res_q <= ld_conv;

			if (exec && op == OP_SETP && fd[2:1] != 2'b00) begin
				pt_tag[fd[2:0]] <= fx[2:0];
				pt_op[fd[2:0]]  <= fx[4:3];
				pt_val[fd[2:0]] <= {fb, fx[10:5]};
			end

			st_en <= f_st_q;
			if (f_st_q) begin
				st_addr <= f_addr_q;
				st_be   <= f_be_q;
				for (k = 0; k < LANES; k = k + 1)
					st_data[k*8 +: 8] <= r1_all[k*32 +: 8];
			end

			if (pkt_ready) begin
				cur_data <= pkt_data;
				cur_addr <= pkt_addr;
				cur_be   <= pkt_be;
				cur_row  <= pkt_row;
				cur_col  <= pkt_col;
				cur_chan <= pkt_chan;
				cur_last <= pkt_last;
			end

			case (state)
				S_IDLE: begin
					if (layer_start) begin
						busy    <= 1'b1;
						end_req <= 1'b0;
						sec     <= 3'd0;
						iter    <= 9'd0;
						if (pro_len != 0) begin
							pc    <= pro_start;
							left  <= pro_len;
							state <= S_PRO;
						end
						else
							state <= S_WAIT;
					end
				end

				S_PRO: begin
					if (issue) begin
						if (last_i) begin
							if (more_iter) begin
								iter <= iter + 1'b1;
								pc   <= t_start;
								left <= t_len;
							end
							else begin
								iter  <= 9'd0;
								state <= S_WAIT;
							end
						end
						else begin
							pc   <= pc + 1'b1;
							left <= left - 1'b1;
						end
					end
				end

				S_WAIT: begin
					if (pkt_valid && body_len != 0) begin
						pc    <= body_start;
						left  <= body_len;
						state <= S_BODY;
					end
					else if (end_req && !pkt_valid) begin
						iter <= 9'd0;
						if (nx_first != 3'd0) begin
							sec   <= nx_first;
							pc    <= n_start;
							left  <= n_len;
							state <= S_EPI;
						end
						else
							state <= S_FIN;
					end
				end

				S_BODY: begin
					if (issue) begin
						if (last_i) begin
							if (pkt_valid) begin
								pc   <= body_start;
								left <= body_len;
							end
							else
								state <= S_WAIT;
						end
						else begin
							pc   <= pc + 1'b1;
							left <= left - 1'b1;
						end
					end
				end

				S_EPI: begin
					if (issue) begin
						if (last_i) begin
							if (more_iter) begin
								iter <= iter + 1'b1;
								pc   <= t_start;
								left <= t_len;
							end
							else if (nx_after != 3'd0) begin
								iter <= 9'd0;
								sec  <= nx_after;
								pc   <= n_start;
								left <= n_len;
							end
							else
								state <= S_FIN;
						end
						else begin
							pc   <= pc + 1'b1;
							left <= left - 1'b1;
						end
					end
				end

				S_FIN: begin
					if (pipe_empty && !st_en) begin
						busy    <= 1'b0;
						done    <= 1'b1;
						end_req <= 1'b0;
						state   <= S_IDLE;
					end
				end

				default: state <= S_IDLE;
			endcase
		end
	end

	always @(posedge clk) begin
		if (pm_we) pm[pm_waddr] <= pm_wdata;
		if (lut_we) lut[lut_waddr] <= lut_wdata;
		else if (exec && op == OP_LUTW) lut[sda[7:0]] <= sdb[15:0];
	end

	integer sk;
	always @(posedge clk) begin
		if (exec && op == OP_STS)
			for (sk = 0; sk < LANES; sk = sk + 1)
				if (wlanes[sk]) lmem[sdb[LM_AW-1:0]][sk*32 +: 32] <= vda[sk*32 +: 32];
		if (exec && op == OP_STS8)
			for (sk = 0; sk < LANES; sk = sk + 1)
				if (wlanes[sk])
					lmem[sdb[LM_AW+1:2]][sk*32 + sdb[1:0]*8 +: 8] <=
						($signed(vda[sk*32 +: 32]) < -32'sd128) ? 8'h80 :
						(($signed(vda[sk*32 +: 32]) > 32'sd127) ? 8'h7F : vda[sk*32 +: 8]);
	end
endmodule
