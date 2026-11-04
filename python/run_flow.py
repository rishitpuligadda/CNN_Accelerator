"""8x8 digits (scikit-learn, model in digits_model.py): train in numpy -> quantize -> golden check -> compile -> files for tb_model.v

    python3 run_flow.py [output_dir]          (default ../simulation/model)
"""
import sys
import numpy as np
import digits_model as model
import chipnet
from compile import report_and_write


def layers_from_model():
    out = []
    for L in model.LAYERS:
        out.append(dict(kind=L["kind"], cin=L["cin"], cout=L["cout"], kh=L["k"], kw=L["k"], stride=1, pad=L["pad"],
                        relu=L["relu"], pool=1 if L["pool"] else 0, softmax=(L["kind"] == "fc")))
    return out


def main(outdir):
    print("1) Training the float CNN on the 8x8 handwritten digits (scikit-learn):")
    params = model.train(epochs=60)
    xtr, ytr, xte, yte = model.load_digits_split()
    layers = layers_from_model()
    logits, _ = chipnet.float_forward(layers, params, xte)
    report_and_write(layers, params, xtr, xte, yte, outdir, logits)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "../simulation/model")
