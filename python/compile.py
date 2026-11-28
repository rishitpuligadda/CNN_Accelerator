"""Compile a quantized network into what the chip reads from external memory.

Memory map (32-bit words), laid out per model:
    input image | weights | feature maps kept in external memory | layer table | result (written by the chip)
A layer whose input or output does not fit a feature buffer runs as several table entries, one per band of
output rows; each band loads its input rows (with the rows its kernel overlaps) from external memory and
writes its output rows back. Maps that fit stay on chip between layers.

Files written (see write_files): model_mem.hex, images.hex, model_params.vh, golden.npz
"""
import numpy as np
import chipnet

HDR_WORDS = 16              # layer-table entry header: 10 fields, then 6 sections


def venc(op, pr, d, a, b, x):
    return (op << 26) | (pr << 23) | (d << 19) | (a << 15) | (b << 11) | (x & 0x7FF)


def LI(d, v):
    if not -262144 <= v <= 262143:
        raise ValueError(f"LI immediate {v} does not fit 19 bits")
    return (0x01 << 26) | (d << 19) | (v & 0x7FFFF)


def program(L, ql, out_h, out_w):
    """Vector-unit program for one layer, returning (words, sections, mode) like the RTL tests build them.
    mode 1: requantize (+ ReLU) and store; 2: requantize (+ ReLU) + 2x2 max pooling; 4: requantize + softmax."""
    p = []
    mode = 4 if L["softmax"] else (2 if L["pool"] else 1)
    p += [LI(1, ql["M"]), LI(2, ql["M_neg"]), venc(0x09, 0, 0, 1, 2, ql["S"]),     # SETQ q0
          LI(3, -128), LI(4, 127), venc(0x0A, 0, 0, 3, 4, 0)]                       # SETC c0 = int8
    if mode == 2:
        orp = (out_w + 3) // 4
        p += [LI(1, 1), venc(0x14, 0, 0, 1, 0, 0),             # SETR out_base = 1
              LI(1, out_h * orp), venc(0x14, 0, 0, 1, 0, 1),   # SETR channel pitch
              LI(1, orp), venc(0x14, 0, 0, 1, 0, 2),           # SETR row pitch
              LI(1, 1), venc(0x14, 0, 0, 1, 0, 3),             # SETR L = 1 (2x2)
              venc(0x0C, 0, 2, 0, 1, (0 << 5) | (2 << 3) | 2),  # P2: row, low 1 bit == 0
              venc(0x0C, 0, 3, 0, 1, (1 << 5) | (2 << 3) | 2)]  # P3: row, low 1 bit == 1
    if mode == 4:
        p += [LI(3, 0), LI(4, chipnet.M_MAX), venc(0x0A, 0, 2, 3, 4, 0),          # c2 = 0..8191 (max - logit)
              LI(4, 127), venc(0x0A, 0, 1, 3, 4, 0),                            # c1 = 0..127 (probability)
              LI(3, chipnet.LOGIT_LO), LI(4, chipnet.LOGIT_HI), venc(0x0A, 0, 3, 3, 4, 0),  # c3 = 16-bit logit
              venc(0x12, 0, 6, 3, 0, 0),                                        # BCAST v6, s3 (running max)
              venc(0x11, 0, 5, 0, 0, 0),                                        # VLI v5, 0 (running sum)
              venc(0x11, 0, 4, 0, 0, chipnet.LN2_K),                            # VLI v4, 177 (ln2/256 * 2^16)
              LI(10, 1), LI(11, 1)]
    s_pro = len(p)
    body = len(p)
    p.append(venc(0x21, 0, 0, 7, 0, 0))                        # REQ v0, v7, q0
    if mode == 1:
        p.append(venc(0x38, 0, 0, 0, 0, 0))                    # ST8 v0, c0
    if mode == 2:
        # 2x2 max pooling in 6 instructions per packet: the even row's pair maxima wait in local memory
        # (entry lmidx) for the odd row; the odd row takes the max and stores it at the pooled address
        p[body] = venc(0x21, 0, 0, 7, 0, 0x10)                 # REQ.sat8 v0, v7, q0 (requantize, int8)
        p += [venc(0x30, 0, 1, 0, 0, 1),                       # MAXP.dup v1, v0 (pair maxima, also in lanes 2,3)
              venc(0x3C, 2, 0, 1, 0, 1),                       # [p2] STS.lmidx v1
              venc(0x3B, 3, 2, 0, 0, 1),                       # [p3] LDS.lmidx v2
              venc(0x1B, 3, 1, 1, 2, 0),                       # [p3] MAX v1, v1, v2
              venc(0x3A, 3, 0, 1, 0, 0)]                       # [p3] ST8P v1, c0 (address unit: paddr, pbe)
    if mode == 4:
        p += [venc(0x22, 0, 0, 0, 0, 3),                       # CLAMP v0, v0, c3 (16-bit logit)
              venc(0x08, 0, 1, 0, 0, 4),                       # TAG s1, chan
              venc(0x3C, 0, 0, 0, 1, 0),                       # STS v0, s1
              venc(0x1B, 0, 6, 6, 0, 0)]                       # MAX v6, v6, v0
    e0 = len(p)
    if mode == 4:
        p += [venc(0x08, 0, 1, 0, 0, 9), venc(0x3B, 0, 1, 1, 0, 0),    # TAG s1, iter;  LDS v1, s1
              venc(0x19, 0, 1, 6, 1, 0), venc(0x22, 0, 1, 1, 0, 2),    # SUB v1, v6, v1 (m = max - y); CLAMP c2
              venc(0x1E, 0, 3, 1, 0, 4),                               # SHR v3, v1, 4      j
              venc(0x1D, 0, 2, 3, 0, 4), venc(0x19, 0, 2, 1, 2, 0),    # SHL v2, v3, 4; SUB v2, v1, v2   r = m & 15
              venc(0x20, 0, 2, 2, 4, 0),                               # MUL v2, v2, v4     r * 177
              venc(0x23, 0, 3, 3, 0, 0),                               # LUT v3, v3         t = 2^(-j/16), Q14
              venc(0x20, 0, 2, 3, 2, 0), venc(0x1F, 0, 2, 2, 0, 16),   # MUL v2, v3, v2; SHRR v2, 16
              venc(0x19, 0, 3, 3, 2, 0),                               # SUB v3, v3, v2     t * 2^(-r/256)
              venc(0x1E, 0, 2, 1, 0, 8), venc(0x24, 0, 3, 3, 2, 0),    # SHR v2, v1, 8; SHRRV v3, v3, v2   e
              venc(0x3C, 0, 0, 3, 1, 0), venc(0x18, 0, 5, 5, 3, 0)]    # STS v3, s1; ADD v5, v5, v3
    e1 = len(p)
    if mode == 4:
        p += [venc(0x33, 0, 2, 5, 0, 0), venc(0x0B, 0, 3, 2, 0, 30),   # RADD s2, v5;  RCP s3, s2, 30
              venc(0x12, 0, 4, 3, 0, 0)]                               # BCAST v4, s3
    e2 = len(p)
    if mode == 4:
        p += [venc(0x08, 0, 1, 0, 0, 9), venc(0x3B, 0, 1, 1, 0, 0),    # TAG s1, iter;  LDS v1, s1
              venc(0x20, 0, 2, 4, 1, 0), venc(0x1F, 0, 2, 2, 0, 23),   # MUL v2, v4, v1; SHRR 23
              venc(0x04, 0, 5, 10, 1, 0), venc(0x39, 0, 11, 2, 5, 1)]  # ADDS s5, s10, s1; ST8A ... c1
    e3 = len(p)
    if len(p) > 64:
        raise ValueError("program longer than 64 instructions")
    cnt = L["cout"]
    sections = [(0, s_pro, 1), (body, e0 - body, 0), (e0, e1 - e0, cnt), (e1, e2 - e1, 1),
                (e2, e3 - e2, cnt), (0, 0, 0)]
    return p, sections, mode


