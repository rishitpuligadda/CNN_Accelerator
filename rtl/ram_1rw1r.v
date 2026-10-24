`timescale 1ns/1ps

module ram_1rw1r #(
	parameter DEPTH = 1536
)(
`ifdef USE_POWER_PINS
	inout                       vccd1,
	inout                       vssd1,
`endif
	input                       clk,
	input                       en0,
	input                       we0,
	input  [3:0]                be0,
	input  [$clog2(DEPTH)-1:0]  addr0,
	input  [31:0]               wdata0,
	output [31:0]               rdata0,
	input                       en1,
	input  [$clog2(DEPTH)-1:0]  addr1,
	output [31:0]               rdata1
);
`ifndef SYNTHESIS
	initial begin
		if (DEPTH < 512 || DEPTH % 512 != 0) begin
			$display("ERROR: %m DEPTH = %0d, must be a multiple of 512", DEPTH);
			$finish;
		end
	end
`endif

`ifdef USE_SRAM_MACRO
	localparam AW    = $clog2(DEPTH);
	localparam MAW   = 9;
	localparam NBANK = DEPTH / 512;
	localparam BW    = AW - MAW;

	wire [NBANK*32-1:0] dout0_all, dout1_all;

	genvar b;
	generate
		for (b = 0; b < NBANK; b = b + 1) begin : BANK
			wire sel0, sel1;

			if (NBANK == 1) begin : ONE
				assign sel0 = 1'b1;
				assign sel1 = 1'b1;
			end
			else begin : MANY
				assign sel0 = (addr0[AW-1:MAW] == b);
				assign sel1 = (addr1[AW-1:MAW] == b);
			end

			sky130_sram_2kbyte_1rw1r_32x512_8
`ifndef SYNTHESIS
			#(.VERBOSE(0))
`endif
			u_mem (
`ifdef USE_POWER_PINS
				.vccd1(vccd1),
				.vssd1(vssd1),
`endif
				.clk0(clk),
				.csb0(~(en0 & sel0)),
				.web0(~we0),
				.wmask0(be0),
				.addr0(addr0[MAW-1:0]),
				.din0(wdata0),
				.dout0(dout0_all[b*32 +: 32]),
				.clk1(clk),
				.csb1(~(en1 & sel1)),
				.addr1(addr1[MAW-1:0]),
				.dout1(dout1_all[b*32 +: 32])
			);
		end

		if (NBANK == 1) begin : RD_ONE
			assign rdata0 = dout0_all;
			assign rdata1 = dout1_all;
		end
		else begin : RD_MANY
			reg [BW-1:0] bank0_q, bank1_q;

			always @(posedge clk) begin
				bank0_q <= addr0[AW-1:MAW];
				bank1_q <= addr1[AW-1:MAW];
			end

			assign rdata0 = dout0_all[bank0_q*32 +: 32];
			assign rdata1 = dout1_all[bank1_q*32 +: 32];
		end
	endgenerate

`else
	reg [31:0] mem [0:DEPTH-1];
	reg [31:0] rdata0_r, rdata1_r;
	integer    i;

	always @(posedge clk) begin
		if (en0 && we0)
			for (i = 0; i < 4; i = i + 1)
				if (be0[i]) mem[addr0][i*8 +: 8] <= wdata0[i*8 +: 8];

		if (en0 && !we0) rdata0_r <= mem[addr0];
		else             rdata0_r <= 32'bx;

		if (en1 && !(en0 && we0 && addr0 == addr1)) rdata1_r <= mem[addr1];
		else                                        rdata1_r <= 32'bx;
	end

	assign rdata0 = rdata0_r;
	assign rdata1 = rdata1_r;
`endif
endmodule
