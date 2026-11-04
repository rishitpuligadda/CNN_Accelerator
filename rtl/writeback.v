module writeback #(
    parameter EAW  = 16,
    parameter ADDR = 11
) (
    input                      clk,
    input                      rst_n,

    input                      start,
    input      [ADDR-1:0]      src,
    input      [ADDR:0]        nwords,
    input      [EAW-1:0]       ext_base,
    output reg                 done,
    output                     busy,

    // output feature buffer read port
    output                     buf_en,
    output     [ADDR-1:0]      buf_addr,
    input      [31:0]          buf_rdata,

    // external memory write channel
    output                     wr_req_valid,
    input                      wr_req_ready,
    output     [EAW-1:0]       wr_req_addr,
    output     [31:0]          wr_req_data
);
	localparam S_IDLE = 2'd0;
	localparam S_RD   = 2'd1;
	localparam S_CAP  = 2'd2;
	localparam S_WR   = 2'd3;

	reg  [1:0]       state;
	reg  [ADDR:0]    i;
	reg  [31:0]      data_q;

	assign busy         = (state != S_IDLE);
	assign buf_en       = (state == S_RD);
	assign buf_addr     = src + i[ADDR-1:0];
	assign wr_req_valid = (state == S_WR);
	assign wr_req_addr  = ext_base + {{(EAW-ADDR-1){1'b0}}, i};
	assign wr_req_data  = data_q;

	// One word at a time: read the buffer (the address is taken at the end of S_RD), capture the data at the
	// end of the next cycle (S_CAP; valid there for both the behavioral RAM and the sky130 macro), then write it.
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			state  <= S_IDLE;
			i      <= {(ADDR+1){1'b0}};
			data_q <= 32'd0;
			done   <= 1'b0;
		end
		else begin
			done <= 1'b0;
			case (state)
				S_IDLE: begin
					i <= {(ADDR+1){1'b0}};
					if (start) begin
						if (nwords == 0) done  <= 1'b1;
						else             state <= S_RD;
					end
				end
				S_RD:  state <= S_CAP;
				S_CAP: begin
					data_q <= buf_rdata;
					state  <= S_WR;
				end
				S_WR: begin
					if (wr_req_ready) begin
						if (i + 1'b1 == nwords) begin
							done  <= 1'b1;
							state <= S_IDLE;
						end
						else begin
							i     <= i + 1'b1;
							state <= S_RD;
						end
					end
				end
			endcase
		end
	end
endmodule
