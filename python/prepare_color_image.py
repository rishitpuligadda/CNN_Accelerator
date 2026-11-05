"""Prepare your own photos for the CIFAR-10 model on the chip.

    python3 prepare_color_image.py cat.jpg:cat truck.jpeg:truck dog.png:5

Each argument is <image file>:<label>; the label is a CIFAR-10 class name or its number (0-9).
Writes my_photos.npz: your photos as the test images (raw 0..255, like cifar10.npz) with their labels,
and CIFAR-10's training images for calibration.
"""
import sys
import numpy as np
from PIL import Image, ImageOps

CLASSES = ["airplane", "automobile", "bird", "cat", "deer", "dog", "frog", "horse", "ship", "truck"]

if len(sys.argv) < 2:
    sys.exit("usage: python3 prepare_color_image.py <photo>:<label> [<photo>:<label> ...]\n"
             f"labels: a number 0-9 or one of {', '.join(CLASSES)}")

photos, labels = [], []
for arg in sys.argv[1:]:
    path, sep, lab = arg.rpartition(':')
    if not sep or not path:
        sys.exit(f"'{arg}': give a label after the file name, e.g. {arg}:cat")
    lab = lab.strip().lower()
    if lab.isdigit() and int(lab) < len(CLASSES):
        label = int(lab)
    elif lab in CLASSES:
        label = CLASSES.index(lab)
    else:
        sys.exit(f"'{arg}': unknown label '{lab}' (use 0-9 or one of {', '.join(CLASSES)})")

    img = Image.open(path)
    img = ImageOps.exif_transpose(img).convert('RGB')                         # phone rotation, then RGB
    side = min(img.size)
    img = ImageOps.fit(img, (side, side), method=Image.Resampling.LANCZOS)   # centre crop to a square
    img = img.resize((32, 32), Image.Resampling.LANCZOS)
    photos.append(np.array(img, dtype=np.uint8))                              # raw 0..255, like CIFAR-10
    labels.append(label)
    print(f"  {path}: label {label} ({CLASSES[label]})")

with np.load('cifar10.npz') as f:          # calibration stays on CIFAR-10's training images
    x_train, y_train = f['x_train'], f['y_train']

np.savez('my_photos.npz', x_train=x_train, y_train=y_train,
         x_test=np.stack(photos), y_test=np.array(labels, dtype=np.int64))
print(f"{len(photos)} photo(s) -> my_photos.npz")
