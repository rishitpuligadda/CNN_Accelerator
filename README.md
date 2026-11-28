# CNN Accelerator

**by Shivani and Rishit**

An int8 convolutional-neural-network accelerator chip, written in Verilog for an open-source 130 nm process.
A trained Keras model is compiled into a table of layers in external memory; the chip runs the whole network
from a single `start` - convolutions, fully connected layers, requantization, activations, pooling and softmax -
and writes the result back to memory.

> 📷 *Architecture overview - figure to be added (`docs/images/architecture.png`)*

---

## Contents

1. [Highlights](#highlights)
2. [Results on trained models](#results-on-trained-models)
3. [Hardware architecture](#hardware-architecture)
   - [Part 1 - The systolic array](#part-1--the-systolic-array)
   - [Part 2 - The vector unit](#part-2--the-vector-unit)
   - [Part 3 - Data movement and control around them](#part-3--data-movement-and-control-around-them)
   - [Top-level integration: running a whole network](#top-level-integration-running-a-whole-network)
4. [Software flow: from a Keras model to the chip](#software-flow-from-a-keras-model-to-the-chip)
5. [What a model may contain](#what-a-model-may-contain)
6. [Run your own model, step by step](#run-your-own-model-step-by-step)
7. [How to run](#how-to-run)
8. [Example output, explained](#example-output-explained)
9. [Verification](#verification)
10. [Repository layout](#repository-layout)
11. [Status and next steps](#status-and-next-steps)

---

## Highlights

| | |
|---|---|
| Arithmetic | int8 activations and weights, 32-bit accumulation, int32 biases |
| Compute | 4 x 4 output-stationary systolic array (16 multiply-accumulates per cycle) |
| Post-processing | a programmable 4-lane SIMD vector unit: requantization, ReLU / Leaky ReLU / ReLU6, max and average pooling, global average pooling, argmax, softmax with 16-bit logits |
| On-chip memory | 20 KB in 12 SRAM macros: two 6 KB feature buffers (ping-pong), a 4 KB weight buffer and the vector unit's 4 KB local memory; plus the vector unit's 32-byte lookup table and 256-byte program memory in flip-flops |
| Off-chip | weights, layer table and input image in external memory; weights stream in filter group by filter group |
| Control | a layer sequencer reads the network from a layer table - one `start` runs the whole model |
| Interface | `start`, table address, `busy` / `done` / `err`, and a valid/ready memory read and write channel |
| Toolchain | Python: Keras export, conversion, int8 quantization, bit-exact golden model, compiler, result checker |

## Results on trained models

Every row: the trained float model, its int8 version (computed exactly as the chip computes it), and the chip in
RTL simulation, which matched the int8 model **bit for bit on every layer of every image**.

| Model | Data | Float accuracy | int8 accuracy | Chip (RTL) |
|---|---|---|---|---|
| CNN, 3 layers | 8x8 handwritten digits (scikit-learn) | 98.33 % | 98.33 % | bit-exact, 354 / 360 |
| CNN, 5 layers (conv-pool, conv-pool, conv, dense, dense) | MNIST | 98.99 % | 99.00 % | bit-exact |
| same architecture | Fashion-MNIST | 90.05 % | 90.03 % | bit-exact |
| colour CNN, 5 layers | CIFAR-10 | 69.44 % | 69.45 % | bit-exact |
| the CIFAR-10 CNN | our own photos (cat, truck, airplanes, frogs) | - | - | bit-exact, 4 / 6 correct |

Quantization to int8 cost at most 0.02 percentage points on these models.

---

## Hardware architecture

The design has three parts - the systolic array, the vector unit, and the data movement and control around them -
joined by a top-level integration that runs a whole network.

> 📷 *Block diagram of the chip - figure to be added (`docs/images/block_diagram.png`)*

```
            external memory (layer table, weights, image, result)
                 |  read channel                   ^ write channel
                 v                                 |
   layer sequencer --> layer config --> layer controller ------------+
                 |                         |                         |
                 v                         v                         |
               DMA ----> feature buffer A/B ---> activation feeder   |
                 |                                    |              |
                 +-----> weight buffer ---> weight feeder            |
                                                      v              |
                                   skew buffers -> 4x4 systolic array |
                                                      |              |
                                   result collector -> packet FIFO (credits)
                                                      |
                                                vector unit ---> feature buffer B/A ---> write-back
```

### Part 1 - The systolic array

> 📷 *Systolic array and processing element - figure to be added (`docs/images/systolic_array.png`)*

**Processing element** (`Processing_Element.v`). Each PE multiplies an int8 activation by an int8 weight and adds
the product to a 32-bit accumulator: `acc <= (first ? bias : acc) + product`. The bias is loaded into the
accumulator with the first product of each output, so no separate addition is needed. A `last` flag marks the
final product, after which the result leaves the PE.

**The array** (`systolic_array.v`). 4 x 4 PEs, **output stationary**: each PE computes one output value
(one of 4 output pixels x one of 4 filters) while activations flow left to right and weights flow top to bottom.
The `first`/`last` flags travel with the data, and each column streams its 4 results out one row after the other,
so a new tile can start while the previous one drains.

**Feeding it.**
- `act_feeder.v` builds the convolution's input on the fly (im2col without storing it): for each output tile it
  walks the kernel window over the input channels, applying padding (0-3) and stride (1-4), and reads the
  feature buffer with a registered output stage that matches the SRAM macros' timing.
- `wgt_feeder.v` streams the weights of the current group of 4 filters, slaved to the activation feeder.
- `skew_buffer.v` delays lane *i* by *i* cycles, giving the diagonal wavefront a systolic array needs.

Every convolution - any kernel up to 7 x 7 (also non-square), any number of channels and filters - and every fully
connected layer (a convolution whose kernel covers the whole input map) runs on this array.

### Part 2 - The vector unit

> 📷 *Vector unit pipeline - figure to be added (`docs/images/vector_unit.png`)*

The vector unit (`vector_unit.v`, `vu_lane.v`, `vu_regs.v`) is a small programmable SIMD processor that turns the
array's 32-bit accumulators into the int8 feature map of the next layer. Its full instruction set is in
`vector_isa.md`.

**Machine.**
- **4 lanes** of 32 bits - one packet from the array is one vector (4 output pixels of one channel).
- **Registers:** 7 vector registers plus `v7`, the current packet (read-only); 16 scalar registers; a lane mask;
  4 requantization sets (M for positive values, M for negative values, shift S); 4 clamp sets.
- **Program memory:** 64 instructions, organized in **sections**: a prologue (before the first packet), a body
  (run for every packet) and up to four epilogues (after the last packet). The prologue and the epilogues can
  **repeat** with a counter (`TAG iter`), so programs loop over values kept in local memory - with no branch
  instructions and no loop overhead.
- **Interlocks** handle the 2-cycle instructions (multiply, requantize, local-memory loads) - no NOPs needed.

**What it computes** (about 45 instructions, each verified against an instruction-set interpreter):
- **Requantization** `REQ`: `y = acc x M / 2^S`, rounded half up and saturated - with a separate multiplier for
  negative values, which gives ReLU (M_neg = 0) and Leaky ReLU for free; `CLAMP` gives ReLU6 and int8 saturation.
- **Lane arithmetic:** add, subtract, min, max, shifts with rounding (also by a different amount in each lane,
  `SHRRV`), multiply, compare, select.
- **Predication:** every instruction can be limited to lanes of a mask, or to packets matching up to six
  predicates on their row, column, channel, address or byte mask.
- **Across lanes:** `MAXP`/`ADDP` (pairs), `PERM`/`PERMS` (permutations), `RMAX`/`RADD` (reductions to a scalar).
- **Address unit:** computes where a pooled value belongs (`paddr`, `pbe`, `lmidx`) from the packet's tags.
- **Local memory:** 4 KB (256 entries of 128 bits), built from four 1 KB SRAM macros, one per lane (flip-flops in
  the default simulation). It holds values that span packets: the even row's partial
  maxima during 2 x 2 pooling, the logits during softmax, and per-channel sums for global average pooling.
- **Lookup table** (16 x 16 bits), indexed by the low 4 bits of each lane; softmax keeps 2^(-k/16) in it.
- **`RCP`**, a reciprocal unit (2^n / x), for softmax's division.

**Programs** (generated by the compiler): requantize + ReLU in 2 instructions per packet; 2 x 2 and 4 x 4 max pooling
and 2 x 2 average pooling fused into the convolution (~13 cycles per packet); global average pooling; argmax;
softmax over up to 256 classes (within 0.008 of a float softmax, i.e. one output step).

**How softmax computes exp.** The compiler scales the last layer so that its logits come out in base 2 with 8
fraction bits, as 16-bit values (`y = z x log2(e) x 256`; the factor log2(e) costs nothing, it is folded into the
layer's M / 2^S). Then e^(z - z_max) = 2^(-m/256) with `m = max - y`, and the program splits m into three parts:

```
2^(-m/256) = 2^-(m >> 8)            the integer part: a right shift (SHRRV, a different amount in each lane)
           x 2^(-((m >> 4) & 15)/16) the next 4 bits: the 16-entry table (Q14)
           x 2^(-(m & 15)/256)       the last 4 bits: 1 - (m & 15) x ln2/256, one multiply (error below 0.1%)
```

Sum, one `RCP` for 2^30 / sum, and a multiply per class give the probabilities (x 128). Other activations such as
sigmoid (1 / (1 + e^-x)) can be built the same way from these instructions.

### Part 3 - Data movement and control around them

> 📷 *Data flow through the memories - figure to be added (`docs/images/dataflow.png`)*

**Memories.**
- `ram_1rw1r.v` - a wrapper around the sky130 SRAM macro `sky130_sram_2kbyte_1rw1r_32x512_8` (2 KB, one read/write
  port and one read port). It banks several macros into a larger memory and has a behavioural model for fast
  simulation; both are tested against each other.
- **Feature buffers A and B**: 6 KB each (3 macros). One holds the layer's input, the other receives its output.
- **Weight buffer**: 4 KB (2 macros), double-buffered: the next filter group loads while the current one computes.

**Moving data.**
- `dma.v` reads external memory over a valid/ready channel (word addresses, any latency) into the buffers: the
  input image for the first layer, and each layer's weights and biases filter group by filter group - so only two
  groups of weights are ever on the chip, however large the model.

**Control.**
- `layer_config.v` takes a layer's raw shape (input size, channels, filters, kernel, padding, stride, pooling),
  derives every address and pitch the controller needs, and **rejects invalid layers** with an error code
  (bad kernel, stride or padding, weights or maps too large for the buffers, and more).
- `layer_controller.v` walks the output in tiles of 4 pixels x 4 filters, loads biases and weights, drives the
  feeders, and keeps the array busy - including the spacing rules that keep consecutive tiles from colliding.
- `result_collector.v` gathers each column's 4 results into a **packet** with its output address and its tags
  (row, column, channel), and `pkt_fifo.v` buffers 8 packets. A **credit** counter in the controller stops the
  array whenever the vector unit falls behind (for example during pooling), so nothing is ever lost.

### Top-level integration: running a whole network

**`accel_top.v`** connects everything, and **`layer_seq.v`** turns single layers into whole networks:

1. The sequencer reads a **layer entry** from the table in external memory: the layer's shape and flags, its
   weight address, and the vector-unit program, section settings and lookup table, which it writes into the
   vector unit.
2. It starts the layer; the controller and the vector unit run it.
3. **Ping-pong:** after each layer, buffers A and B swap roles, so the next layer reads what the previous one
   just wrote - intermediate feature maps never leave the chip. Only the first layer loads an image.
4. After the last layer, **`writeback.v`** copies the result (e.g. the 10 class probabilities) to external memory
   over the write channel, and `done` rises.

Layer table entry (32-bit words; the next entry follows directly):

| Word | Contents |
|---|---|
| 0 | input height, width, channels; number of filters |
| 1 | kernel height and width, padding, stride, pooling; flags: load image, write back, last layer |
| 2 | weight address in external memory; output address in the buffer |
| 3 | image address; write-back address |
| 4 | write-back source and length |
| 5 | number of program words and lookup-table entries |
| 6-11 | the six sections (start, length, repeat count) |
| 12... | program words, then lookup-table entries |

**Chip interface:** `clk`, `rst_n`, `start`, `tbl_base`, `busy`, `done`, `err_valid`, `err[6:0]`, the memory read
channel (`rd_req_*`, `rd_resp_*`) and the memory write channel (`wr_req_*`).

---

## Software flow: from a Keras model to the chip

> 📷 *Software flow - figure to be added (`docs/images/software_flow.png`)*

| Step | File | What it does |
|---|---|---|
| Train | your Keras script (e.g. `train_cifar.py`) | a normal Keras CNN within the chip's limits |
| Export | `python/keras_export.py` | the model's layers, settings, weights and Keras's own predictions to a plain `.npz` (the only step needing TensorFlow) |
| Convert | `python/keras_flow.py` | Keras layers to chip layers: pooling fused into the conv before it, Flatten + Dense into an FC layer, BatchNorm folded, Dropout dropped; every chip limit checked; **the converted network must reproduce Keras's predictions** |
| Quantize | `python/chipnet.py` | calibration on training images; int8 weights, int32 biases, M and S per layer, 16-bit base-2 logits for softmax; the **bit-exact golden model** |
| Compile | `python/compile.py` | vector-unit programs, the layer table, weights and images as memory-image files |
| Run | `tb/tb_model.v` | the testbench plays only the chip's surroundings - the external memory and the host - and records everything the chip produces; it never sees an expected value |
| Check | `python/check_results.py` | compares the chip's results (every layer and the written-back result) with the golden model, computes accuracy, draws the gallery |

`classify.py` in the main directory runs all of these in one command.

Memory map in external memory (32-bit words): `0` input image, `4096` weights, `49152` layer table,
`57344` result written by the chip.

## What a model may contain

**Supported Keras layers:** Conv2D (ReLU or linear, `valid` padding or symmetric `same`, stride 1-4, kernels up to
7 x 7), MaxPooling2D 2 x 2 right after a convolution, BatchNormalization right after a linear Conv2D/Dense
(folded), Flatten, Dense (ReLU or linear; softmax on the last layer), Dropout, and Activation/ReLU/Softmax layers.
Inputs are images scaled with `x / 255`, greyscale or colour.

**Chip limits** (the flow names the rule a model breaks):
- every feature map must fit a 6 KB buffer: `1 + channels x height x ceil(width / 4)` <= 1536 words;
- kernels up to 7 x 7 - so the map before a Dense layer must be at most 7 x 7;
- `channels x kernel height x kernel width` <= 1020 weights per filter; at most 255 filters.

---

## Run your own model, step by step

Any image classifier that stays within the rules above can run on the chip. The path is always the same: a
dataset file, a Keras model designed for the chip's limits, training, then one command that converts, quantizes,
compiles, simulates the chip and checks it. Each step below says what it needs and how to tell it worked.

**Requirements:** Python 3 with numpy, Pillow and scikit-learn; TensorFlow (for training and for exporting the
model - nothing after the export needs it); Verilator 5.x for the chip simulation.

### Step 1 - Put the dataset in one `.npz` file

The flow reads a single file with four arrays:

| Array | Contents |
|---|---|
| `x_train`, `x_test` | the images as **raw `uint8` pixels, 0..255**; shape `(N, H, W)` for greyscale or `(N, H, W, C)` for colour |
| `y_train`, `y_test` | the labels as **integers** 0, 1, 2, ... (not one-hot); shape `(N,)` or `(N, 1)` |

The training images are used to calibrate the int8 scales; the test images are what the chip classifies.
For a dataset that comes with Keras:

```python
import numpy as np, tensorflow as tf
(xtr, ytr), (xte, yte) = tf.keras.datasets.cifar10.load_data()       # or mnist, fashion_mnist
np.savez("python/my_data.npz", x_train=xtr, y_train=ytr, x_test=xte, y_test=yte)
```

For your own images, load them into arrays of that shape (all the same size) and save them the same way.

### Step 2 - Design the model for the chip

Use a plain `Sequential` stack of the supported layers (see [What a model may contain](#what-a-model-may-contain)).
Plan the sizes on paper before training - the flow rejects a model that breaks a rule, naming the rule, but
it is quicker to get it right first:

1. **Every stored feature map must fit 1536 words:** `1 + channels x height x ceil(width / 4) <= 1536`.
   This holds for the input image (a 32 x 32 colour image takes 769 words; 64 x 64 colour would not fit) and
   for the map stored after each convolution (after its pooling, if a pooling layer follows it). Example for a
   32 x 32 colour input: a 3 x 3 conv with 32 filters gives 30 x 30 x 32, pooled to 15 x 15 x 32:
   `1 + 32 x 15 x 4 = 1921` - too big. With 24 filters: `1 + 24 x 15 x 4 = 1441` - fits.
   So: **put a MaxPooling2D right after the early convolutions**, and keep their filter counts modest.
2. **Kernels up to 7 x 7**, and a Dense layer after Flatten counts as a kernel the size of the whole map - so
   **the map before `Flatten` must be at most 7 x 7**.
3. **At most 1020 weights per filter:** `channels x kernel height x kernel width <= 1020`. For the first Dense
   layer that is `channels x height x width` of the map before `Flatten` (4 x 4 x 56 = 896 is fine,
   5 x 5 x 64 = 1600 is not - add one more convolution or pooling first). For later Dense layers it is simply
   the number of inputs.
4. **At most 255 filters / units** per layer (so up to 255 classes).
5. **Activations:** ReLU or none on hidden layers; softmax only on the last layer (or no softmax: the chip then
   returns the int8 scores). Pooling only 2 x 2 max pooling, directly after a convolution. Padding `valid`, or
   `same` with an odd kernel where it is symmetric; strides 1-4.

A template that fits (it is the CIFAR-10 model of this project; for 28 x 28 greyscale use `input_shape=(28, 28, 1)`):

```python
from tensorflow.keras import layers, models
model = models.Sequential([
    layers.Conv2D(24, 3, activation="relu", input_shape=(32, 32, 3)),   # 30x30x24 -> pooled 15x15x24
    layers.MaxPooling2D(2),
    layers.Conv2D(48, 3, activation="relu"),                             # 13x13x48 -> pooled 6x6x48
    layers.MaxPooling2D(2),
    layers.Conv2D(56, 3, activation="relu"),                             # 4x4x56
    layers.Flatten(),                                                    # 4 x 4 x 56 = 896 inputs (<= 1020)
    layers.Dense(64, activation="relu"),
    layers.Dense(10, activation="softmax"),
])
```

### Step 3 - Train it and save it

Train the normal Keras way, with one requirement: **the inputs must be the pixels divided by 255** (the chip
flow assumes exactly this scaling). Then save the model:

```python
model.compile(optimizer="adam", loss="sparse_categorical_crossentropy", metrics=["accuracy"])
model.fit(xtr / 255.0, ytr, epochs=10, validation_data=(xte / 255.0, yte))
model.save("python/my_model.keras")
```

`python/train_cifar.py` and `python/train_fashion.py` are complete examples. Tip: train for one epoch first and
run step 4 on it - if the model breaks a chip rule you find out in a minute, not after the full training.

### Step 4 - Run it on the chip

**Option A - your own photos** (one command, from the main directory, in the environment with TensorFlow):

```bash
python3 classify.py --model python/my_model.keras --data python/my_data.npz --classes "cat,dog,bird" \
                    photo1.jpg:cat photo2.jpg:dog photo3.jpg
```

The photos can be any size; they are cropped to a square and resized to the model's input. Give each one its
true label after a colon if you know it. `--classes` takes `cifar10`, `mnist`, `fashion` or your own list in
class-number order. Add `--macro` to simulate with the SRAM macro models.

**Option B - the dataset's test images** (two commands):

```bash
cd python
python3 keras_export.py my_model.keras my_data.npz my_export.npz      # needs TensorFlow; only once per model
cd ../simulation
./py_run_keras.sh ../python/my_export.npz ../python/my_data.npz 100 macro   # 100 test images on the chip
```

The number is how many test images go through the chip simulation (it takes a few seconds to minutes per image,
depending on the model); the accuracy of the integer model is computed on the whole test set in Python.
For class names in the gallery: `CHECK="--names=cat,dog,bird" ./py_run_keras.sh ...`.

**If the machine runs out of memory** (`Killed`): the flow evaluates the whole test set in Python first. Make a
smaller copy of the dataset and use that instead:

```bash
python3 -c "
import numpy as np
f = np.load('python/my_data.npz')
np.savez('python/my_data_small.npz', x_train=f['x_train'][:1000], y_train=f['y_train'][:1000],
         x_test=f['x_test'][:2000], y_test=f['y_test'][:2000])"
```

If the C++ build of the simulation is killed instead, build with fewer parallel jobs: `JOBS=1 ./run_model.sh`.

### Step 5 - Read the result

The run prints, in order (see [Example output, explained](#example-output-explained) for a full run):

1. **Conversion:** the chip layers your model became, and `same class on 100.0% of 500 images` - the converted
   network reproduces Keras's own predictions. If it does not, the flow stops here.
2. **Quantization:** the int8 scale of every layer, and `float accuracy` vs `integer (chip) accuracy`. These
   are normally within a fraction of a percent; a large drop means a layer's values do not quantize well
   (BatchNormalization after a convolution and moderate weights usually help).
3. **Compiling:** where each layer's program and weights are placed in external memory.
4. **The chip:** the cycle count per image, a picture of each image with the chip's prediction and its two
   largest probabilities, and the accuracy.
5. **The check:** `PASS: the chip's results (every layer, and the result it wrote back) match the golden model
   exactly` - every byte the chip produced, in every layer, equals the Python golden model.

**Common messages and what to change:**

| Message | Fix |
|---|---|
| `its stored output ... needs N words, a feature buffer holds 1536` | fewer filters in that layer, pooling after it, or a smaller input |
| `kernels are at most 7x7 (an FC layer's input map must be at most 7x7)` | more pooling or another convolution before `Flatten` |
| `channels x kernel = N weights per filter, at most 1020` | fewer channels into that layer, or a smaller map before `Flatten` |
| `at most 255 filters` | fewer filters or units |
| `pooling must follow a convolution directly` / `only 2x2 max pooling with stride 2` | move the pooling, use `MaxPooling2D(2)` |
| `activation '...' is not supported` | use ReLU (or none) on hidden layers |
| `softmax is only supported on the last layer` | remove softmax from the hidden layers |
| `BatchNormalization can only be folded right after a linear conv/dense` | `Conv2D(..., activation=None)`, then `BatchNormalization`, then `ReLU` |
| `'same' padding ... is asymmetric` | use `valid` padding, or an input size where `same` pads equally on both sides |
| `the converted network does not reproduce Keras` | the data file is not the one the model was trained on (or a different input scaling than / 255) |

---

## How to run

**Requirements:** Verilator (5.x), Python 3 with numpy, Pillow and scikit-learn; TensorFlow only to export Keras
models. Icarus Verilog runs the testbenches too.

### The SRAM macros

The design uses two SRAM macros, both with one read/write port (with a byte write mask) and one read-only port:

| Macro | Size | Used | For |
|---|---|---|---|
| **`sky130_sram_2kbyte_1rw1r_32x512_8`** | 2 KB: 512 words of 32 bits | 8 times | 3 for each feature buffer, 2 for the weight buffer |
| **`sky130_sram_1kbyte_1rw1r_32x256_8`** | 1 KB: 256 words of 32 bits | 4 times | the vector unit's local memory, one per lane |

They were generated with [OpenRAM](https://github.com/VLSIDA/OpenRAM) and are published in the
[sky130_sram_macros](https://github.com/VLSIDA/sky130_sram_macros) repository; PDK installations made with
open_pdks (for example the IIC-OSIC-TOOLS container) usually include them already:

```bash
find "$PDK_ROOT" -name 'sky130_sram_*kbyte_1rw1r_32x*_8*'
```

What each step needs from each macro's folder:

| Step | Files | Notes |
|---|---|---|
| simulation, default | nothing | `ram_1rw1r.v` and `vector_unit.v` have behavioural models; every testbench runs without the macros |
| simulation with `macro` / `--macro` | `sky130_sram_2kbyte_1rw1r_32x512_8.v`, `sky130_sram_1kbyte_1rw1r_32x256_8.v` | the macros' simulation models, kept in `macros/`; compiled with `-DUSE_SRAM_MACRO` |
| synthesis | the same `.v` files (as black boxes), and `USE_SRAM_MACRO` defined | the macros are instantiated, not synthesized |
| place and route | `.lef` (outline and pins), `.gds` (layout) | |
| timing analysis | `.lib` (timing models) | |

If `macros/` is missing in your copy, take the two `.v` files from the repository or the PDK above and put them
there. (Check the macro repository's license before redistributing its files.)

### Classify your own photos (one command)

From the main directory, in the environment with TensorFlow:

```bash
python3 classify.py --model python/cifar_cnn.keras --data python/cifar10.npz --classes cifar10 \
                    images/cat.jpeg:cat images/truck.jpg:truck images/frog.jpeg:frog images/dog.png
```

- `--model` a trained Keras model (`.keras`), or an export (`.npz`)
- `--data` the dataset the model was trained on (`.npz` with `x_train`, `y_train`, `x_test`, `y_test`), used to
  calibrate the int8 scales
- `--classes` `cifar10`, `mnist`, `fashion`, or your own list `"cat,dog,..."`
- photos: any size, jpg/png/...; each optionally with its true label (`photo.jpg:cat`). Without a label the
  photo shows `label ?` and is not counted.
- `--macro` simulate with the sky130 SRAM macro models; `--invert yes|no|auto` for greyscale photos (MNIST digits
  are white on black); `--verbose` full logs

It exports the model (only when it changed; kept in `build/`), prepares the photos, converts, quantizes and
compiles, runs the chip in simulation and checks the results. Logs are in `build/`.

### Train and run a model on a whole test set

```bash
cd python
python3 train_cifar.py                                            # trains cifar_cnn.keras, writes cifar10.npz
python3 keras_export.py cifar_cnn.keras cifar10.npz cifar_export.npz
cd ../simulation
./py_run_keras.sh ../python/cifar_export.npz ../python/cifar10.npz 100     # 100 test images on the chip
CHECK="--names=airplane,automobile,bird,cat,deer,dog,frog,horse,ship,truck" ./run_model.sh   # rerun chip + check
```

### Hardware test suites (in `simulation/`)

| Script | Tests |
|---|---|
| `pe.sh`, `sysarray.sh`, `skew.sh` | processing element, systolic array, skew buffers |
| `act.sh`, `wgt.sh`, `dma.sh`, `ram.sh`, `collector.sh` | feeders, DMA, SRAM wrapper (behavioural and macro), result collector |
| `lane.sh`, `regs.sh`, `vector_unit.sh` | vector-unit lane, register file, directed programs |
| `iss.sh [macro]` | random programs against the instruction-set interpreter (`macro`: local memory as the four 1 KB macros) |
| `xlane.sh`, `pred.sh` | cross-lane instructions, reductions, lookup table, `RCP`, `SHRRV`; predicates |
| `pool.sh`, `post.sh`, `model.sh` | pooling on the RTL; softmax and global average pooling; pooling on the interpreter |
| `top.sh [macro]` | 66 single layers through the whole chip, including rejected configurations |
| `network.sh [macro]` | 16 complete networks, each from one `start` |
| `py_run_model.sh`, `py_run_keras.sh`, `run_model.sh` | trained models (8x8 digits, Keras) on the chip |

Waveforms are written only on request: add `+vcd` (e.g. `./run_model.sh +vcd`).

---

## Example output, explained

Six of our own photos through the CIFAR-10 model, with the sky130 SRAM macro models:

```
(venv) /foss/designs/CNN_Accelerator > python3 classify.py --model python/cifar_cnn.keras --data python/cifar10.npz --classes cifar10 --macro images/cat.jpeg:cat images/truck.jpg:truck images/aeroplane.jpeg:airplane images/airplane.jpg:airplane images/frog.jpeg:frog images/frog1.jpeg:frog

=== 1/5 the model has not changed since its last export (build/cifar_cnn_export.npz)
```
**Step 1** - the model was exported before and has not changed, so TensorFlow is not needed.

```
=== 2/5 preparing 6 photo(s) for the model's 32x32x3 input
  images/cat.jpeg: label cat
  images/truck.jpg: label truck
  images/aeroplane.jpeg: label airplane
  images/airplane.jpg: label airplane
  images/frog.jpeg: label frog
  images/frog1.jpeg: label frog
```
**Step 2** - each photo is centre-cropped and resized to the model's 32 x 32 x 3 input; the labels are the true
answers we gave.

```
=== 3/5 converting, quantizing and compiling for the chip
1) Converting the Keras model to chip layers:
   chip layer 0: conv 32x32x3 -> 24 filters 3x3, stride 1, pad 0, ReLU, 2x2 max pool -> stored 15x15x24 (1441 of 1536 words)
   chip layer 1: conv 15x15x24 -> 48 filters 3x3, stride 1, pad 0, ReLU, 2x2 max pool -> stored 6x6x48 (577 of 1536 words)
   chip layer 2: conv 6x6x48 -> 56 filters 3x3, stride 1, pad 0, ReLU -> stored 4x4x56 (225 of 1536 words)
   chip layer 3: fc 4x4x56 -> 64 filters 4x4, stride 1, pad 0, ReLU -> stored 1x1x64 (65 of 1536 words)
   chip layer 4: fc 1x1x64 -> 10 filters 1x1, stride 1, pad 0, softmax -> stored 1x1x10 (11 of 1536 words)

   checking the conversion against Keras's own predictions:
   largest difference from Keras: reference 1.19e-06, converted chip network 1.19e-06; same class on 100.0% of 500 images
```
**Conversion** - the 8 Keras layers became 5 chip layers (each pooling fused into its convolution, the two Dense
layers as FC layers). Each stored map is shown against the 1536-word buffer. The converted network reproduces
Keras's predictions to within 10^-6.

```
2) Quantization (calibration on training images):
   layer 0 (conv 3->24, 3x3, stride 1, pad 0, ReLU, 2x2 pool): requantization 0.001926 ~ M 32316 / 2^24
   layer 1 (conv 24->48, 3x3, stride 1, pad 0, ReLU, 2x2 pool): requantization 0.002299 ~ M 19286 / 2^23
   layer 2 (conv 48->56, 3x3, stride 1, pad 0, ReLU): requantization 0.004880 ~ M 20466 / 2^22
   layer 3 (fc 56->64, 4x4, stride 1, pad 0, ReLU): requantization 0.002804 ~ M 23520 / 2^23
   layer 4 (fc 64->10, 1x1, stride 1, pad 0, softmax): requantization 0.457866 ~ M 30007 / 2^16
   softmax: 16-bit logits in base-2 units (one step = 1/256), exp by a 16-entry table + shift

3) The integer model (bit-exact with the chip) on 6 test images:
   float accuracy 66.67%,  integer (chip) accuracy 66.67%,  same prediction as float on 100.0% of the images
```
**Quantization** - each layer's scale factor becomes an integer multiplier M and a shift S for the vector unit's
`REQ` instruction; the softmax layer's factor also converts its logits to 16-bit base-2 values. The int8 model makes the same
prediction as the float model on every photo.

```
4) Compiling for the chip:
   layer 0: table entry at 49152 (39 words, program 27 instructions), weights at 4096 (186 words), input 32x32 -> stored 15x15x24
   layer 1: table entry at 49191 (39 words, program 27 instructions), weights at 4282 (2640 words), input 15x15 -> stored 6x6x48
   layer 2: table entry at 49230 (20 words, program 8 instructions), weights at 6922 (6104 words), input 6x6 -> stored 4x4x56
   layer 3: table entry at 49250 (20 words, program 8 instructions), weights at 13026 (14400 words), input 4x4 -> stored 1x1x64
   layer 4: table entry at 49270 (69 words, program 49 instructions), weights at 27426 (204 words), input 1x1 -> stored 1x1x10
   wrote 23721 words of weights and table, and 6 test images for the RTL, to /foss/designs/CNN_Accelerator/simulation/model
```
**Compiling** - one table entry per layer: the pooling layers carry the 27-instruction pooling program, the plain
layers an 8-instruction requantize + ReLU program, the softmax layer 49 instructions plus its 16-entry table.
The whole model is 23,721 words (about 93 KB) of external memory.

```
=== 4/5 running the chip (RTL simulation)   5/5 checking its results
Running 6 images on the chip, 5 layers each (one start per image).
    image 0: done after 264950 cycles
    image 1: done after 264945 cycles
    image 2: done after 264964 cycles
    image 3: done after 265019 cycles
    image 4: done after 264946 cycles

6 images, 264963 cycles per image on average. Everything the chip produced: outputs/chip_results.hex
```
**Step 4** - the chip runs each photo from one `start`: about 265,000 cycles, 2.65 ms at 100 MHz. The testbench
only stores what the chip wrote; the comparison comes afterwards.

```
The first 6 images as the chip saw them, with label, the chip's prediction and its two largest probabilities (<- marks a misclassified image):

  image 0                             image 1                             image 2
  ##++++++++++++##+####+####+#####    ++++++++++++++++++++++++++++++++    ################################
  ###+++#+++###########+#########+    ++++++++++++++++++++++++++++++++    ################################
  ...                                 ...                                 ...
  label cat chip cat                  label truck chip truck              label airplane chip airplane
  cat:0.83 frog:0.11                  truck:0.99 airplane:0.00            airplane:0.99 automobile:0.00

  image 3                             image 4                             image 5
  +++++++++++++++++++++++#########    ..........             .........                  ........ ..
  +++++++++++++++++++#############    .........                 ......             ..    .........
  ...                                 ...                                 ...
  label airplane chip ship <-         label frog chip bird <-             label frog chip frog
  ship:0.88 airplane:0.12             bird:0.68 frog:0.22                 frog:0.99 automobile:0.01
```
**Step 5, the gallery** - each photo as the chip saw it (32 x 32, drawn by brightness: `#` dark, `.` faint), the
true label, the chip's prediction and its two largest probabilities, read from the result **the chip wrote back to
memory**. (The ASCII pictures are shortened here; the full output shows all 32 rows, followed by a gallery of the
misclassified images.)

```
Accuracy on the 6 labelled images:
    the chip (RTL)                    4 of 6 = 66.67%
    integer golden model (Python)     4 of 6
    (on the whole test set of the flow: float 66.67%, integer 66.67%)
Chip against the golden model:
    chip and golden model predict the same class on 6 of 6 images
    0 layer-map bytes and 0 written-back bytes differ from the golden model
    264964 cycles per image on average (2649.6 us at 100 MHz)
    every image with its outputs and the full gallery: outputs/model_results.txt

PASS: the chip's results (every layer, and the result it wrote back) match the golden model exactly
```
**Step 5, the verdict** - the cat, the truck, one airplane and one frog are right. The second airplane (large blue
sky) is taken for a ship, and one frog for a bird: mistakes of the model itself, which the int8 model and Keras
make too. What matters for the hardware is the last part: **0 bytes differ** - every value of every layer, and the
result written back, is exactly what the golden model computed.

---

## Verification

| Level | Testbench | What is checked |
|---|---|---|
| Blocks | `tb_processing_element`, `tb_systolic_activity`, `tb_skew_buffer`, `tb_act_feeder`, `tb_wgt_feeder`, `tb_dma`, `tb_ram_1rw1r`, `tb_result_collector` | each block against a reference, including edge cases (partial tiles, all strides and paddings, slow memory, macro timing) |
| Vector unit | `tb_vu_lane`, `tb_vu_regs`, `tb_vector_unit`, `tb_vu_iss`, `tb_vu_xlane`, `tb_vu_pred` | every instruction; thousands of random programs against an instruction-set interpreter (every store and every register compared); edge cases for each instruction |
| Programs | `tb_vu_model`, `tb_vu_pool`, `tb_vu_post` | pooling, softmax and global average pooling on real feature maps |
| Chip, single layers | `tb_accel_top` | 66 layers through the whole chip: every accumulator and every int8 result, backpressure from slow programs, slow memory, 7 kinds of invalid layer rejected |
| Chip, networks | `tb_network` | 16 complete networks from one `start`; every layer's map and the written-back result |
| Chip, trained models | `tb_model` + `check_results.py` | trained Keras models on real images, bit-exact against the golden model |

Each suite passes in Verilator and Icarus Verilog, with behavioural memories and with the sky130 macro models.
Each was also checked with deliberately planted bugs, to make sure it catches them.

## Repository layout

```
CNN_Accelerator/
|-- README.md            this file
|-- classify.py          one command: Keras model + photos -> chip classification
|-- vector_isa.md        the vector unit's instruction set and the layer-table format
|-- rtl/                 the hardware (Verilog-2005)
|-- tb/                  testbenches
|-- simulation/          scripts to build and run the testbenches; model/ and outputs/ are generated
|-- python/              the software flow (export, convert, quantize, golden model, compile, check)
|-- macros/              the SRAM macros' simulation models (see "The SRAM macros")
|-- synthesis/, sta/     synthesis and static timing analysis of the processing element
|-- images/              photos to classify
|-- build/               generated by classify.py (exports, prepared photos, logs)
`-- docs/images/         architecture figures (to be added)
```

## Status and next steps

**Done:** the complete RTL (array, vector unit, control, memories, layer sequencer, write-back); the software flow
from Keras to the chip; verification from single blocks to trained models; processing-element synthesis and static
timing (+0.87 ns slack at a 10 ns clock, pre-layout).

**Next:**
- the chip boundary: a QSPI PSRAM adapter to bring the pin count down to about 12-15;
- synthesis, place and route of the whole chip, and gate-level simulation of the network tests;
- larger models: 8 KB feature buffers, and row-band tiling for maps of any size;
- faster pooling, and kernels larger than 7 x 7.

test test
