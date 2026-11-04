"""A network as the chip runs it, independent of where it came from (numpy training, Keras, ...).

A network is a list of layers (dicts):
    kind     "conv" or "fc" (an FC layer is a conv whose kernel covers the whole input map)
    cin, cout, kh, kw, stride, pad
    relu     True: ReLU after requantization (M_neg = 0); False: linear
    pool     0 none, 1 = 2x2 max pooling (fused into the layer by the vector unit)
    softmax  True only for the last layer: softmax over the classes (1x1 output)
and per layer float parameters (w with shape (cout, cin, kh, kw), b with shape (cout,)).

All integer arithmetic mirrors the chip (spec vector_isa.md):
  REQ:   y = acc * (acc < 0 ? M_neg : M);  y = (y >> S) + ((y >> (S-1)) & 1) if S > 0;  saturate to int32
  store: saturate to int8;  pool: 2x2 max of the stored int8 values (floor for odd sizes)
  softmax: d = clamp(logit - max, -128, 0); e = table[d & 255]; R = floor(2^30 / sum e);
           q = SHRR(low32(R * e), 23) clamped to 0..127  (probability x 128)
"""
import numpy as np


# ---------------------------------------------------------------- shapes
def out_shape(L, h, w):
    oh = (h + 2 * L["pad"] - L["kh"]) // L["stride"] + 1
    ow = (w + 2 * L["pad"] - L["kw"]) // L["stride"] + 1
    sh, sw = (oh // 2, ow // 2) if L["pool"] else (oh, ow)
    return oh, ow, sh, sw


def map_words(c, h, w):
    """Words a C x H x W int8 map takes in a feature buffer: guard word, planar, rows padded to 4 bytes."""
    return 1 + c * h * ((w + 3) // 4)


BUF_WORDS = 1536


def check_limits(layers, in_c, in_h, in_w):
    """Raise ValueError with a readable reason for the first rule a layer breaks."""
    h, w, c = in_h, in_w, in_c
    if map_words(c, h, w) > BUF_WORDS:
        raise ValueError(f"input image {h}x{w}x{c} needs {map_words(c, h, w)} words, a feature buffer holds {BUF_WORDS}")
    for i, L in enumerate(layers):
        name = f"layer {i} ({L['kind']} {L['cin']}->{L['cout']}, {L['kh']}x{L['kw']}, stride {L['stride']}, pad {L['pad']})"
        if L["cin"] != c:
            raise ValueError(f"{name}: expects {L['cin']} input channels, gets {c}")
        if not (1 <= L["kh"] <= 7 and 1 <= L["kw"] <= 7):
            raise ValueError(f"{name}: kernels are at most 7x7 (an FC layer's input map must be at most 7x7)")
        if not 1 <= L["stride"] <= 4:
            raise ValueError(f"{name}: stride must be 1..4")
        if not (0 <= L["pad"] <= 3 and L["pad"] < min(L["kh"], L["kw"])):
            raise ValueError(f"{name}: padding must be 0..3 and smaller than the kernel")
        if L["cin"] * L["kh"] * L["kw"] > 1020:
            raise ValueError(f"{name}: channels x kernel = {L['cin'] * L['kh'] * L['kw']} weights per filter, at most 1020")
        if L["cout"] > 255:
            raise ValueError(f"{name}: at most 255 filters")
        if h + 2 * L["pad"] < L["kh"] or w + 2 * L["pad"] < L["kw"]:
            raise ValueError(f"{name}: kernel larger than its (padded) {h}x{w} input")
        oh, ow, sh, sw = out_shape(L, h, w)
        if L["pool"] and (oh < 2 or ow < 2):
            raise ValueError(f"{name}: 2x2 pooling needs an output of at least 2x2, gets {oh}x{ow}")
        if L["pool"] and ow > 128:
            raise ValueError(f"{name}: pooling needs an output at most 128 wide")
        if map_words(L["cout"], sh, sw) > BUF_WORDS:
            raise ValueError(f"{name}: its stored output {sh}x{sw}x{L['cout']} needs {map_words(L['cout'], sh, sw)} words, "
                             f"a feature buffer holds {BUF_WORDS} (fewer filters, more pooling, or a smaller input)")
        if L["softmax"] and (i != len(layers) - 1 or sh != 1 or sw != 1):
            raise ValueError(f"{name}: softmax only on the last layer, with a 1x1 output")
        h, w, c = sh, sw, L["cout"]
    return h, w, c


# ---------------------------------------------------------------- arithmetic (NCHW)
def im2col(x, kh, kw, stride, pad):
    """Rows (n, oy, ox); columns in the chip's weight order c*(kh*kw) + i*kw + j."""
    n, c, h, w = x.shape
    xp = np.pad(x, ((0, 0), (0, 0), (pad, pad), (pad, pad)))
    oh = (h + 2 * pad - kh) // stride + 1
    ow = (w + 2 * pad - kw) // stride + 1
    cols = np.empty((n, c, kh, kw, oh, ow), dtype=x.dtype)
    for i in range(kh):
        for j in range(kw):
            cols[:, :, i, j] = xp[:, :, i:i + stride * oh:stride, j:j + stride * ow:stride]
    return cols.transpose(0, 4, 5, 1, 2, 3).reshape(n * oh * ow, c * kh * kw), oh, ow


def pool2(a):
    n, c, h, w = a.shape
    return a[:, :, :h // 2 * 2, :w // 2 * 2].reshape(n, c, h // 2, 2, w // 2, 2).max(axis=(3, 5))


def float_forward(layers, params, x):
    """Float network in chip order. Returns the logits and every layer's output before pooling (for calibration)."""
    acts = []
    for L, (w, b) in zip(layers, params):
        cols, oh, ow = im2col(x, L["kh"], L["kw"], L["stride"], L["pad"])
        z = (cols @ w.reshape(w.shape[0], -1).T + b).reshape(x.shape[0], oh, ow, -1).transpose(0, 3, 1, 2)
        a = np.maximum(z, 0) if L["relu"] else z
        acts.append(a)
        x = pool2(a) if L["pool"] else a
    return x.reshape(x.shape[0], -1), acts


# ---------------------------------------------------------------- quantization
def quantize_factor(f):
    """M / 2^S ~= f with the largest S that keeps M <= 32767."""
    s = 0
    while round(f * 2 ** (s + 1)) <= 32767 and s < 47:
        s += 1
    return int(round(f * 2 ** s)), s


def quantize(layers, params, xcal, s_in=1.0 / 127.0):
    """Per-layer int8 weights (symmetric, per tensor), int32 biases, M/S; output scales from calibration images."""
    _, acts = float_forward(layers, params, xcal)
    q = []
    for L, (w, b), a in zip(layers, params, acts):
        s_w = float(np.abs(w).max()) / 127.0 or 1.0
        wq = np.clip(np.round(w / s_w), -127, 127).astype(np.int64)
        bq = np.round(b / (s_in * s_w)).astype(np.int64)
        s_out = float(np.abs(a).max()) / 127.0 or 1.0
        m, s = quantize_factor(s_in * s_w / s_out)
        if m < 1:
            m = 1
        q.append(dict(wq=wq, bq=bq, M=m, S=s, M_neg=0 if L["relu"] else m, s_in=s_in, s_w=s_w, s_out=s_out))
        s_in = s_out
    s_logit = q[-1]["s_out"]
    table = np.array([int(round(32767 * np.exp(((t - 256) if t >= 128 else 0) * s_logit))) for t in range(256)],
                     dtype=np.int64)
    return q, table


def input_int8(x, scale=127.0):
    return np.clip(np.round(x * scale), -128, 127).astype(np.int64)


def req(acc, m, mneg, s):
    y = np.where(acc < 0, acc * mneg, acc * m).astype(np.int64)
    if s > 0:
        y = (y >> s) + ((y >> (s - 1)) & 1)
    return np.clip(y, -2 ** 31, 2 ** 31 - 1)


def golden(layers, q, table, xi):
    """Integer forward pass of one image (int8, C x H x W) exactly as the chip computes it.
    Returns every layer's stored int8 map (C x H x W) and the final output bytes (probabilities x 128 after
    softmax, or the int8 logits if the last layer has no softmax)."""
    x = xi[None].astype(np.int64)
    maps = []
    for L, ql in zip(layers, q):
        cols, oh, ow = im2col(x, L["kh"], L["kw"], L["stride"], L["pad"])
        acc = (cols @ ql["wq"].reshape(ql["wq"].shape[0], -1).T + ql["bq"]).reshape(1, oh, ow, -1).transpose(0, 3, 1, 2)
        y = np.clip(req(acc, ql["M"], ql["M_neg"], ql["S"]), -128, 127)
        if L["pool"]:
            y = pool2(y)
        maps.append(y[0])
        x = y
    out = maps[-1][:, 0, 0]
    if layers[-1]["softmax"]:
        d = np.clip(out - out.max(), -128, 0)
        e = table[d & 255]
        r = (1 << 30) // int(e.sum())
        p = (r * e) & 0xFFFFFFFF
        p = np.where(p >= 2 ** 31, p - 2 ** 32, p)
        out = np.clip((p >> 23) + ((p >> 22) & 1), 0, 127)
        maps[-1] = out.reshape(-1, 1, 1)                 # the last layer stores the probabilities
    return maps, out
