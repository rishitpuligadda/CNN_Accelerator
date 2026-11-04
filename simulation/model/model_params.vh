// written by the Python flow (compile.write_files)
localparam NIMG = 1000;
localparam IMG_WORDS = 197;
localparam IMG_C = 1;
localparam IMG_H = 28;
localparam IMG_W = 28;
localparam NL = 5;
localparam NCLASS = 10;
localparam MAP_BYTES = 6306;
localparam SOFTMAX = 1;
localparam FLOAT_ACC_X10000 = 9005;
localparam INT_ACC_X10000 = 9003;
function integer lay_c(input integer l);
	case (l)
		0: lay_c = 24;
		1: lay_c = 64;
		2: lay_c = 64;
		3: lay_c = 64;
		4: lay_c = 10;
		default: lay_c = 0;
	endcase
endfunction
function integer lay_h(input integer l);
	case (l)
		0: lay_h = 13;
		1: lay_h = 5;
		2: lay_h = 3;
		3: lay_h = 1;
		4: lay_h = 1;
		default: lay_h = 0;
	endcase
endfunction
function integer lay_w(input integer l);
	case (l)
		0: lay_w = 13;
		1: lay_w = 5;
		2: lay_w = 3;
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