def _align(a, n=16):
    return (a + n - 1) // n * n


def entry_words(L, w, sects, prog, nlut, table, *, in_h, pad_t, pad_b, load, ld, wb, last, waddr):
    """One layer-table entry: header (16 words), program, lookup table."""
    ld_base, ld_words, ld_nblk, ld_sram, ld_stride = ld
    wb_ext, wb_words, wb_nblk, wb_src, wb_stride = wb
    hdr = [
        (L["cout"] << 24) | (L["cin"] << 16) | (w << 8) | in_h,
        L["kh"] | (L["kw"] << 4) | (L["pad"] << 8) | (pad_t << 11) | (pad_b << 14) | (L["stride"] << 17)
        | ((1 if L["pool"] else 0) << 20) | (int(load) << 22) | (int(wb_words > 0) << 23) | (int(last) << 24),
        waddr,
        1 | (len(prog) << 16) | (nlut << 23),                       # output base word 1 (word 0: guard)
        ld_base, ld_words | (ld_nblk << 12) | (ld_sram << 20), ld_stride,
        wb_ext, wb_words | (wb_nblk << 12) | (wb_src << 20), wb_stride,
    ] + [(c << 13) | (ln << 6) | st for st, ln, c in sects]
    assert len(hdr) == HDR_WORDS
    return hdr + prog + [int(table[2 * i]) | (int(table[2 * i + 1]) << 16) for i in range(nlut // 2)]


def compile_network(layers, q, table, in_c, in_h, in_w):
    bands, _ = chipnet.check_limits(layers, in_c, in_h, in_w)
    n = len(layers)
    mem = {}
    # shapes
    shp = []
    h, w, c = in_h, in_w, in_c
    for L in layers:
        oh, ow, sh, sw = chipnet.out_shape(L, h, w)
        shp.append((h, w, c, oh, ow, sh, sw))
        h, w, c = sh, sw, L["cout"]
    img_words = chipnet.map_words(in_c, in_h, in_w)
    ptr = _align(img_words)
    # weights: per group of 4 filters, 4 bias words, then M words {w3[k], w2[k], w1[k], w0[k]}
    waddrs = []
    for L, ql in zip(layers, q):
        wq = ql["wq"].reshape(L["cout"], -1)
        m = wq.shape[1]
        waddrs.append(ptr)
        for g in range((L["cout"] + 3) // 4):
            for j in range(4):
                f = 4 * g + j
                mem[ptr + j] = int(ql["bq"][f]) & 0xFFFFFFFF if f < L["cout"] else 0
            for k in range(m):
                word = 0
                for j in range(4):
                    f = 4 * g + j
                    if f < L["cout"]:
                        word |= (int(wq[f, k]) & 0xFF) << (8 * j)
                mem[ptr + 4 + k] = word
            ptr += m + 4
    wgt_end = ptr
    # which maps go through external memory: a banded layer's input and output, and the result
    out_ext = [bands[i] > 0 or (i + 1 < n and bands[i + 1] > 0) or i == n - 1 for i in range(n)]
    in_ext = [i == 0 or out_ext[i - 1] for i in range(n)]
    map_base = [None] * n
    ptr = _align(ptr)
    for i in range(n - 1):
        if out_ext[i]:
            h, w, c, oh, ow, sh, sw = shp[i]
            map_base[i] = ptr
            ptr = _align(ptr + chipnet.map_words(layers[i]["cout"], sh, sw))
    maps_end = ptr
    # table entries (placed after the maps), then the result area
    ents, probe, info = [], [], []
    for li, (L, ql) in enumerate(zip(layers, q)):
        h, w, c, oh, ow, sh, sw = shp[li]
        rp, orp = (w + 3) // 4, (sw + 3) // 4
        src = 0 if li == 0 else map_base[li - 1]          # input map in external memory (0 = the image)
        R = bands[li]
        nband = 1 if R == 0 else -(-sh // R)
        info.append(dict(bands=nband, rows=R, in_hw=(h, w), out=(sh, sw, L["cout"]), wgt=waddrs[li],
                         wgt_words=((L["cout"] + 3) // 4) * (L["cin"] * L["kh"] * L["kw"] + 4)))
        for b in range(nband):
            last = (li == n - 1) and (b == nband - 1)
            if R == 0:
                r0, r1, in_h_b, pad_t, pad_b = 0, sh, h, L["pad"], L["pad"]
                ld = (src, img_words if li == 0 else chipnet.map_words(c, h, w), 1, 0, 0) if in_ext[li] else (0, 0, 0, 0, 0)
                out_h_b = sh
            else:
                r0, r1 = b * R, min(sh, (b + 1) * R)
                P = 1 if L["pool"] else 0
                o0, o1 = r0 << P, r1 << P
                i0 = o0 * L["stride"] - L["pad"]
                i1 = (o1 - 1) * L["stride"] - L["pad"] + L["kh"]
                i0c, i1c = max(0, i0), min(h, i1)
                in_h_b, pad_t, pad_b = i1c - i0c, i0c - i0, i1 - i1c
                ld = (src + 1 + i0c * rp, in_h_b * rp, c, 1, h * rp)
                out_h_b = r1 - r0
            # write-back: (offset into the destination map, words, blocks, buffer word, stride); the destination
            # (the next layer's input map, or the result area after the table) is filled in below
            if not out_ext[li]:
                wb = (0, 0, 0, 0, 0)
            elif R == 0:
                wb = (0, chipnet.map_words(L["cout"], sh, sw), 1, 0, 0)
            else:
                wb = (1 + r0 * orp, out_h_b * orp, L["cout"], 1, sh * orp)
            prog, sects, mode = program(L, ql, out_h_b, sw)
            ents.append(dict(L=L, li=li, h=h, w=w, sh=sh, sw=sw, sects=sects, prog=prog, mode=mode,
                             nlut=16 if mode == 4 else 0, in_h=in_h_b, pad_t=pad_t, pad_b=pad_b,
                             load=in_ext[li], ld=ld, wb=wb, last=last, waddr=waddrs[li]))
            # how the testbench's probe maps this entry's buffer words onto the layer's whole map
            probe.append((li, 0 if R == 0 else out_h_b * orp, r0 * orp, sh * orp))
        info[-1]["mode"] = ents[-1]["mode"]
        info[-1]["prog"] = len(ents[-1]["prog"])
    tbl = _align(maps_end)
    tptr = tbl
    sizes = [HDR_WORDS + len(e["prog"]) + e["nlut"] // 2 for e in ents]    # the result area follows the table
    res = _align(tbl + sum(sizes))
    for e, sz in zip(ents, sizes):
        wb = e["wb"]
        if wb[1]:
            wb = ((res if e["li"] == n - 1 else map_base[e["li"]]) + wb[0],) + wb[1:]
        words = entry_words(e["L"], e["w"], e["sects"], e["prog"], e["nlut"], table,
                            in_h=e["in_h"], pad_t=e["pad_t"], pad_b=e["pad_b"], load=e["load"], ld=e["ld"], wb=wb,
                            last=e["last"], waddr=e["waddr"])
        assert len(words) == sz
        for i, wd in enumerate(words):
            mem[tptr + i] = wd & 0xFFFFFFFF
        inf = info[e["li"]]
        inf.setdefault("addr", tptr)
        inf["words"] = inf.get("words", 0) + sz
        tptr += sz
    res_words = chipnet.map_words(layers[-1]["cout"], shp[-1][5], shp[-1][6])
    layout = dict(img=0, img_words=img_words, wgt=_align(img_words), wgt_end=wgt_end, maps=_align(wgt_end),
                  maps_end=maps_end, tbl=tbl, tbl_words=tptr - tbl, res=res, res_words=res_words,
                  mem_words=_align(res + res_words, 1024), entries=len(ents))
    return mem, info, probe, layout


def image_words(xi):
    """Guard word, then planar channels, rows padded to a multiple of 4 bytes."""
    c, h, w = xi.shape
    rp = (w + 3) // 4 * 4
    nbytes = 4 + c * h * rp
    by = np.zeros(nbytes + (-nbytes) % 4, dtype=np.int64)
    for ci in range(c):
        for y in range(h):
            for x in range(w):
                by[4 + ci * h * rp + y * rp + x] = int(xi[ci, y, x]) & 0xFF
    return [int(by[i]) | (int(by[i + 1]) << 8) | (int(by[i + 2]) << 16) | (int(by[i + 3]) << 24)
            for i in range(0, len(by), 4)]


def write_hex_mem(path, mem):
    with open(path, "w") as f:
        last = None
        for a in sorted(mem):
            if last is None or a != last + 1:
                f.write(f"@{a:04x}\n")
            f.write(f"{mem[a]:08x}\n")
            last = a


def write_files(outdir, layers, entries, images, labels, results, float_acc, int_acc, n_rtl=None):
    """Files for the RTL run and for check_results.py.
    For the testbench (tb_model.v) - only what the chip and its memory need, no expected values:
      model_mem.hex (weights + layer table), images.hex, model_params.vh (memory map, counts and sizes, and how
      each table entry's buffer words map onto its layer's whole map, for the probe)
    For check_results.py only (the testbench never reads it):
      golden.npz - the golden model's every layer map and output, labels, images, layer shapes"""
    import os
    os.makedirs(outdir, exist_ok=True)
    n = len(images) if n_rtl is None else min(n_rtl, len(images))
    write_hex_mem(os.path.join(outdir, "model_mem.hex"), _MEM_CACHE["mem"])
    lay = _MEM_CACHE["layout"]
    probe = _MEM_CACHE["probe"]
    iw = len(image_words(images[0]))
    with open(os.path.join(outdir, "images.hex"), "w") as f:
        for i in range(n):
            for w in image_words(images[i]):
                f.write(f"{w:08x}\n")
    words = [chipnet.map_words(e["out"][2], e["out"][0], e["out"][1]) for e in entries]
    with open(os.path.join(outdir, "model_params.vh"), "w") as f:
        f.write("// written by the Python flow (compile.write_files): memory map and sizes only, no expected values\n")
        f.write(f"localparam NIMG = {n};\nlocalparam IMG_WORDS = {iw};\nlocalparam NL = {len(entries)};\n")
        f.write(f"localparam NE = {len(probe)};\nlocalparam MAXB = {4 * max(words)};\n")
        f.write(f"localparam IMG_EB = {lay['img']};\nlocalparam TBL_EB = {lay['tbl']};\nlocalparam WB_EB = {lay['res']};\n")
        f.write(f"localparam MEM_WORDS = {lay['mem_words']};\nlocalparam WB_WORDS = {words[-1]};\n")
        f.write("function integer lay_words(input integer l);\n\tcase (l)\n")
        for li, w in enumerate(words):
            f.write(f"\t\t{li}: lay_words = {w};\n")
        f.write("\t\tdefault: lay_words = 0;\n\tendcase\nendfunction\n")
        # probe: entry e stores into its buffer; word a of it is word map_word(e, a) of layer ent_layer(e)'s map
        for fn, k in (("ent_layer", 0), ("ent_bw", 1), ("ent_off", 2), ("ent_cp", 3)):
            f.write(f"function integer {fn}(input integer e);\n\tcase (e)\n")
            for ei, pr in enumerate(probe):
                f.write(f"\t\t{ei}: {fn} = {pr[k]};\n")
            f.write(f"\t\tdefault: {fn} = 0;\n\tendcase\nendfunction\n")
    np.savez(os.path.join(outdir, "golden.npz"),
             images=np.asarray(images[:n]), labels=np.asarray(labels[:n]),
             outputs=np.array([r[1] for r in results[:n]]),
             **{f"map{li}": np.array([r[0][li] for r in results[:n]]) for li in range(len(entries))},
             shapes=np.array([e["out"] for e in entries]), modes=np.array([e["mode"] for e in entries]),
             softmax=layers[-1]["softmax"], float_acc=float_acc, int_acc=int_acc)
    return n


_MEM_CACHE = {}


def build(layers, q, table, in_c, in_h, in_w):
    mem, entries, probe, layout = compile_network(layers, q, table, in_c, in_h, in_w)
    _MEM_CACHE.update(mem=mem, probe=probe, layout=layout)
    return mem, entries


def report_and_write(layers, params, xtr, xte, yte, outdir, float_logits, in_scale=127.0, n_rtl=None):
    float_pred = float_logits.argmax(axis=1)
    known = yte >= 0                                     # -1 = no label (e.g. your own photos)
    float_acc = (float_pred == yte)[known].mean() if known.any() else 0.0

    print("\n2) Quantization (calibration on training images):")
    q, table = chipnet.quantize(layers, params, xtr, s_in=1.0 / in_scale)
    for li, (L, ql) in enumerate(zip(layers, q)):
        print(f"   layer {li} ({L['kind']} {L['cin']}->{L['cout']}, {L['kh']}x{L['kw']}, stride {L['stride']}, "
              f"pad {L['pad']}{', ReLU' if L['relu'] else ''}{', 2x2 pool' if L['pool'] else ''}"
              f"{', softmax' if L['softmax'] else ''}): requantization "
              f"{ql['s_in'] * ql['s_w'] / ql['s_out']:.6f} ~ M {ql['M']} / 2^{ql['S']}")
    if layers[-1]["softmax"]:
        print(f"   softmax: 16-bit logits in base-2 units (one step = 1/256), exp by a 16-entry table + shift")

    print(f"\n3) The integer model (bit-exact with the chip) on {len(xte)} test images:")
    xq = chipnet.input_int8(xte, in_scale)
    results = [chipnet.golden(layers, q, table, xq[i]) for i in range(len(xq))]
    int_pred = np.array([int(np.argmax(r[1])) for r in results])
    int_acc = (int_pred == yte)[known].mean() if known.any() else 0.0
    print(f"   float accuracy {float_acc * 100:.2f}%,  integer (chip) accuracy {int_acc * 100:.2f}%,  "
          f"same prediction as float on {(int_pred == float_pred).mean() * 100:.1f}% of the images")

    print("\n4) Compiling for the chip:")
    mem, entries = build(layers, q, table, xq.shape[1], xq.shape[2], xq.shape[3])
    for li, e in enumerate(entries):
        bands = (f", {e['bands']} bands of {e['rows']} rows" if e["rows"] else "")
        print(f"   layer {li}: table entry at {e['addr']} ({e['words']} words, program {e['prog']} instructions{bands}), "
              f"weights at {e['wgt']} ({e['wgt_words']} words), input {e['in_hw'][0]}x{e['in_hw'][1]} -> "
              f"stored {e['out'][0]}x{e['out'][1]}x{e['out'][2]}")
    lay = _MEM_CACHE["layout"]
    if lay["maps_end"] > lay["maps"]:
        print(f"   feature maps kept in external memory: words {lay['maps']}..{lay['maps_end'] - 1}")
    n = write_files(outdir, layers, entries, xq, yte, results, float_acc, int_acc, n_rtl)
    print(f"   wrote {len(mem)} words of weights and table ({lay['entries']} table entries), and {n} test images "
          f"for the RTL, to {outdir}; external memory used: {lay['mem_words']} words")
    return float_acc, int_acc
