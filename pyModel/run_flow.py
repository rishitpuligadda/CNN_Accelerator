"""Train -> quantize -> check the integer model -> compile -> files for the RTL test (tb_model.v).

    python3 run_flow.py [output_dir]          (default ../simulation/model)
"""
import os
import sys
import numpy as np
import model
import quant
import compile as cc


def main(outdir):
    os.makedirs(outdir, exist_ok=True)
    print("1) Training the float CNN on the 8x8 handwritten digits (scikit-learn):")
    params = model.train(epochs=60)
    xtr, ytr, xte, yte = model.load_digits_split()
    float_pred = model.forward(params, xte).argmax(axis=1)
    float_acc = (float_pred == yte).mean()

    print("\n2) Quantization (calibration on the training images):")
    q, table = quant.quantize(params, xtr)
    for li, (L, ql) in enumerate(zip(model.LAYERS, q)):
        print(f"   layer {li} ({L['kind']}, {L['cin']}->{L['cout']}, {L['k']}x{L['k']}): "
              f"weight scale {ql['s_w']:.5f}, output scale {ql['s_out']:.5f}, "
              f"requantization {ql['s_in'] * ql['s_w'] / ql['s_out']:.6f} ~ M {ql['M']} / 2^{ql['S']}, "
              f"bias range {ql['bq'].min()}..{ql['bq'].max()}")
    print(f"   exp table: one logit step = {q[-1]['s_out']:.4f}; table[0] = {table[0]}, table[-1] = {table[255]}, "
          f"table[-20] = {table[256 - 20]}")

    print("\n3) The integer model (bit-exact with the chip) on the 360 test images:")
    xte_q = quant.input_int8(xte)
    golden = [quant.golden(q, table, xte_q[i]) for i in range(len(xte_q))]
    int_pred = np.array([int(np.argmax(g[1])) for g in golden])
    int_acc = (int_pred == yte).mean()
    agree = (int_pred == float_pred).mean()
    print(f"   float accuracy {float_acc * 100:.2f}%,  integer (chip) accuracy {int_acc * 100:.2f}%,  "
          f"same prediction as float on {agree * 100:.1f}% of the images")

    print("\n4) Compiling for the chip:")
    mem, entries = cc.compile_network(q, table)
    for li, e in enumerate(entries):
        print(f"   layer {li}: table entry at {e['addr']} ({e['words']} words, program {e['prog']} instructions), "
              f"weights at {e['wgt']} ({e['wgt_words']} words), input {e['in_hw'][0]}x{e['in_hw'][1]} -> "
              f"stored {e['out'][0]}x{e['out'][1]}x{e['out'][2]}")
    cc.write_hex_mem(os.path.join(outdir, "model_mem.hex"), mem)
    with open(os.path.join(outdir, "images.hex"), "w") as f:
        for i in range(len(xte_q)):
            for w in cc.image_words(xte_q[i]):
                f.write(f"{w:08x}\n")
    with open(os.path.join(outdir, "expected.hex"), "w") as f:
        for i, (maps, probs) in enumerate(golden):
            for p in probs:
                f.write(f"{int(p) & 0xFF:08x}\n")
            f.write(f"{int(yte[i]):08x}\n{int(int_pred[i]):08x}\n")
    with open(os.path.join(outdir, "expmaps.hex"), "w") as f:
        for maps, probs in golden:
            for li, mp in enumerate(maps):
                if model.LAYERS[li]["kind"] == "fc":
                    vals = probs                         # the last layer stores probabilities
                else:
                    vals = mp.reshape(-1)
                for v in vals:
                    f.write(f"{int(v) & 0xFF:02x}\n")
    # the network's shape for the testbench
    with open(os.path.join(outdir, "model_params.vh"), "w") as f:
        f.write("// written by run_flow.py\n")
        f.write(f"localparam NIMG = {len(xte_q)};\nlocalparam IMG_WORDS = {len(cc.image_words(xte_q[0]))};\n")
        f.write(f"localparam NL = {len(entries)};\nlocalparam NCLASS = {model.LAYERS[-1]['cout']};\n")
        f.write(f"localparam FLOAT_ACC_X10000 = {int(round(float_acc * 10000))};\n")
        f.write(f"localparam INT_ACC_X10000 = {int(round(int_acc * 10000))};\n")
        for name, idx in (("lay_c", 2), ("lay_h", 0), ("lay_w", 1), ("lay_mode", 3)):
            f.write(f"function integer {name}(input integer l);\n\tcase (l)\n")
            for li, e in enumerate(entries):
                v = e["mode"] if idx == 3 else e["out"][idx]
                f.write(f"\t\t{li}: {name} = {v};\n")
            f.write(f"\t\tdefault: {name} = 0;\n\tendcase\nendfunction\n")
    with open(os.path.join(outdir, "model_info.txt"), "w") as f:
        f.write(f"images {len(xte_q)}\nimg_words {len(cc.image_words(xte_q[0]))}\n"
                f"float_accuracy {float_acc:.4f}\ninteger_accuracy {int_acc:.4f}\n")
    print(f"   wrote model_mem.hex ({len(mem)} words), images.hex, expected.hex, expmaps.hex to {outdir}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "../simulation/model")
