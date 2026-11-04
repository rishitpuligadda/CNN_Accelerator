"""Quantization and the bit-exact integer model of the chip.

Every rule here mirrors the hardware exactly (spec vector_isa.md):
  REQ:   y = acc * (acc < 0 ? M_neg : M_pos);  y = (y >> S) + ((y >> (S-1)) & 1) if S > 0;  saturate to int32
  store: clamp to the clamp set, saturate to int8
  pool:  2x2 max of the stored int8 values (floor for odd sizes)
  softmax: d = clamp(logit - max, -128, 0); e = table[d & 255]; R = floor(2^30 / sum e);
           q = SHRR(low32(R * e), 23) clamped to 0..127  (probability x 128)
"""
import numpy as np
from model import LAYERS, forward, im2col


def quantize_factor(f):
    """M / 2^S ~= f with the largest S that keeps M <= 32767 (as in the hardware tests)."""
    s = 0
    while round(f * 2 ** (s + 1)) <= 32767 and s < 47:
        s += 1
    return int(round(f * 2 ** s)), s


def quantize(params, xcal):
    """Per-layer int8 weights, int32 biases and requantization; activation scales from calibration images."""
    _, _, acts = forward(params, xcal, keep=True)
    s_in = 1.0 / 127.0                       # input pixels 0..1 -> int8 0..127
    q = []
    for L, (w, b), a in zip(LAYERS, params, acts):
        s_w = np.abs(w).max() / 127.0
        wq = np.clip(np.round(w / s_w), -127, 127).astype(np.int64)
        bq = np.round(b / (s_in * s_w)).astype(np.int64)
        s_out = np.abs(a).max() / 127.0
        m, s = quantize_factor(s_in * s_w / s_out)
        q.append(dict(wq=wq, bq=bq, M=m, S=s, M_neg=0 if L["relu"] else m,
                      s_in=s_in, s_w=s_w, s_out=s_out))
        s_in = s_out
    # exp table for the softmax: one int8 logit step is s_out of the last layer
    s_logit = q[-1]["s_out"]
    table = np.array([int(round(32767 * np.exp(((b - 256) if b >= 128 else 0) * s_logit))) for b in range(256)],
                     dtype=np.int64)
    return q, table


def input_int8(x):
    return np.clip(np.round(x * 127), 0, 127).astype(np.int64)


def req(acc, m, mneg, s):
    y = np.where(acc < 0, acc * mneg, acc * m).astype(np.int64)
    if s > 0:
        y = (y >> s) + ((y >> (s - 1)) & 1)
    return np.clip(y, -2 ** 31, 2 ** 31 - 1)


def golden(q, table, xi):
    """Integer forward pass of one image (int8, shape 1x8x8). Returns every layer's stored int8 map,
    the logits' accumulators, and the 10 output bytes (probability x 128)."""
    x = xi[None].astype(np.int64)            # (1, C, H, W)
    maps = []
    for L, ql in zip(LAYERS, q):
        cols, oh, ow = im2col(x, L["k"], L["pad"])
        acc = cols @ ql["wq"].reshape(ql["wq"].shape[0], -1).T + ql["bq"]
        acc = acc.reshape(1, oh, ow, -1).transpose(0, 3, 1, 2)
        y = np.clip(req(acc, ql["M"], ql["M_neg"], ql["S"]), -128, 127)
        if L["pool"]:
            n, c, h, w = y.shape
            y = y[:, :, :h // 2 * 2, :w // 2 * 2].reshape(n, c, h // 2, 2, w // 2, 2).max(axis=(3, 5))
        maps.append(y[0])
        x = y
    logits = maps[-1][:, 0, 0]
    d = np.clip(logits - logits.max(), -128, 0)
    e = table[d & 255]
    r = (1 << 30) // int(e.sum())
    p = (r * e) & 0xFFFFFFFF
    p = np.where(p >= 2 ** 31, p - 2 ** 32, p)
    probs = np.clip((p >> 23) + ((p >> 22) & 1), 0, 127)
    return maps, probs
