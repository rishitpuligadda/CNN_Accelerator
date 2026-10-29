module vu_regs #(
    parameter LANES = 4
) (
    input                        clk,
    input                        rst_n,

    input      [2:0]             vra,
    input      [2:0]             vrb,
    output     [LANES*32-1:0]    vda,
    output     [LANES*32-1:0]    vdb,
    input      [LANES*32-1:0]    pkt_data,

    input                        vw0_en,
    input      [2:0]             vw0_idx,
    input      [LANES-1:0]       vw0_lanes,
    input      [LANES*32-1:0]    vw0_data,
    input                        vw1_en,
    input      [2:0]             vw1_idx,
    input      [LANES-1:0]       vw1_lanes,
    input      [LANES*32-1:0]    vw1_data,

    input      [3:0]             sra,
    input      [3:0]             srb,
    output     [31:0]            sda,
    output     [31:0]            sdb,
    input                        sw_en,
    input      [3:0]             sw_idx,
    input      [31:0]            sw_data,

    input                        q_we,
    input      [1:0]             q_widx,
    input      [15:0]            q_mpos,
    input      [15:0]            q_mneg,
    input      [5:0]             q_s,
    input      [1:0]             q_ridx,
    output     [15:0]            mpos,
    output     [15:0]            mneg,
    output     [5:0]             s,

    input                        c_we,
    input      [1:0]             c_widx,
    input      [31:0]            c_lo,
    input      [31:0]            c_hi,
    input      [1:0]             c_ridx,
    output     [31:0]            lo,
    output     [31:0]            hi
);
	reg  [LANES*32-1:0] vreg [0:6];
	reg  [31:0]         sreg [1:15];
	reg  [15:0]         q_mp [0:3];
	reg  [15:0]         q_mn [0:3];
	reg  [5:0]          q_sh [0:3];
	reg  [31:0]         c_l  [0:3];
	reg  [31:0]         c_h  [0:3];
	integer             r, k;

	reg  [LANES*32-1:0] va_r, vb_r;
	reg  [31:0]         sa_r, sb_r;
	integer             j;

	always @* begin
		va_r = (vra == 3'd7) ? pkt_data : vreg[vra];
		vb_r = (vrb == 3'd7) ? pkt_data : vreg[vrb];
		for (j = 0; j < LANES; j = j + 1) begin
			if (vra != 3'd7 && vw0_en && vw0_idx == vra && vw0_lanes[j]) va_r[j*32 +: 32] = vw0_data[j*32 +: 32];
			if (vra != 3'd7 && vw1_en && vw1_idx == vra && vw1_lanes[j]) va_r[j*32 +: 32] = vw1_data[j*32 +: 32];
			if (vrb != 3'd7 && vw0_en && vw0_idx == vrb && vw0_lanes[j]) vb_r[j*32 +: 32] = vw0_data[j*32 +: 32];
			if (vrb != 3'd7 && vw1_en && vw1_idx == vrb && vw1_lanes[j]) vb_r[j*32 +: 32] = vw1_data[j*32 +: 32];
		end
	end

	always @* begin
		sa_r = (sra == 4'd0) ? 32'd0 : sreg[sra];
		sb_r = (srb == 4'd0) ? 32'd0 : sreg[srb];
	end

	assign vda  = va_r;
	assign vdb  = vb_r;
	assign sda  = sa_r;
	assign sdb  = sb_r;
	assign mpos = q_mp[q_ridx];
	assign mneg = q_mn[q_ridx];
	assign s    = q_sh[q_ridx];
	assign lo   = c_l[c_ridx];
	assign hi   = c_h[c_ridx];

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			for (r = 0; r < 7; r = r + 1)  vreg[r] <= {(LANES*32){1'b0}};
			for (r = 1; r < 16; r = r + 1) sreg[r] <= 32'd0;
			for (r = 0; r < 4; r = r + 1) begin
				q_mp[r] <= 16'd0;
				q_mn[r] <= 16'd0;
				q_sh[r] <= 6'd0;
				c_l[r]  <= 32'h80000000;
				c_h[r]  <= 32'h7FFFFFFF;
			end
		end
		else begin
			for (r = 0; r < 7; r = r + 1)
				for (k = 0; k < LANES; k = k + 1) begin
					if (vw1_en && vw1_idx == r[2:0] && vw1_lanes[k])
						vreg[r][k*32 +: 32] <= vw1_data[k*32 +: 32];
					else if (vw0_en && vw0_idx == r[2:0] && vw0_lanes[k])
						vreg[r][k*32 +: 32] <= vw0_data[k*32 +: 32];
				end
			if (sw_en && sw_idx != 4'd0) sreg[sw_idx] <= sw_data;
			if (q_we) begin
				q_mp[q_widx] <= q_mpos;
				q_mn[q_widx] <= q_mneg;
				q_sh[q_widx] <= q_s;
			end
			if (c_we) begin
				c_l[c_widx] <= c_lo;
				c_h[c_widx] <= c_hi;
			end
		end
	end
endmodule
