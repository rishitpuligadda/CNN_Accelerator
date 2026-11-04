// written by run_flow.py
localparam NIMG = 360;
localparam IMG_WORDS = 17;
localparam NL = 3;
localparam NCLASS = 10;
localparam FLOAT_ACC_X10000 = 9833;
localparam INT_ACC_X10000 = 9833;
function integer lay_c(input integer l);
	case (l)
		0: lay_c = 8;
		1: lay_c = 16;
		2: lay_c = 10;
		default: lay_c = 0;
	endcase
endfunction
function integer lay_h(input integer l);
	case (l)
		0: lay_h = 4;
		1: lay_h = 2;
		2: lay_h = 1;
		default: lay_h = 0;
	endcase
endfunction
function integer lay_w(input integer l);
	case (l)
		0: lay_w = 4;
		1: lay_w = 2;
		2: lay_w = 1;
		default: lay_w = 0;
	endcase
endfunction
function integer lay_mode(input integer l);
	case (l)
		0: lay_mode = 2;
		1: lay_mode = 2;
		2: lay_mode = 4;
		default: lay_mode = 0;
	endcase
endfunction
