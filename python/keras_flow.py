"""From an exported Keras model (keras_export.py) to the chip.

    python3 keras_flow.py mnist_cnn_export.npz mnist.npz [output_dir] [n_rtl]

1. converts the Keras layers into chip layers and checks every chip limit (with a readable reason)
2. verifies the conversion: the converted network must reproduce Keras's own predictions
3. calibrates on MNIST training images, quantizes to int8
4. measures float and int8 (bit-exact chip model) accuracy on all MNIST test images
5. compiles the layer table, weights and the first n_rtl test images for tb_model.v

Supported Keras layers: Conv2D (relu/linear, valid or symmetric same padding, stride 1..4), MaxPooling2D 2x2
(fused into the conv before it), BatchNormalization right after a linear conv/dense (folded into it),
Flatten, Dense (relu/linear; softmax on the last one), Dropout (ignored), Activation/ReLU/Softmax layers.
"""
import json
import sys
import numpy as np
import chipnet
from compile import report_and_write


class Unsupported(ValueError):
    pass


def _act(a, where):
    if a in (None, "linear"):
        return "linear"
    if a in ("relu", "softmax"):
        return a
    raise Unsupported(f"{where}: activation '{a}' is not supported (relu, linear, and softmax at the end)")


def keras_same_pad(size, k, s, where):
    """Keras 'same': output ceil(size/s), extra padding goes to the bottom/right. The chip pads symmetrically,
    so this only works when the top/left padding p reproduces the same output size."""
    out = -(-size // s)
    total = max((out - 1) * s + k - size, 0)
    p = total // 2
    if (size + 2 * p - k) // s + 1 != out:
        raise Unsupported(f"{where}: 'same' padding with stride {s} and kernel {k} on size {size} is asymmetric "
                          f"in Keras; the chip pads symmetrically (use 'valid' padding or an odd input size)")
    return p


def convert(export):
    meta = json.loads(str(export["meta"]))
    in_h, in_w, in_c = meta["input_shape"]
    h, w, c = in_h, in_w, in_c
    layers, params = [], []
    flat = False
    for i, ent in enumerate(meta["layers"]):
        cls, cfg = ent["class"], ent["config"]
        wts = [export[f"w{i}_{j}"] for j in range(ent["n_weights"])]
        where = f"Keras layer {i} ({cls})"
        if cls in ("InputLayer", "Dropout"):
            continue
        if cfg.get("data_format", "channels_last") != "channels_last":
            raise Unsupported(f"{where}: only channels_last models")
        if cls == "Conv2D":
            if flat:
                raise Unsupported(f"{where}: a convolution after Flatten")
            if tuple(cfg.get("dilation_rate", (1, 1))) != (1, 1) or cfg.get("groups", 1) != 1:
                raise Unsupported(f"{where}: dilated or grouped convolutions are not supported")
            kh, kw = cfg["kernel_size"]
            sh_, sw_ = cfg["strides"]
            if sh_ != sw_:
                raise Unsupported(f"{where}: different strides for rows and columns")
            if cfg["padding"] == "valid":
                pad = 0
            else:
                ph, pw = keras_same_pad(h, kh, sh_, where), keras_same_pad(w, kw, sw_, where)
                if ph != pw:
                    raise Unsupported(f"{where}: 'same' padding differs for rows ({ph}) and columns ({pw})")
                pad = ph
            kern = wts[0].transpose(3, 2, 0, 1)                 # (kh, kw, cin, cout) -> (cout, cin, kh, kw)
            bias = wts[1] if cfg.get("use_bias", True) else np.zeros(kern.shape[0], np.float32)
            a = _act(cfg.get("activation"), where)
            layers.append(dict(kind="conv", cin=c, cout=kern.shape[0], kh=kh, kw=kw, stride=sh_, pad=pad,
                               relu=(a == "relu"), pool=0, softmax=(a == "softmax"), _act=a))
            params.append([kern.astype(np.float64), bias.astype(np.float64)])
            h = (h + 2 * pad - kh) // sh_ + 1
            w = (w + 2 * pad - kw) // sw_ + 1
            c = kern.shape[0]
        elif cls == "MaxPooling2D":
            ps = tuple(cfg["pool_size"])
            st = tuple(cfg["strides"]) if cfg.get("strides") else ps
            if ps != (2, 2) or st != (2, 2) or cfg.get("padding", "valid") != "valid":
                raise Unsupported(f"{where}: only 2x2 max pooling with stride 2 and 'valid' padding")
            if not layers or layers[-1]["kind"] != "conv" or layers[-1]["pool"]:
                raise Unsupported(f"{where}: pooling must follow a convolution directly (it is fused into it)")
            layers[-1]["pool"] = 1
            h, w = h // 2, w // 2
        elif cls == "BatchNormalization":
            if not layers or layers[-1]["_act"] != "linear" or layers[-1]["pool"]:
                raise Unsupported(f"{where}: BatchNormalization can only be folded right after a linear conv/dense "
                                  f"(put the activation after it)")
            gamma, beta, mean, var = wts
            k = gamma / np.sqrt(var + cfg.get("epsilon", 1e-3))
            params[-1][0] = params[-1][0] * k[:, None, None, None]
            params[-1][1] = (params[-1][1] - mean) * k + beta
        elif cls in ("Activation", "ReLU", "Softmax"):
            a = "relu" if cls == "ReLU" else ("softmax" if cls == "Softmax" else _act(cfg.get("activation"), where))
            if not layers or layers[-1]["_act"] != "linear" or layers[-1]["pool"]:
                raise Unsupported(f"{where}: an activation must follow a linear conv/dense directly")
            layers[-1]["_act"] = a
            layers[-1]["relu"] = (a == "relu")
            layers[-1]["softmax"] = (a == "softmax")
        elif cls == "Flatten":
            flat = True
        elif cls == "Dense":
            if not flat and (h, w) != (1, 1):
                raise Unsupported(f"{where}: Dense on a {h}x{w} map without Flatten")
            units = wts[0].shape[1]
            kern = wts[0].reshape(h, w, c, units).transpose(3, 2, 0, 1)   # Keras flattens (row, col, channel)
            bias = wts[1] if cfg.get("use_bias", True) else np.zeros(units, np.float32)
            a = _act(cfg.get("activation"), where)
            layers.append(dict(kind="fc", cin=c, cout=units, kh=h, kw=w, stride=1, pad=0,
                               relu=(a == "relu"), pool=0, softmax=(a == "softmax"), _act=a))
            params.append([kern.astype(np.float64), bias.astype(np.float64)])
            h, w, c = 1, 1, units
        else:
            raise Unsupported(f"{where}: this layer type is not supported by the chip flow yet")
    for L in layers[:-1]:
        if L["softmax"]:
            raise Unsupported("softmax is only supported on the last layer")
    return layers, params, (in_c, in_h, in_w), meta.get("input_scale", 255.0)


# ---------------------------------------------------------------- Keras semantics, independently (NHWC)
def keras_reference(meta, export, x):
    """Runs the exported model the way Keras defines it (channels last, asymmetric 'same' padding,
    (row, col, channel) flatten) - an independent check of the conversion."""
    for i, ent in enumerate(meta["layers"]):
        cls, cfg = ent["class"], ent["config"]
        wts = [export[f"w{i}_{j}"].astype(np.float64) for j in range(ent["n_weights"])]
        if cls == "Conv2D":
            kh, kw = cfg["kernel_size"]
            s = cfg["strides"][0]
            n, H, W, C = x.shape
            if cfg["padding"] == "same":
                oh, ow = -(-H // s), -(-W // s)
                th, tw = max((oh - 1) * s + kh - H, 0), max((ow - 1) * s + kw - W, 0)
                x = np.pad(x, ((0, 0), (th // 2, th - th // 2), (tw // 2, tw - tw // 2), (0, 0)))
            else:
                oh, ow = (H - kh) // s + 1, (W - kw) // s + 1
            y = np.zeros((n, oh, ow, wts[0].shape[3]))
            for a in range(kh):
                for b in range(kw):
                    y += np.einsum("nhwc,cf->nhwf", x[:, a:a + s * oh:s, b:b + s * ow:s, :], wts[0][a, b])
            if cfg.get("use_bias", True):
                y += wts[1]
            x = y
        elif cls == "MaxPooling2D":
            n, H, W, C = x.shape
            x = x[:, :H // 2 * 2, :W // 2 * 2].reshape(n, H // 2, 2, W // 2, 2, C).max(axis=(2, 4))
        elif cls == "BatchNormalization":
            g, be, mu, var = wts
            x = (x - mu) / np.sqrt(var + cfg.get("epsilon", 1e-3)) * g + be
        elif cls == "Flatten":
            x = x.reshape(x.shape[0], -1)
        elif cls == "Dense":
            x = x.reshape(x.shape[0], -1) @ wts[0] + (wts[1] if cfg.get("use_bias", True) else 0)
        a = cfg.get("activation") if cls in ("Conv2D", "Dense", "Activation") else \
            ("relu" if cls == "ReLU" else ("softmax" if cls == "Softmax" else None))
        if a == "relu":
            x = np.maximum(x, 0)
        elif a == "softmax":
            e = np.exp(x - x.max(axis=-1, keepdims=True))
            x = e / e.sum(axis=-1, keepdims=True)
    return x


def softmax(z):
    e = np.exp(z - z.max(axis=1, keepdims=True))
    return e / e.sum(axis=1, keepdims=True)


def main(export_path, mnist_path, outdir="../simulation/model", n_rtl=100, n_cal=1000):
    export = np.load(export_path, allow_pickle=True)
    meta = json.loads(str(export["meta"]))
    print("1) Converting the Keras model to chip layers:")
    try:
        layers, params, (in_c, in_h, in_w), in_div = convert(export)
        chipnet.check_limits(layers, in_c, in_h, in_w)
    except ValueError as e:
        sys.exit(f"   the model cannot run on the chip as it is: {e}")
    h, w = in_h, in_w
    for li, L in enumerate(layers):
        oh, ow, sh, sw = chipnet.out_shape(L, h, w)
        print(f"   chip layer {li}: {L['kind']} {h}x{w}x{L['cin']} -> {L['cout']} filters {L['kh']}x{L['kw']}, "
              f"stride {L['stride']}, pad {L['pad']}{', ReLU' if L['relu'] else ''}"
              f"{', 2x2 max pool' if L['pool'] else ''}{', softmax' if L['softmax'] else ''} -> stored "
              f"{sh}x{sw}x{L['cout']} ({chipnet.map_words(L['cout'], sh, sw)} of {chipnet.BUF_WORDS} words)")
        h, w = sh, sw

    with np.load(mnist_path, allow_pickle=True) as f:
        xtr, ytr, xte, yte = f["x_train"], f["y_train"], f["x_test"], f["y_test"]
    to_nchw = lambda a: a.reshape(len(a), in_h, in_w, in_c).transpose(0, 3, 1, 2).astype(np.float64) / in_div
    xtr_c, xte_c = to_nchw(xtr[:n_cal]), to_nchw(xte)

    print("\n   checking the conversion against Keras's own predictions:")
    kp = export["keras_preds"]
    m = len(kp)
    ref = keras_reference(meta, export, xte[:m].reshape(m, in_h, in_w, in_c).astype(np.float64) / in_div)
    ours, _ = chipnet.float_forward(layers, params, xte_c[:m])
    ours_p = softmax(ours) if layers[-1]["softmax"] else ours
    d_ref, d_ours = np.abs(ref - kp).max(), np.abs(ours_p - kp).max()
    same = (ours_p.argmax(1) == kp.argmax(1)).mean()
    print(f"   largest difference from Keras: reference {d_ref:.2e}, converted chip network {d_ours:.2e}; "
          f"same class on {same * 100:.1f}% of {m} images")
    if d_ours > 1e-3 or same < 1.0:
        sys.exit("   the converted network does not reproduce Keras - please send me this output")

    logits, _ = chipnet.float_forward(layers, params, xte_c)
    report_and_write(layers, params, xtr_c, xte_c, yte, outdir, logits, in_scale=127.0, n_rtl=n_rtl)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit("usage: python3 keras_flow.py <export.npz> <mnist.npz> [output_dir] [n_rtl]")
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "../simulation/model",
         int(sys.argv[4]) if len(sys.argv) > 4 else 100)
