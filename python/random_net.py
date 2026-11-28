"""Random networks for testing the chip: random shapes and weights (no training), compiled and written for
tb_model.v exactly like a trained model, so check_results.py compares every layer of the RTL with the golden model.

    python3 random_net.py <seed> [output_dir] [n_images]        (default ../simulation/model, 3 images)

Seeds 0..9 are fixed networks that cover the features in turn (maps much larger than a feature buffer, split
into bands; 11x11 kernels; padding up to 5; strides 1-4; pooling; FC + softmax); other seeds pick everything
at random. The images are random too, so only "chip == golden model" means anything here, not accuracy.
"""
import sys
import numpy as np
import chipnet
from compile import report_and_write


def L(kind, cin, cout, k, stride=1, pad=0, relu=True, pool=False, softmax=False, kw=None):
    return dict(kind=kind, cin=cin, cout=cout, kh=k, kw=k if kw is None else kw, stride=stride, pad=pad,
                relu=relu, pool=1 if pool else 0, softmax=softmax)


# (input c, h, w), layers
FIXED = {
    # a 64x64 colour image: the first two layers' maps do not fit a 6 KB buffer -> bands
    0: ((3, 64, 64), [L("conv", 3, 16, 3, pad=1, pool=True), L("conv", 16, 24, 3, pad=1, pool=True),
                      L("conv", 24, 20, 3, pool=True), L("fc", 20, 10, 7, relu=False, softmax=True)]),
    # 11x11 kernels with 'same' padding 5, stride 2, on a tall image (300 rows: more than 255, bands only)
    1: ((1, 300, 40), [L("conv", 1, 8, 11, stride=2, pad=5), L("conv", 8, 8, 11, pad=5, pool=True),
                       L("conv", 8, 12, 3, stride=3)]),
    # stride 4 with an 11x11 kernel (AlexNet-style first layer), then pooling and small layers
    2: ((3, 99, 99), [L("conv", 3, 12, 11, stride=4, pad=2, pool=True), L("conv", 12, 16, 5, pad=2),
                      L("conv", 16, 20, 3, pool=True), L("fc", 20, 7, 5, relu=False, softmax=True)]),
    # non-square kernels, padding 3 with stride 1 (bands whose top padding is neither 0 nor the full pad)
    3: ((2, 120, 60), [L("conv", 2, 6, 7, kw=5, pad=3), L("conv", 6, 10, 9, kw=3, stride=2, pad=1, pool=True),
                       L("conv", 10, 4, 1)]),
    # a band layer followed by on-chip layers, then a linear (no ReLU) output and no softmax
    4: ((4, 48, 100), [L("conv", 4, 12, 3, pad=1), L("conv", 12, 8, 3, stride=2, pool=True),
                       L("conv", 8, 8, 3, pad=1), L("conv", 8, 5, 3, relu=False)]),
    # pooling with an odd number of conv rows in every band boundary case, many channels, narrow map
    5: ((16, 97, 21), [L("conv", 16, 32, 3, pool=True), L("conv", 32, 48, 3, pad=1, pool=True),
                       L("conv", 48, 10, 3, relu=False)]),
    # 1x1 and 2x2 kernels on a big map, stride 2 without padding
    6: ((8, 70, 90), [L("conv", 8, 16, 1), L("conv", 16, 16, 2, stride=2), L("conv", 16, 6, 3, stride=2, pad=1)]),
    # the largest FC input: an 11x11 map before Flatten
    7: ((1, 46, 46), [L("conv", 1, 8, 5, pool=True), L("conv", 8, 8, 11, kw=11, pad=5),
                      L("conv", 8, 8, 3, stride=2),
                      L("fc", 8, 12, 10, relu=False, softmax=True)]),
    # everything fits on chip (the ping-pong path) next to an 11x11 kernel
    8: ((1, 28, 28), [L("conv", 1, 8, 11, pad=5, pool=True), L("conv", 8, 16, 3, pool=True),
                      L("fc", 16, 10, 6, relu=False, softmax=True)]),
    # a wide map (255 columns) with pooling: many narrow bands
    9: ((2, 40, 255), [L("conv", 2, 4, 3, pad=1), L("conv", 4, 4, 3, stride=2, pad=1, pool=True)]),
}


