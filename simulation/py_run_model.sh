#!/bin/bash
# 8x8 digits example: train (python/digits_model.py), quantize and compile, then run on the RTL.
#   ./py_run_model.sh [macro]          (checker options: CHECK="--all" ./py_run_model.sh)
mkdir -p model
( cd ../python && python3 run_flow.py ../simulation/model ) || { echo "Python flow failed"; exit 1; }
./run_model.sh "$@"
