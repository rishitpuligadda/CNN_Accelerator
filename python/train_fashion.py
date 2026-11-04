import ssl
ssl._create_default_https_context = ssl._create_unverified_context

import numpy as np
import tensorflow as tf
from tensorflow.keras import layers, models

# 1. Load Fashion MNIST
(train_images, train_labels), (test_images, test_labels) = tf.keras.datasets.fashion_mnist.load_data()

# 2. Save the raw dataset to .npz for your export script
np.savez('fashion_mnist.npz', 
         x_train=train_images, y_train=train_labels, 
         x_test=test_images, y_test=test_labels)

# 3. Reshape to 28x28x1 and normalize
train_images = train_images.reshape((60000, 28, 28, 1)) / 255.0
test_images = test_images.reshape((10000, 28, 28, 1)) / 255.0

# 4. Build the model (using your exact 24-filter hardware constraint)
model = models.Sequential([
    layers.Conv2D(24, (3, 3), activation='relu', input_shape=(28, 28, 1)),
    layers.MaxPooling2D((2, 2)),
    layers.Conv2D(64, (3, 3), activation='relu'),
    layers.MaxPooling2D((2, 2)),
    layers.Conv2D(64, (3, 3), activation='relu'),
    layers.Flatten(),
    layers.Dense(64, activation='relu'),
    layers.Dense(10, activation='softmax')
])

model.compile(optimizer='adam',
              loss=tf.keras.losses.SparseCategoricalCrossentropy(),
              metrics=['accuracy'])

model.fit(train_images, train_labels, epochs=5, validation_data=(test_images, test_labels))
model.save('fashion_cnn.keras')
print("Successfully saved fashion_cnn.keras and fashion_mnist.npz")
