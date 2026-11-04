"""Compile a quantized network into what the chip reads from external memory.

Memory map (32-bit words):  0 input image | 4096 weights | 49152 layer table | 57344 result (written by the chip)
Files written:
  model_mem.hex   weights and layer table ($readmemh with @address markers)
  images.hex      the test images, IMG_WORDS words each (guard word + planar rows padded to 4 bytes)
  expected.hex    per image: 10 output bytes (probability x 128), the label, the golden prediction
  expmaps.hex     per image: every layer's stored int8 map, one byte per line, in (channel, row, column) order
"""
import numpy as np
from model import LAYERS

IMG_EB, WGT_EB, TBL_EB, WB_EB = 0, 4096, 49152, 57344


def venc(op, pr, d, a, b, x):
    return (op << 26) | (pr << 23) | (d << 19) | (a << 15) | (b << 11) | (x & 0x7FF)


def LI(d, v):
    if not -262144 <= v <= 262143:
        raise ValueError(f"LI immediate {v} does not fit 19 bits")
    return (0x01 << 26) | (d << 19) | (v & 0x7FFFF)


def program(L, ql, out_h, out_w):
    """Vector-unit program for one layer, returning (words, sections) like the RTL tests build them."""
    p = []
    mode = 4 if L["kind"] == "fc" else (2 if L["pool"] else 1)
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
        p += [LI(4, 0), venc(0x0A, 0, 2, 3, 4, 0),             # c2 = -128..0
              LI(3, 0), LI(4, 127), venc(0x0A, 0, 1, 3, 4, 0), # c1 = 0..127
              venc(0x11, 0, 6, 0, 0xF, 0x780),                 # VLI v6, -128
              venc(0x11, 0, 5, 0, 0, 0),                       # VLI v5, 0
              LI(10, 1), LI(11, 1)]
    s_pro = len(p)
    body = len(p)
    p.append(venc(0x21, 0, 0, 7, 0, 0))                        # REQ v0, v7, q0
    if mode == 1:
        p.append(venc(0x38, 0, 0, 0, 0, 0))                    # ST8 v0, c0
    if mode == 2:
        p += [venc(0x22, 0, 0, 0, 0, 0),                       # CLAMP v0, v0, c0
              venc(0x30, 0, 1, 0, 0, 0),                       # MAXP v1, v0
              venc(0x08, 0, 6, 0, 0, 8),                       # TAG s6, lmidx
              venc(0x3C, 2, 0, 1, 6, 0),                       # [p2] STS v1, s6
              venc(0x3B, 3, 2, 6, 0, 0),                       # [p3] LDS v2, s6
              venc(0x1B, 3, 1, 1, 2, 0),                       # [p3] MAX v1, v1, v2
              venc(0x34, 0, 1, 1, 0, 0b01000100),              # PERM v1, v1: lanes 0,1 -> 2,3
              venc(0x08, 0, 9, 0, 0, 6),                       # TAG s9, paddr
              venc(0x08, 0, 5, 0, 0, 7),                       # TAG s5, pbe
              venc(0x39, 3, 5, 1, 9, 0)]                       # [p3] ST8A v1, s9, s5, c0
    if mode == 4:
        p += [venc(0x22, 0, 0, 0, 0, 0),                       # CLAMP v0, v0, c0
              venc(0x08, 0, 1, 0, 0, 4),                       # TAG s1, chan
              venc(0x3C, 0, 0, 0, 1, 0),                       # STS v0, s1
              venc(0x1B, 0, 6, 6, 0, 0)]                       # MAX v6, v6, v0
    e0 = len(p)
    if mode == 4:
        p += [venc(0x08, 0, 1, 0, 0, 9), venc(0x3B, 0, 1, 1, 0, 0),    # TAG s1, iter;  LDS v1, s1
              venc(0x19, 0, 1, 1, 6, 0), venc(0x22, 0, 1, 1, 0, 2),    # SUB v1, v1, v6; CLAMP c2
              venc(0x23, 0, 1, 1, 0, 0), venc(0x3C, 0, 0, 1, 1, 0),    # LUT v1, v1;     STS v1, s1
              venc(0x18, 0, 5, 5, 1, 0)]                               # ADD v5, v5, v1
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


def check_limits(L, h, w):
    if L["k"] > 7:
        raise ValueError("kernels are at most 7x7 (the map before an FC layer must be at most 7x7)")
    if L["cin"] * L["k"] * L["k"] > 1020:
        raise ValueError("channels x kernel x kernel must be at most 1020")
    if L["cout"] > 255:
        raise ValueError("at most 255 filters")


def compile_network(q, table, in_h=8, in_w=8):
    mem = {}
    entries = []
    wptr, tptr = WGT_EB, TBL_EB
    h, w = in_h, in_w
    n = len(LAYERS)
    for li, (L, ql) in enumerate(zip(LAYERS, q)):
        check_limits(L, h, w)
        oh, ow = h + 2 * L["pad"] - L["k"] + 1, w + 2 * L["pad"] - L["k"] + 1
        sh, sw = (oh // 2, ow // 2) if L["pool"] else (oh, ow)
        # weights: per group of 4 filters, 4 bias words, then M words {w3[k], w2[k], w1[k], w0[k]}
        wq = ql["wq"].reshape(L["cout"], -1)
        m = wq.shape[1]
        waddr = wptr
        for g in range((L["cout"] + 3) // 4):
            for j in range(4):
                f = 4 * g + j
                mem[wptr + j] = int(ql["bq"][f]) & 0xFFFFFFFF if f < L["cout"] else 0
            for k in range(m):
                word = 0
                for j in range(4):
                    f = 4 * g + j
                    if f < L["cout"]:
                        word |= (int(wq[f, k]) & 0xFF) << (8 * j)
                mem[wptr + 4 + k] = word
            wptr += m + 4
        prog, sects, mode = program(L, ql, sh, sw)
        nlut = 256 if mode == 4 else 0
        last = li == n - 1
        wb_words = 1 + L["cout"] * sh * ((sw + 3) // 4)
        hdr = [
            (L["cout"] << 24) | (L["cin"] << 16) | (w << 8) | h,
            (int(last) << 18) | (int(last) << 17) | (int(li == 0) << 16) | ((1 if L["pool"] else 0) << 12)
            | (1 << 9) | (L["pad"] << 6) | (L["k"] << 3) | L["k"],
            (1 << 16) | waddr,
            (WB_EB << 16) | IMG_EB,
            (wb_words << 12),
            (nlut << 8) | len(prog),
        ] + [(c << 13) | (ln << 6) | st for st, ln, c in sects]
        words = hdr + prog + [int(table[2 * i]) | (int(table[2 * i + 1]) << 16) for i in range(nlut // 2)]
        for i, wd in enumerate(words):
            mem[tptr + i] = wd & 0xFFFFFFFF
        entries.append(dict(addr=tptr, words=len(words), prog=len(prog), mode=mode, in_hw=(h, w),
                            out=(sh, sw, L["cout"]), wgt=waddr, wgt_words=wptr - waddr))
        tptr += len(words)
        h, w = sh, sw
    if wptr > TBL_EB or tptr > WB_EB:
        raise ValueError("weights or table do not fit the memory map")
    return mem, entries


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
