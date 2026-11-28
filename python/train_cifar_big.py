"""A bigger CIFAR-10 CNN (about 290,000 weights, 9 chip layers) whose early feature maps do NOT fit the chip's
6 KB buffers: the compiler runs those layers in bands of rows through external memory.

    python3 train_cifar_big.py [epochs, default 30]          (needs TensorFlow; writes cifar_big.keras)

Layers (on the chip; "bands" = processed in bands through external memory):
    32x32x3  -> conv 3x3 'same' 32         -> 32x32x32    bands
             -> conv 3x3 'same' 32 + pool  -> 16x16x32    bands
             -> conv 3x3 'same' 64         -> 16x16x64    bands
             -> conv 3x3 'same' 64 + pool  ->  8x8x64     bands
             -> conv 3x3 'same' 96         ->  8x8x96     bands
             -> conv 3x3 'same' 96 + pool  ->  4x4x96     bands
             -> conv 3x3 'valid' 64        ->  2x2x64     on chip
             -> Flatten (256) -> Dense 128 -> Dense 10 softmax
Every convolution is Conv2D (no activation) -> BatchNormalization -> ReLU: the flow folds the BatchNorm into the
convolution. Data augmentation (flips, shifts) runs in the input pipeline, not as layers, so the saved model
contains only layers the chip supports.
"""
import ssl
import sys
import os
ssl._create_default_https_context = ssl._create_unverified_context

import numpy as np
import tensorflow as tf
from tensorflow.keras import layers, models

EPOCHS = int(sys.argv[1]) if len(sys.argv) > 1 else 30

# the dataset file the chip flow uses (raw uint8 pixels, integer labels)
if os.path.isfile("cifar10.npz"):
    d = np.load("cifar10.npz")
    x_tr, y_tr, x_te, y_te = d["x_train"], d["y_train"].ravel(), d["x_test"], d["y_test"].ravel()
else:
    (x_tr, y_tr), (x_te, y_te) = tf.keras.datasets.cifar10.load_data()
    y_tr, y_te = y_tr.ravel(), y_te.ravel()
    np.savez("cifar10.npz", x_train=x_tr, y_train=y_tr, x_test=x_te, y_test=y_te)


def block(m, filters, pool=False, padding="same"):
    m.add(layers.Conv2D(filters, 3, padding=padding, use_bias=True))
    m.add(layers.BatchNormalization())
    m.add(layers.ReLU())
    if pool:
        m.add(layers.MaxPooling2D(2))


model = models.Sequential([layers.Input((32, 32, 3))])
block(model, 32)
block(model, 32, pool=True)
block(model, 64)
block(model, 64, pool=True)
block(model, 96)
block(model, 96, pool=True)
block(model, 64, padding="valid")
model.add(layers.Flatten())
model.add(layers.Dropout(0.3))
model.add(layers.Dense(128, activation="relu"))
model.add(layers.Dense(10, activation="softmax"))
model.summary()


def augment(x, y):
    x = tf.image.random_flip_left_right(x)
    x = tf.image.resize_with_crop_or_pad(x, 36, 36)          # shift by up to 2 pixels
    x = tf.image.random_crop(x, (32, 32, 3))
    return x, y


train = (tf.data.Dataset.from_tensor_slices((x_tr.astype("float32") / 255.0, y_tr))
         .shuffle(10000).map(augment, num_parallel_calls=tf.data.AUTOTUNE).batch(128).prefetch(2))
test = tf.data.Dataset.from_tensor_slices((x_te.astype("float32") / 255.0, y_te)).batch(256)

steps = EPOCHS * ((len(x_tr) + 127) // 128)
lr = tf.keras.optimizers.schedules.CosineDecay(2e-3, steps)
model.compile(optimizer=tf.keras.optimizers.Adam(lr), loss="sparse_categorical_crossentropy", metrics=["accuracy"])
model.fit(train, epochs=EPOCHS, validation_data=test)
model.save("cifar_big.keras")
print(f"Saved cifar_big.keras (test accuracy {model.evaluate(test, verbose=0)[1] * 100:.2f}%) and cifar10.npz")
