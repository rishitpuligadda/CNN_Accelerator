import sys
import numpy as np
from PIL import Image, ImageOps

if len(sys.argv) < 2:
    print("Usage: python3 prepare_color_image.py <image.jpg>")
    sys.exit(1)

img_path = sys.argv[1]

# 1. Load image in full RGB color
img = Image.open(img_path).convert('RGB')

# 2. Center crop it into a perfect square to avoid stretching the aspect ratio
# (Finds the shortest edge and crops the center)
min_edge = min(img.size)
img = ImageOps.fit(img, (min_edge, min_edge), method=Image.Resampling.LANCZOS)

# 3. Resize to the exact 32x32 chip requirement
img = img.resize((32, 32), Image.Resampling.LANCZOS)

# 4. Convert to array, scale to 0-1, reshape to (1, 32, 32, 3)
img_array = np.array(img, dtype=np.float32) / 255.0
x_test = img_array.reshape((1, 32, 32, 3))
y_test = np.array([0]) # Dummy label

# 5. Save to NPZ
out_name = 'my_color_photo.npz'
np.savez(out_name, x_train=x_test, y_train=y_test, x_test=x_test, y_test=y_test)
print(f"Processed {img_path} into CIFAR-10 RGB format -> {out_name}")
