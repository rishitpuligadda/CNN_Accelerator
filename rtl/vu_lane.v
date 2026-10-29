module vu_lane (
    input                    clk,
    input                    rst_n,
    input       [3:0]        lop,
    input                    issue,
    input  signed [31:0]     a,
    input  signed [31:0]     b,
    input       [4:0]        sh,
    input  signed [15:0]     mpos,
    input  signed [15:0]     mneg,
    input       [5:0]        s,
    input  signed [31:0]     lo,
    input  signed [31:0]     hi,
    output reg signed [31:0] r1,
    output reg               v1,
    output reg signed [31:0] r2,
    output reg               v2
);
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

	wire                slow = (lop == L_MUL) || (lop == L_REQ);

	wire signed [31:0]  lifted  = (a > lo) ? a : lo;
	wire signed [31:0]  clamped = (lifted < hi) ? lifted : hi;
	wire signed [31:0]  sat8    = (clamped < -32'sd128) ? -32'sd128 :
	                              ((clamped > 32'sd127) ? 32'sd127 : clamped);
	wire signed [31:0]  shr     = a >>> sh;
	wire                rbit    = (sh == 5'd0) ? 1'b0 : a[sh - 5'd1];

	reg  signed [31:0]  fast;

	always @* begin
		case (lop)
			L_ADD:    fast = a + b;
			L_SUB:    fast = a - b;
			L_MAX:    fast = (a > b) ? a : b;
			L_MIN:    fast = (a < b) ? a : b;
			L_SHL:    fast = a <<< sh;
			L_SHR:    fast = shr;
			L_SHRR:   fast = shr + {31'd0, rbit};
			L_CLAMP:  fast = clamped;
			L_CLAMP8: fast = sat8;
			L_PASS:   fast = a;
			default:  fast = a;
		endcase
	end

	wire signed [15:0]  msel = (lop == L_REQ) ? ((a < 0) ? mneg : mpos) : b[15:0];
	wire signed [47:0]  prod = a * msel;

	reg  signed [47:0]  p_q;
	reg         [5:0]   s_q;
	reg                 req_q, slow_q;

	wire signed [47:0]  pshr  = p_q >>> s_q;
	wire                prbit = (s_q == 6'd0) ? 1'b0 : p_q[s_q - 6'd1];
	wire signed [47:0]  rnd   = (s_q == 6'd0) ? p_q : pshr + {47'd0, prbit};
	wire signed [31:0]  rsat  = (rnd > 48'sh00007FFFFFFF)  ? 32'sh7FFFFFFF :
	                            ((rnd < -48'sh000080000000) ? 32'sh80000000 : rnd[31:0]);

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			r1     <= 32'sd0;
			v1     <= 1'b0;
			p_q    <= 48'sd0;
			s_q    <= 6'd0;
			req_q  <= 1'b0;
			slow_q <= 1'b0;
			r2     <= 32'sd0;
			v2     <= 1'b0;
		end
		else begin
			v1     <= issue && !slow;
			if (issue && !slow) r1 <= fast;

			slow_q <= issue && slow;
			if (issue && slow) begin
				p_q   <= prod;
				s_q   <= s;
				req_q <= (lop == L_REQ);
			end

			v2 <= slow_q;
			if (slow_q) r2 <= req_q ? rsat : p_q[31:0];
		end
	end
endmodule
