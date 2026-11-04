"""Export a trained Keras model for the chip flow. Run this where TensorFlow is installed:

    python3 keras_export.py mnist_cnn.keras mnist.npz mnist_cnn_export.npz

It writes a plain .npz (no TensorFlow needed afterwards) with every layer's type, settings and weights,
and Keras's own predictions for the first 500 test images, so keras_flow.py can verify its conversion.
"""
import json
import sys
import numpy as np
import tensorflow as tf

KEEP = ["filters", "kernel_size", "strides", "padding", "activation", "use_bias", "dilation_rate", "data_format",
        "pool_size", "units", "epsilon", "axis", "rate", "groups"]


def main(model_path, mnist_path, out_path):
    model = tf.keras.models.load_model(model_path)
    model.summary()
    meta = []
    arrays = {}
    for i, layer in enumerate(model.layers):
        cfg = layer.get_config()
        entry = {"class": layer.__class__.__name__,
                 "config": {k: cfg[k] for k in KEEP if k in cfg}}
        if entry["class"] == "Activation":
            entry["config"]["activation"] = cfg.get("activation")
        for j, wt in enumerate(layer.get_weights()):
            arrays[f"w{i}_{j}"] = wt
        entry["n_weights"] = len(layer.get_weights())
        meta.append(entry)
    with np.load(mnist_path, allow_pickle=True) as f:
        x_test = f["x_test"][:500]
    x = x_test.reshape((-1,) + tuple(model.input_shape[1:])).astype(np.float32) / 255.0
    preds = model.predict(x, verbose=0)
    arrays["keras_preds"] = preds
    arrays["meta"] = np.array(json.dumps({"layers": meta, "input_shape": list(model.input_shape[1:]),
                                          "input_scale": 255.0}))
    np.savez(out_path, **arrays)
    print(f"wrote {out_path}: {len(meta)} layers, Keras predictions for {len(preds)} test images")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: python3 keras_export.py <model.keras> <mnist.npz> <export.npz>")
    main(*sys.argv[1:])
