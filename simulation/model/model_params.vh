// written by the Python flow (compile.write_files)
localparam NIMG = 10;
localparam IMG_WORDS = 769;
localparam IMG_C = 3;
localparam IMG_H = 32;
localparam IMG_W = 32;
localparam NL = 5;
localparam NCLASS = 10;
localparam MAP_BYTES = 8098;
localparam SOFTMAX = 1;
localparam FLOAT_ACC_X10000 = 6944;
localparam INT_ACC_X10000 = 6945;
function integer lay_c(input integer l);
	case (l)
		0: lay_c = 24;
		1: lay_c = 48;
		2: lay_c = 56;
		3: lay_c = 64;
		4: lay_c = 10;
		default: lay_c = 0;
	endcase
endfunction
function integer lay_h(input integer l);
	case (l)
		0: lay_h = 15;
		1: lay_h = 6;
		2: lay_h = 4;
		3: lay_h = 1;
		4: lay_h = 1;
		default: lay_h = 0;
	endcase
endfunction
function integer lay_w(input integer l);
	case (l)
		0: lay_w = 15;
		1: lay_w = 6;
		2: lay_w = 4;
		3: lay_w = 1;
		4: lay_w = 1;
		default: lay_w = 0;
	endcase
endfunction
function integer lay_mode(input integer l);
	case (l)
		0: lay_mode = 2;
		1: lay_mode = 2;
		2: lay_mode = 1;
		3: lay_mode = 1;
		4: lay_mode = 4;
		default: lay_mode = 0;
	endcase
endfunction
