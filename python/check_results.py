"""Compare what the chip produced (outputs/chip_results.hex, written by tb_model.v) with the golden model.

    python3 check_results.py <model_dir> <chip_results.hex> [--all] [--names a,b,c,...]

The chip's results come only from the simulation: the result it wrote back to memory, and the probe's record
of each layer's stores. This script computes nothing for the chip - it compares, counts and draws.
Exit status 1 if any byte differs from the golden model.
"""
import sys
import numpy as np


def map_words(c, h, w):
    return 1 + c * h * ((w + 3) // 4)


def positions(c, h, w, mode):
    """Byte position of value (c, y, x) of a stored map: guard word, planar, rows padded to 4 bytes."""
    rp = (w + 3) // 4
    pos = np.empty((c, h, w), dtype=np.int64)
    for ci in range(c):
        for y in range(h):
            for x in range(w):
                pos[ci, y, x] = (1 + ci) * 4 if mode == 4 else (1 + ci * h * rp + y * rp + x // 4) * 4 + x % 4
    return pos


def read_chip(path, shapes, n_img):
    lay_bytes = [map_words(c, h, w) * 4 for h, w, c in shapes]
    wb_words = map_words(shapes[-1][2], shapes[-1][0], shapes[-1][1])
    lines = [ln.strip() for ln in open(path) if ln.strip() and not ln.startswith("//")]
    out, i = [], 0
    while i < len(lines):
        tag, n, cyc = lines[i].split()
        assert tag == "image", f"unexpected line {lines[i]!r}"
        i += 1
        wb = [int(lines[i + k], 16) for k in range(wb_words)]
        i += wb_words
        layers = []
        for nb in lay_bytes:
            vals = np.array([int(lines[i + k][:2], 16) for k in range(nb)], dtype=np.int64)
            cnts = np.array([int(lines[i + k][2:]) for k in range(nb)], dtype=np.int64)
            layers.append((vals, cnts))
            i += nb
        wbb = np.frombuffer(np.array(wb, dtype="<u4").tobytes(), dtype=np.uint8).astype(np.int64)
        out.append(dict(cycles=int(cyc), wb=wbb, layers=layers))
    if len(out) != n_img:
        sys.exit(f"the chip's results hold {len(out)} images, expected {n_img} (did the simulation finish?)")
    return out


def s8(v):
    return np.where(v >= 128, v - 256, v)


def draw(img):
    """Rows of characters for one image (C x H x W int8): brightness, # dark ... faint."""
    g = img.astype(np.float64).mean(axis=0)
    wide = img.shape[2] > 16
    rows = []
    for y in range(img.shape[1]):
        r = ""
        for v in g[y]:
            ch = "#" if v > 90 else "+" if v > 45 else "." if v > 12 else " "
            r += ch if wide else ch * 2
        rows.append(r)
    return rows


def gallery(idx, imgs, labels, preds, outs, softmax, names, out):
    if len(idx) == 0:
        return
    colw = max(len(draw(imgs[0])[0]) + 4, 22)
    per_row = max(1, min(6, 120 // colw))
    nm = (lambda k: "?" if k < 0 else (names[k] if names and k < len(names) else str(k)))
    for s in range(0, len(idx), per_row):
        grp = idx[s:s + per_row]
        pics = [draw(imgs[i]) for i in grp]
        out.append("".join(f"  image {i:<5d}".ljust(colw) for i in grp))
        for y in range(len(pics[0])):
            out.append("".join(("  " + p[y]).ljust(colw) for p in pics))
        out.append("".join((f"  label {nm(labels[i])} chip {nm(preds[i])}" + ("" if preds[i] == labels[i] or labels[i] < 0 else " <-")).ljust(colw)
                           for i in grp))
        line = ""
        for i in grp:
            o = outs[i]
            b1, b2 = np.argsort(-o, kind="stable")[:2]
            line += (f"  {nm(b1)}:{o[b1] / 128:.2f} {nm(b2)}:{o[b2] / 128:.2f}" if softmax
                     else f"  {nm(b1)}:{o[b1]} {nm(b2)}:{o[b2]}").ljust(colw)
        out.append(line)
        out.append("")


def main(model_dir, chip_path, show_all=False, names=None):
    g = np.load(f"{model_dir}/golden.npz")
    shapes, modes = [tuple(s) for s in g["shapes"]], list(g["modes"])
    imgs, labels, gout = g["images"], g["labels"].ravel(), g["outputs"]
    n = len(imgs)
    chip = read_chip(chip_path, shapes, n)
    softmax = bool(g["softmax"])

    # 1. every layer's map (probe) and the written-back result, byte for byte
    map_err, out_err, first = 0, 0, []
    chip_out = []
    for i, r in enumerate(chip):
        for li, ((h, w, c), mode) in enumerate(zip(shapes, modes)):
            pos = positions(c, h, w, mode)
            vals, cnts = r["layers"][li]
            got, cnt = s8(vals[pos]), cnts[pos]
            exp = g[f"map{li}"][i].reshape(c, h, w)
            bad = (got != exp) | (cnt != 1)
            map_err += int(bad.sum())
            for (ci, y, x) in np.argwhere(bad)[:max(0, 5 - len(first))]:
                first.append(f"image {i} layer {li} ({ci},{y},{x}): chip {got[ci, y, x]} (written {cnt[ci, y, x]}x), "
                             f"golden {exp[ci, y, x]}")
        h, w, c = shapes[-1]
        wbpos = positions(c, h, w, modes[-1]).reshape(-1)
        o = s8(r["wb"][wbpos])
        chip_out.append(o)
        if (o != gout[i]).any():
            out_err += int((o != gout[i]).sum())
            if len(first) < 5:
                first.append(f"image {i}: written-back result {list(o)}, golden {list(gout[i])}")
    chip_out = np.array(chip_out)

    # 2. predictions and accuracy: from the chip's written-back result
    pred = np.array([int(np.argmax(o)) for o in chip_out])
    gpred = np.array([int(np.argmax(o)) for o in gout])
    report = []
    show = list(range(n)) if show_all or n <= 60 else list(range(60))
    report.append(f"The first {len(show)} images as the chip saw them, with label, the chip's prediction and its two largest "
                  f"{'probabilities' if softmax else 'outputs'} (<- marks a misclassified image):\n")
    gallery(show, imgs, labels, pred, chip_out, softmax, names, report)
    known = labels >= 0                                  # photos without a label (-1) are not counted
    wrong = [i for i in range(n) if known[i] and pred[i] != labels[i]]
    report.append(f"All {len(wrong)} misclassified images:\n")
    gallery(wrong, imgs, labels, pred, chip_out, softmax, names, report)
    print("\n".join(report))

    with open(f"{chip_path.rsplit('/', 1)[0]}/model_results.txt", "w") as f:
        for i in range(n):
            f.write(f"image {i:4d}  label {labels[i] if known[i] else '?'}  chip {pred[i]}  "
                    f"{'     ' if not known[i] else 'ok   ' if pred[i] == labels[i] else 'WRONG'}  "
                    f"{chip[i]['cycles']} cycles  outputs: {' '.join(str(v) for v in chip_out[i])}\n")
        f.write("\n")
        full = []
        gallery(list(range(n)), imgs, labels, pred, chip_out, softmax, names, full)
        f.write("\n".join(full))

    cyc = np.mean([r["cycles"] for r in chip])
    nk = int(known.sum())
    if nk:
        print(f"Accuracy on the {nk} labelled images:")
        print(f"    the chip (RTL)                    {int((pred == labels)[known].sum())} of {nk} = "
              f"{(pred == labels)[known].mean() * 100:.2f}%")
        print(f"    integer golden model (Python)     {int((gpred == labels)[known].sum())} of {nk}")
        if nk == n:
            print(f"    (on the whole test set of the flow: float {float(g['float_acc']) * 100:.2f}%, "
                  f"integer {float(g['int_acc']) * 100:.2f}%)")
    else:
        print("No labels given, so no accuracy - the predictions are in the gallery above.")
    print("Chip against the golden model:")
    print(f"    chip and golden model predict the same class on {int((pred == gpred).sum())} of {n} images")
    print(f"    {map_err} layer-map bytes and {out_err} written-back bytes differ from the golden model")
    print(f"    {cyc:.0f} cycles per image on average ({cyc / 100:.1f} us at 100 MHz)")
    for m in first:
        print("    FIRST DIFFERENCES: " + m)
    print("    every image with its outputs and the full gallery: " + chip_path.rsplit('/', 1)[0] + "/model_results.txt\n")
    if map_err or out_err or (pred != gpred).any():
        print("FAIL: the chip's results differ from the golden model")
        sys.exit(1)
    print("PASS: the chip's results (every layer, and the result it wrote back) match the golden model exactly")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 2:
        sys.exit("usage: python3 check_results.py <model_dir> <chip_results.hex> [--all] [--names a,b,...]")
    nms = None
    for a in sys.argv[1:]:
        if a.startswith("--names="):
            nms = a.split("=", 1)[1].split(",")
    main(args[0], args[1], "--all" in sys.argv, nms)
