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
6. [How to run](#how-to-run)
7. [Example output, explained](#example-output-explained)
8. [Verification](#verification)
9. [Repository layout](#repository-layout)
10. [Status and next steps](#status-and-next-steps)

---

## Highlights

| | |
|---|---|
| Arithmetic | int8 activations and weights, 32-bit accumulation, int32 biases |
| Compute | 4 x 4 output-stationary systolic array (16 multiply-accumulates per cycle) |
| Post-processing | a programmable 4-lane SIMD vector unit: requantization, ReLU / Leaky ReLU / ReLU6, any activation by lookup table, max and average pooling, global average pooling, argmax, softmax |
| On-chip memory | 16 KB in 8 SRAM macros (two 6 KB feature buffers for ping-pong, and a 4 KB weight buffer), plus the vector unit's 4 KB local memory, 512-byte lookup table and 256-byte program memory (flip-flops for now) |
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
- **Lane arithmetic:** add, subtract, min, max, shifts with rounding, multiply, compare, select.
- **Predication:** every instruction can be limited to lanes of a mask, or to packets matching up to six
  predicates on their row, column, channel, address or byte mask.
- **Across lanes:** `MAXP`/`ADDP` (pairs), `PERM`/`PERMS` (permutations), `RMAX`/`RADD` (reductions to a scalar).
- **Address unit:** computes where a pooled value belongs (`paddr`, `pbe`, `lmidx`) from the packet's tags.
- **Local memory:** 4 KB (256 entries of 128 bits). It holds values that span packets: the even row's partial
  maxima during 2 x 2 pooling, the logits during softmax, and per-channel sums for global average pooling.
- **Lookup table** (256 x 16 bits) for any function of an int8 value - exp for softmax, sigmoid, tanh, ...
- **`RCP`**, a reciprocal unit (2^n / x), for softmax's division.

**Programs** (generated by the compiler): requantize + ReLU in 2 instructions per packet; 2 x 2 and 4 x 4 max pooling
and 2 x 2 average pooling fused into the convolution (~13 cycles per packet); global average pooling; argmax;
softmax over up to 256 classes (exp by table, one `RCP`, within 0.008 of a float softmax).

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
| Quantize | `python/chipnet.py` | calibration on training images; int8 weights, int32 biases, M and S per layer, the softmax exp table; the **bit-exact golden model** |
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

## How to run

**Requirements:** Verilator (5.x), Python 3 with numpy, Pillow and scikit-learn; TensorFlow only to export Keras
models. Icarus Verilog runs the testbenches too.

### The SRAM macro

The design uses one SRAM macro, **`sky130_sram_2kbyte_1rw1r_32x512_8`** (2 KB: 512 words of 32 bits, one
read/write port and one read-only port), 8 times: 3 for each feature buffer and 2 for the weight buffer. It was
generated with [OpenRAM](https://github.com/VLSIDA/OpenRAM) and is published in the
[sky130_sram_macros](https://github.com/VLSIDA/sky130_sram_macros) repository; PDK installations made with
open_pdks (for example the IIC-OSIC-TOOLS container) usually include it already:

```bash
find "$PDK_ROOT" -name 'sky130_sram_2kbyte_1rw1r_32x512_8*'
```

What each step needs from the macro's folder:

| Step | Files | Notes |
|---|---|---|
| simulation, default | nothing | `ram_1rw1r.v` has its own behavioural model; every testbench runs without the macro |
| simulation with `macro` / `--macro` | `sky130_sram_2kbyte_1rw1r_32x512_8.v` | the macro's simulation model, kept in `macros/`; compiled with `-DUSE_SRAM_MACRO` |
| synthesis | the same `.v` (as a black box) | the macro is instantiated, not synthesized |
| place and route | `.lef` (outline and pins), `.gds` (layout) | |
| timing analysis | `.lib` (timing models) | |

If `macros/` is missing in your copy, take `sky130_sram_2kbyte_1rw1r_32x512_8.v` from the repository or the PDK above
and put it there. (Check the macro repository's license before redistributing its files.)

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
| `iss.sh` | random programs against the instruction-set interpreter |
| `xlane.sh`, `pred.sh` | cross-lane instructions, reductions, lookup table, `RCP`; predicates |
| `pool.sh`, `post.sh`, `model.sh` | pooling on the RTL; softmax and global average pooling; pooling on the interpreter |
| `top.sh [macro]` | 66 single layers through the whole chip, including rejected configurations |
| `network.sh` | 16 complete networks, each from one `start` |
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
   layer 4 (fc 64->10, 1x1, stride 1, pad 0, softmax): requantization 0.004323 ~ M 18131 / 2^22
   exp table: one logit step = 0.2868

3) The integer model (bit-exact with the chip) on 6 test images:
   float accuracy 66.67%,  integer (chip) accuracy 66.67%,  same prediction as float on 100.0% of the images
```
**Quantization** - each layer's scale factor becomes an integer multiplier M and a shift S for the vector unit's
`REQ` instruction; the exp table for softmax is built for the last layer's scale. The int8 model makes the same
prediction as the float model on every photo.

```
4) Compiling for the chip:
   layer 0: table entry at 49152 (39 words, program 27 instructions), weights at 4096 (186 words), input 32x32 -> stored 15x15x24
   layer 1: table entry at 49191 (39 words, program 27 instructions), weights at 4282 (2640 words), input 15x15 -> stored 6x6x48
   layer 2: table entry at 49230 (20 words, program 8 instructions), weights at 6922 (6104 words), input 6x6 -> stored 4x4x56
   layer 3: table entry at 49250 (20 words, program 8 instructions), weights at 13026 (14400 words), input 4x4 -> stored 1x1x64
   layer 4: table entry at 49270 (176 words, program 36 instructions), weights at 27426 (204 words), input 1x1 -> stored 1x1x10
   wrote 23828 words of weights and table, and 6 test images for the RTL, to /foss/designs/CNN_Accelerator/simulation/model
```
**Compiling** - one table entry per layer: the pooling layers carry the 27-instruction pooling program, the plain
layers an 8-instruction requantize + ReLU program, the softmax layer 36 instructions plus its 256-entry exp table.
The whole model is 23,828 words (about 93 KB) of external memory.

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
|-- macros/              the SRAM macro's simulation model (see "The SRAM macro")
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
- the vector unit's local memory as SRAM macros instead of flip-flops (before physical design);
- the chip boundary: a QSPI PSRAM adapter to bring the pin count down to about 12-15;
- synthesis, place and route of the whole chip, and gate-level simulation of the network tests;
- larger models: 8 KB feature buffers, and row-band tiling for maps of any size;
- faster pooling, kernels larger than 7 x 7, and a higher-precision softmax.
