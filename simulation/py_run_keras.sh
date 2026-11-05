#!/bin/bash
# A Keras model exported with python/keras_export.py: convert, quantize and compile, then run on the RTL.
#   ./py_run_keras.sh <export.npz> <data.npz> [images for the RTL, default 100] [macro]   (checker options: CHECK="--all --names=...")
[ $# -ge 2 ] || { echo "usage: ./py_run_keras.sh <export.npz> <data.npz> [n_rtl] [macro]"; exit 1; }
EXP=$(realpath "$1"); DATA=$(realpath "$2"); shift 2
N=100
if [[ "$1" =~ ^[0-9]+$ ]]; then N=$1; shift; fi
mkdir -p model
( cd ../python && python3 keras_flow.py "$EXP" "$DATA" ../simulation/model "$N" ) || { echo "Python flow failed"; exit 1; }
./run_model.sh "$@"
