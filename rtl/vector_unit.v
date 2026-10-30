module vector_unit #(
    parameter LANES = 4,
    parameter ADDR  = 11,
    parameter PM_AW = 6
) (
    input                        clk,
    input                        rst_n,

    input                        pm_we,
    input      [PM_AW-1:0]       pm_waddr,
    input      [31:0]            pm_wdata,

    input      [PM_AW-1:0]       pro_start,
    input      [PM_AW:0]         pro_len,
    input      [PM_AW-1:0]       body_start,
    input      [PM_AW:0]         body_len,
    input      [PM_AW-1:0]       epi_start,
    input      [PM_AW:0]         epi_len,

    input                        layer_start,
    input                        layer_end,
    output reg                   busy,
    output reg                   done,

    input                        pkt_valid,
    output                       pkt_ready,
    input      [LANES*32-1:0]    pkt_data,
    input      [ADDR-1:0]        pkt_addr,
    input      [LANES-1:0]       pkt_be,

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
	localparam OP_TAG   = 6'h08;
	localparam OP_SETQ  = 6'h09;
	localparam OP_SETC  = 6'h0A;
	localparam OP_MOV   = 6'h10;
	localparam OP_VLI   = 6'h11;
	localparam OP_BCAST = 6'h12;
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
	reg                  end_req;

	reg  [LANES*32-1:0]  cur_data;
	reg  [ADDR-1:0]      cur_addr;
	reg  [LANES-1:0]     cur_be;

	wire                 running = (state == S_PRO) || (state == S_BODY) || (state == S_EPI);
	wire [31:0]          ins     = pm[pc];
	wire [5:0]           op      = ins[31:26];
	wire [3:0]           fd      = ins[22:19];
	wire [3:0]           fa      = ins[18:15];
	wire [3:0]           fb      = ins[14:11];
	wire [10:0]          fx      = ins[10:0];
	wire [14:0]          imm15   = {fb, fx};
	wire [18:0]          imm19   = {fa, fb, fx};
	wire [2:0]           unused_pred = ins[25:23];
	wire [31:0]          simm15  = {{17{imm15[14]}}, imm15};
	wire [31:0]          simm19  = {{13{imm19[18]}}, imm19};

	reg  [3:0]           lop;
	reg                  vec_op, slow_op, st_op, reads_a, reads_b, writes_v;
	reg                  a_imm, a_bcast, b_imm;

	always @* begin
		lop = L_PASS; vec_op = 1'b0; slow_op = 1'b0; st_op = 1'b0;
		reads_a = 1'b0; reads_b = 1'b0; writes_v = 1'b0;
		a_imm = 1'b0; a_bcast = 1'b0; b_imm = 1'b0;
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
			OP_NOP:   begin end
			default:  begin end
		endcase
	end

	reg                  slow_q;
	reg  [2:0]           slow_dst_q;
	wire                 dep    = slow_q && ((reads_a && fa[2:0] == slow_dst_q) || (reads_b && fb[2:0] == slow_dst_q));
	wire                 stall  = running && vec_op && dep;
	wire                 issue  = running && !stall;
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
	reg  [2:0]           s_dst_q1, s_dst_q2;

	reg                  sw_en;
	reg  [3:0]           sw_idx;
	reg  [31:0]          sw_data;
	reg                  q_we, c_we;

	always @* begin
		sw_en = 1'b0; sw_idx = fd; sw_data = 32'd0; q_we = 1'b0; c_we = 1'b0;
		if (issue) begin
			case (op)
				OP_LI:   begin sw_en = 1'b1; sw_data = simm19; end
				OP_LUI:  begin sw_en = 1'b1; sw_data = {imm19[15:0], 16'd0}; end
				OP_ORI:  begin sw_en = 1'b1; sw_data = sda | {16'd0, imm19[15:0]}; end
				OP_TAG:  begin
					sw_en   = 1'b1;
					sw_data = (fx[2:0] == 3'd0) ? {{(32-ADDR){1'b0}}, cur_addr} :
					          (fx[2:0] == 3'd1) ? {{(32-LANES){1'b0}}, cur_be} : 32'd0;
				end
				OP_SETQ: q_we = 1'b1;
				OP_SETC: c_we = 1'b1;
				default: begin end
			endcase
		end
	end

	vu_regs #(.LANES(LANES)) u_regs (
		.clk(clk), .rst_n(rst_n),
		.vra(fa[2:0]), .vrb(fb[2:0]), .vda(vda), .vdb(vdb), .pkt_data(cur_data),
		.vw0_en(s_wr_q2 && (&v2_all)), .vw0_idx(s_dst_q2), .vw0_lanes({LANES{1'b1}}), .vw0_data(r2_all),
		.vw1_en(f_wr_q && (&v1_all)), .vw1_idx(f_dst_q), .vw1_lanes({LANES{1'b1}}), .vw1_data(r1_all),
		.sra((op == OP_ORI) ? fd : fa), .srb(fb), .sda(sda), .sdb(sdb),
		.sw_en(sw_en), .sw_idx(sw_idx), .sw_data(sw_data),
		.q_we(q_we), .q_widx(fd[1:0]), .q_mpos(sda[15:0]), .q_mneg(sdb[15:0]), .q_s(fx[5:0]),
		.q_ridx(fx[1:0]), .mpos(mpos), .mneg(mneg), .s(sh6),
		.c_we(c_we), .c_widx(fd[1:0]), .c_lo(sda), .c_hi(sdb),
		.c_ridx(fx[1:0]), .lo(lo), .hi(hi)
	);

	genvar i;
	generate
		for (i = 0; i < LANES; i = i + 1) begin : LANE
			wire [31:0] a_in = a_imm   ? simm15 :
			                   a_bcast ? sda    : vda[i*32 +: 32];
			wire [31:0] b_in = b_imm   ? simm15 : vdb[i*32 +: 32];

			vu_lane u_lane (
				.clk(clk), .rst_n(rst_n), .lop(lop), .issue(issue && vec_op),
				.a(a_in), .b(b_in), .sh(fx[4:0]),
				.mpos(mpos), .mneg(mneg), .s(sh6), .lo(lo), .hi(hi),
				.r1(r1_all[i*32 +: 32]), .v1(v1_all[i]), .r2(r2_all[i*32 +: 32]), .v2(v2_all[i])
			);
		end
	endgenerate

	assign pkt_ready = (state == S_WAIT && pkt_valid) || (state == S_BODY && issue && last_i && pkt_valid);

	wire                 pipe_empty = !f_wr_q && !f_st_q && !s_wr_q1 && !s_wr_q2;

	integer              k;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			state      <= S_IDLE;
			pc         <= {PM_AW{1'b0}};
			left       <= {(PM_AW+1){1'b0}};
			end_req    <= 1'b0;
			busy       <= 1'b0;
			done       <= 1'b0;
			cur_data   <= {(LANES*32){1'b0}};
			cur_addr   <= {ADDR{1'b0}};
			cur_be     <= {LANES{1'b0}};
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

			slow_q     <= issue && slow_op;
			slow_dst_q <= fd[2:0];

			f_wr_q   <= issue && vec_op && !slow_op && writes_v;
			f_st_q   <= issue && st_op;
			f_dst_q  <= fd[2:0];
			f_addr_q <= cur_addr;
			f_be_q   <= cur_be;

			s_wr_q1  <= issue && slow_op;
			s_dst_q1 <= fd[2:0];
			s_wr_q2  <= s_wr_q1;
			s_dst_q2 <= s_dst_q1;

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
			end

			case (state)
				S_IDLE: begin
					if (layer_start) begin
						busy    <= 1'b1;
						end_req <= 1'b0;
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
						pc   <= pc + 1'b1;
						left <= left - 1'b1;
						if (last_i) state <= S_WAIT;
					end
				end

				S_WAIT: begin
					if (pkt_valid && body_len != 0) begin
						pc    <= body_start;
						left  <= body_len;
						state <= S_BODY;
					end
					else if (end_req && !pkt_valid) begin
						if (epi_len != 0) begin
							pc    <= epi_start;
							left  <= epi_len;
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
						pc   <= pc + 1'b1;
						left <= left - 1'b1;
						if (last_i) state <= S_FIN;
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
	end
endmodule