def random_net(rng):
    for _ in range(1000):
        c = int(rng.choice([1, 2, 3, 4, 8]))
        h, w = int(rng.integers(16, 160)), int(rng.integers(16, 200))
        layers, ch, hh, ww = [], c, h, w
        for i in range(int(rng.integers(1, 5))):
            k = int(rng.choice([1, 2, 3, 3, 5, 7, 9, 11]))
            kw = k if rng.random() < 0.8 else int(rng.integers(1, 12))
            s = int(rng.choice([1, 1, 1, 2, 2, 3, 4]))
            p = int(rng.integers(0, min(k, kw, 6)))
            f = int(rng.choice([4, 6, 8, 12, 16, 24]))
            pool = rng.random() < 0.4
            Ln = L("conv", ch, f, k, kw=kw, stride=s, pad=p, pool=pool, relu=rng.random() < 0.8)
            try:
                oh, ow, sh, sw = chipnet.out_shape(Ln, hh, ww)
            except Exception:
                break
            if oh < (2 if pool else 1) or ow < (2 if pool else 1) or ch * k * kw > 1020:
                break
            layers.append(Ln)
            ch, hh, ww = f, sh, sw
        if not layers:
            continue
        if hh <= 11 and ww <= 11 and ch * hh * ww <= 1020 and rng.random() < 0.6:
            layers.append(dict(kind="fc", cin=ch, cout=int(rng.integers(2, 20)), kh=hh, kw=ww, stride=1, pad=0,
                               relu=False, pool=0, softmax=True))
        try:
            chipnet.check_limits(layers, c, h, w)
        except ValueError:
            continue
        return (c, h, w), layers
    raise RuntimeError("no valid random network found")


def main(seed, outdir, n_img):
    rng = np.random.default_rng(seed)
    (c, h, w), layers = FIXED[seed] if seed in FIXED else random_net(rng)
    bands, _ = chipnet.check_limits(layers, c, h, w)
    print(f"random network {seed}: input {h}x{w}x{c}")
    hh, ww = h, w
    for i, Ln in enumerate(layers):
        oh, ow, sh, sw = chipnet.out_shape(Ln, hh, ww)
        print(f"   layer {i}: {Ln['kind']} {Ln['cin']}->{Ln['cout']} {Ln['kh']}x{Ln['kw']}, stride {Ln['stride']}, "
              f"pad {Ln['pad']}{', ReLU' if Ln['relu'] else ''}{', 2x2 pool' if Ln['pool'] else ''}"
              f"{', softmax' if Ln['softmax'] else ''} -> {sh}x{sw}x{Ln['cout']}"
              f"{f'  (bands of {bands[i]} rows)' if bands[i] else '  (on chip)'}")
        hh, ww = sh, sw
    params = []
    for Ln in layers:
        fan = Ln["cin"] * Ln["kh"] * Ln["kw"]
        params.append([rng.normal(0, 1.0 / np.sqrt(fan), (Ln["cout"], Ln["cin"], Ln["kh"], Ln["kw"])),
                       rng.normal(0, 0.1, Ln["cout"])])
    xtr = rng.random((4, c, h, w))
    xte = rng.random((n_img, c, h, w))
    yte = -np.ones(n_img, dtype=np.int64)
    logits, _ = chipnet.float_forward(layers, params, xte)
    report_and_write(layers, params, xtr, xte, yte, outdir, logits)


if __name__ == "__main__":
    main(int(sys.argv[1]), sys.argv[2] if len(sys.argv) > 2 else "../simulation/model",
         int(sys.argv[3]) if len(sys.argv) > 3 else 3)
