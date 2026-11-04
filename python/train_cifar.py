import ssl
ssl._create_default_https_context = ssl._create_unverified_context

import numpy as np
import tensorflow as tf
from tensorflow.keras import layers, models

# 1. Load and format CIFAR-10
(x_tr, y_tr), (x_te, y_te) = tf.keras.datasets.cifar10.load_data()

# Flatten labels from (N, 1) column arrays to flat lists for the export flow
y_tr_flat = y_tr.ravel()
y_te_flat = y_te.ravel()

# Save the raw dataset for the chip export flow
np.savez('cifar10.npz', x_train=x_tr, y_train=y_tr_flat, x_test=x_te, y_test=y_te_flat)

# Scale inputs (strict / 255.0 to maintain baseline quantization compatibility)
train_images = x_tr.astype('float32') / 255.0
test_images = x_te.astype('float32') / 255.0

# 2. Build the hardware-constrained color model
model = models.Sequential([
    # Input: 32x32x3. Output: 30x30x24 -> Pooled: 15x15x24 (fits 6KB SRAM)
    layers.Conv2D(24, (3, 3), activation='relu', input_shape=(32, 32, 3)),   
    layers.MaxPooling2D((2, 2)),
    
    # Output: 13x13x48 -> Pooled: 6x6x48
    layers.Conv2D(48, (3, 3), activation='relu'),                            
    layers.MaxPooling2D((2, 2)),
    
    # Output: 4x4x56 (4*4*56 = 896 weights, safely under the 1020 limit)
    layers.Conv2D(56, (3, 3), activation='relu'),                            
    layers.Flatten(),
    
    # Classification head
    layers.Dense(64, activation='relu'),                                     
    layers.Dense(10, activation='softmax')
])

model.compile(optimizer='adam',
              loss=tf.keras.losses.SparseCategoricalCrossentropy(),
              metrics=['accuracy'])

print("Training CIFAR-10 model constrained to hardware limits...")
model.fit(train_images, y_tr_flat, epochs=15, validation_data=(test_images, y_te_flat))
model.save('cifar_cnn.keras')
print("Saved cifar_cnn.keras and cifar10.npz")
