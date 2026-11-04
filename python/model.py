"""A small CNN for 8x8 handwritten digits, defined and trained in plain numpy.

    input 8x8x1
    conv 3x3, pad 1, 8 filters  + ReLU + 2x2 max pool   -> 4x4x8
    conv 3x3, pad 1, 16 filters + ReLU + 2x2 max pool   -> 2x2x16
    fully connected (a 2x2 conv over the whole map), 10 classes + softmax

The layer list is the network description the quantizer and compiler use.
"""
import numpy as np

LAYERS = [
    dict(kind="conv", cin=1,  cout=8,  k=3, pad=1, relu=True, pool=True),
    dict(kind="conv", cin=8,  cout=16, k=3, pad=1, relu=True, pool=True),
    dict(kind="fc",   cin=16, cout=10, k=2, pad=0, relu=False, pool=False),
]


def load_digits_split(seed=0):
    from sklearn.datasets import load_digits
    d = load_digits()
    x = d.images.astype(np.float32) / 16.0           # 0..1
    y = d.target.astype(np.int64)
    rng = np.random.default_rng(seed)
    idx = rng.permutation(len(x))
    n_test = 360
    te, tr = idx[:n_test], idx[n_test:]
    return x[tr, None], y[tr], x[te, None], y[te]     # (N, 1, 8, 8)


# ---------------------------------------------------------------- building blocks (NCHW)
def im2col(x, k, pad):
    n, c, h, w = x.shape
    xp = np.pad(x, ((0, 0), (0, 0), (pad, pad), (pad, pad)))
    oh, ow = h + 2 * pad - k + 1, w + 2 * pad - k + 1
    cols = np.empty((n, c, k, k, oh, ow), dtype=x.dtype)
    for i in range(k):
        for j in range(k):
            cols[:, :, i, j] = xp[:, :, i:i + oh, j:j + ow]
    # rows: (n, oh, ow); columns: (c, kh, kw) - the chip's k order c*(kh*kw) + kh*kw_size + kw
    return cols.transpose(0, 4, 5, 1, 2, 3).reshape(n * oh * ow, c * k * k), oh, ow


def col2im(dcols, xshape, k, pad, oh, ow):
    n, c, h, w = xshape
    d = dcols.reshape(n, oh, ow, c, k, k).transpose(0, 3, 4, 5, 1, 2)
    dxp = np.zeros((n, c, h + 2 * pad, w + 2 * pad), dtype=dcols.dtype)
    for i in range(k):
        for j in range(k):
            dxp[:, :, i:i + oh, j:j + ow] += d[:, :, i, j]
    return dxp[:, :, pad:pad + h, pad:pad + w]


def init_params(seed=1):
    rng = np.random.default_rng(seed)
    params = []
    for L in LAYERS:
        fan_in = L["cin"] * L["k"] * L["k"]
        w = rng.normal(0, np.sqrt(2.0 / fan_in), (L["cout"], L["cin"], L["k"], L["k"])).astype(np.float32)
        b = np.zeros(L["cout"], dtype=np.float32)
        params.append([w, b])
    return params


def forward(params, x, keep=False):
    cache = []
    acts = []                                  # each layer's output before pooling (for calibration)
    for L, (w, b) in zip(LAYERS, params):
        cols, oh, ow = im2col(x, L["k"], L["pad"])
        z = cols @ w.reshape(w.shape[0], -1).T + b
        z = z.reshape(x.shape[0], oh, ow, -1).transpose(0, 3, 1, 2)
        a = np.maximum(z, 0) if L["relu"] else z
        acts.append(a)
        if L["pool"]:
            n, c, h, ww = a.shape
            r = a[:, :, :h // 2 * 2, :ww // 2 * 2].reshape(n, c, h // 2, 2, ww // 2, 2)
            p = r.max(axis=(3, 5))
            mask = (r == p[:, :, :, None, :, None])
        else:
            p, mask = a, None
        cache.append((x, cols, oh, ow, z, a, mask))
        x = p
    logits = x.reshape(x.shape[0], -1)
    return (logits, cache, acts) if keep else logits


def train(epochs=60, lr=0.01, batch=64, seed=1, verbose=True):
    xtr, ytr, xte, yte = load_digits_split()
    params = init_params(seed)
    m = [[np.zeros_like(w), np.zeros_like(b)] for w, b in params]
    v = [[np.zeros_like(w), np.zeros_like(b)] for w, b in params]
    rng = np.random.default_rng(seed)
    step = 0
    for ep in range(epochs):
        order = rng.permutation(len(xtr))
        for s in range(0, len(xtr), batch):
            bi = order[s:s + batch]
            logits, cache, _ = forward(params, xtr[bi], keep=True)
            p = np.exp(logits - logits.max(axis=1, keepdims=True))
            p /= p.sum(axis=1, keepdims=True)
            g = p.copy()
            g[np.arange(len(bi)), ytr[bi]] -= 1
            g /= len(bi)
            grad = g.reshape(len(bi), -1, 1, 1)
            grads = [None] * len(LAYERS)
            for li in reversed(range(len(LAYERS))):
                L = LAYERS[li]
                x, cols, oh, ow, z, a, mask = cache[li]
                w, b = params[li]
                if L["pool"]:
                    n, c, h, ww = a.shape
                    up = np.zeros_like(a)
                    gm = mask * grad[:, :, :, None, :, None]
                    up[:, :, :h // 2 * 2, :ww // 2 * 2] = gm.reshape(n, c, h // 2 * 2, ww // 2 * 2)
                    grad = up
                if L["relu"]:
                    grad = grad * (z > 0)
                gz = grad.transpose(0, 2, 3, 1).reshape(-1, w.shape[0])
                gw = (gz.T @ cols).reshape(w.shape)
                gb = gz.sum(axis=0)
                grads[li] = [gw, gb]
                if li > 0:
                    grad = col2im(gz @ w.reshape(w.shape[0], -1), x.shape, L["k"], L["pad"], oh, ow)
            step += 1
            for li in range(len(LAYERS)):
                for t in range(2):
                    m[li][t] = 0.9 * m[li][t] + 0.1 * grads[li][t]
                    v[li][t] = 0.999 * v[li][t] + 0.001 * grads[li][t] ** 2
                    mh = m[li][t] / (1 - 0.9 ** step)
                    vh = v[li][t] / (1 - 0.999 ** step)
                    params[li][t] -= lr * mh / (np.sqrt(vh) + 1e-8)
        if verbose and (ep % 10 == 9 or ep == epochs - 1):
            acc = (forward(params, xte).argmax(axis=1) == yte).mean()
            print(f"  epoch {ep + 1:3d}: test accuracy {acc * 100:.1f}%")
    return params


if __name__ == "__main__":
    p = train()
    np.savez("float_model.npz", *[a for wb in p for a in wb])
