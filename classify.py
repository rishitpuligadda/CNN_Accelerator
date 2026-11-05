#!/usr/bin/env python3
"""Classify your own photos on the chip, in one command (run it from the project's main directory).

    python3 classify.py --model python/cifar_cnn.keras --data python/cifar10.npz --classes cifar10 \\
                        cat.jpg:cat truck.jpg:truck dog.png

    --model    a trained Keras model (.keras / .h5), or an export made by keras_export.py (.npz)
    --data     the dataset the model was trained on (.npz with x_train, y_train, x_test, y_test):
               its training images calibrate the int8 scales
    --classes  class names: cifar10, mnist, fashion, or your own list "cat,dog,..." (optional)
    photos     image files (jpg, png, ...), each optionally with its true label: photo.jpg:cat or photo.jpg:3
    --macro    simulate with the sky130 SRAM models;  --invert yes/no/auto: grayscale photos with a light
               background are inverted (MNIST digits are white on black; default auto);  --verbose: full logs

Steps: export the model (TensorFlow, only when the model changed) -> prepare the photos for the model's
input -> convert, quantize, compile -> run the chip in simulation -> compare with the golden model.
"""
import argparse
import json
import os
import subprocess
import sys
import numpy as np

ROOT = os.path.dirname(os.path.abspath(__file__))
PY, SIM, BUILD = os.path.join(ROOT, "python"), os.path.join(ROOT, "simulation"), os.path.join(ROOT, "build")

PRESETS = {
    "cifar10": "airplane,automobile,bird,cat,deer,dog,frog,horse,ship,truck",
    "mnist":   "0,1,2,3,4,5,6,7,8,9",
    "fashion": "t-shirt,trouser,pullover,dress,coat,sandal,shirt,sneaker,bag,ankle-boot",
}


def step(msg):
    print(f"\n=== {msg}", flush=True)


def run(cmd, cwd, log, env=None, show_from=None, verbose=False):
    """Run a command; keep its full output in a log file; print it (or only from the line containing show_from)."""
    p = subprocess.run(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    with open(log, "w") as f:
        f.write(p.stdout)
    lines = p.stdout.splitlines()
    if not verbose and show_from is not None:
        start = next((i for i, l in enumerate(lines) if show_from in l), None)
        lines = lines[start:] if start is not None else lines[-25:]
    lines = [l for l in lines if not l.startswith("- ") or verbose]          # Verilator's report lines
    print("\n".join(lines))
    if p.returncode != 0:
        sys.exit(f"\nthat step failed (exit {p.returncode}); full output in {log}")


def parse_photos(args, names):
    out = []
    for a in args:
        path, sep, lab = a.rpartition(":")
        if not sep or not path or os.path.sep in lab or "." in lab:          # no label given ("photo.jpg")
            path, lab = a, ""
        lab = lab.strip()
        if lab == "":
            label = -1
        elif lab.isdigit():
            label = int(lab)
        elif names and lab.lower() in [n.lower() for n in names]:
            label = [n.lower() for n in names].index(lab.lower())
        else:
            sys.exit(f"'{a}': unknown label '{lab}'" + (f" (classes: {', '.join(names)})" if names else
                                                        " - give --classes to use names, or a class number"))
        if not os.path.isfile(path):
            sys.exit(f"'{path}': no such image file")
        out.append((path, label))
    return out


def prepare(photos, shape, invert):
    """Each photo -> the model's input: centre crop to a square, resize, RGB or grayscale, raw 0..255."""
    from PIL import Image, ImageOps
    h, w, c = shape
    imgs = []
    for path, _ in photos:
        img = ImageOps.exif_transpose(Image.open(path)).convert("RGB" if c == 3 else "L")
        side = min(img.size)
        img = ImageOps.fit(img, (side, side), method=Image.Resampling.LANCZOS)
        img = img.resize((w, h), Image.Resampling.LANCZOS)
        a = np.array(img, dtype=np.uint8).reshape(h, w, c)
        if c == 1:
            border = np.concatenate([a[0], a[-1], a[:, 0], a[:, -1]]).mean()
            if invert == "yes" or (invert == "auto" and border > 127):
                a = 255 - a                                          # dark digit on light paper -> MNIST style
                print(f"  {path}: light background, inverted to look like the training images")
        imgs.append(a)
    return np.stack(imgs)


def main():
    ap = argparse.ArgumentParser(description="Classify your own photos on the chip.",
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("--model", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--classes", default=None)
    ap.add_argument("--macro", action="store_true")
    ap.add_argument("--invert", choices=["yes", "no", "auto"], default="auto")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("photos", nargs="+")
    a = ap.parse_args()
    os.makedirs(BUILD, exist_ok=True)
    model, data = os.path.abspath(a.model), os.path.abspath(a.data)
    for f in (model, data):
        if not os.path.isfile(f):
            sys.exit(f"'{f}': file not found")
    names = PRESETS.get(a.classes, a.classes).split(",") if a.classes else None
    photos = parse_photos(a.photos, names)

    # 1. export the Keras model (needs TensorFlow), unless it is already an export or the export is up to date
    if model.endswith(".npz"):
        export = model
        step(f"1/5 using the export {os.path.relpath(export, ROOT)}")
    else:
        export = os.path.join(BUILD, os.path.splitext(os.path.basename(model))[0] + "_export.npz")
        if os.path.isfile(export) and os.path.getmtime(export) > max(os.path.getmtime(model), os.path.getmtime(data)):
            step(f"1/5 the model has not changed since its last export ({os.path.relpath(export, ROOT)})")
        else:
            step("1/5 exporting the Keras model (TensorFlow)")
            run([sys.executable, os.path.join(PY, "keras_export.py"), model, data, export], PY,
                os.path.join(BUILD, "export.log"), show_from="wrote ", verbose=a.verbose)

    # 2. the photos, prepared for the model's input
    meta = json.loads(str(np.load(export, allow_pickle=True)["meta"]))
    shape = meta["input_shape"]
    step(f"2/5 preparing {len(photos)} photo(s) for the model's {shape[0]}x{shape[1]}x{shape[2]} input")
    x = prepare(photos, shape, a.invert)
    with np.load(data) as d:
        xtr, ytr = d["x_train"], d["y_train"].ravel()
    labels = np.array([lab for _, lab in photos], dtype=np.int64)
    photo_npz = os.path.join(BUILD, "photos.npz")
    np.savez(photo_npz, x_train=xtr, y_train=ytr, x_test=x, y_test=labels)
    for (path, lab) in photos:
        print(f"  {path}: label {('?' if lab < 0 else (names[lab] if names and lab < len(names) else lab))}")

    # 3. convert, quantize, compile
    step("3/5 converting, quantizing and compiling for the chip")
    run([sys.executable, "keras_flow.py", export, photo_npz, os.path.join(SIM, "model"), str(len(photos))], PY,
        os.path.join(BUILD, "flow.log"), verbose=True)

    # 4 + 5. the chip in simulation, then the comparison with the golden model
    step("4/5 running the chip (RTL simulation)   5/5 checking its results")
    env = dict(os.environ)
    env["CHECK"] = (f"--names={','.join(names)}" if names else "") + " --all"
    run(["bash", "run_model.sh"] + (["macro"] if a.macro else []), SIM, os.path.join(BUILD, "chip.log"),
        env=env, show_from="Running ", verbose=a.verbose)
    print(f"\nlogs: {os.path.relpath(BUILD, ROOT)}/   chip results: simulation/outputs/chip_results.hex, model_results.txt")


if __name__ == "__main__":
    main()
