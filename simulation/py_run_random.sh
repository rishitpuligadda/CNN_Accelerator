#!/bin/bash
# Random networks (python/random_net.py): random shapes and weights, compiled like a trained model, run on the RTL
# and checked layer by layer against the golden model. Seeds 0-9 are fixed networks that cover bands (maps larger
# than a feature buffer), 11x11 kernels, padding, strides and pooling; other seeds are random.
#   ./py_run_random.sh [seeds, default "0 1 2 3 4 5 6 7 8 9"] [macro]
SEEDS="${1:-0 1 2 3 4 5 6 7 8 9}"
shift
mkdir -p model
fail=0
for s in $SEEDS; do
	echo "=== random network $s"
	( cd ../python && python3 random_net.py "$s" ../simulation/model 2 ) | grep -E "random network|   layer [0-9]+: (conv|fc)|external memory used" \
		|| { echo "Python flow failed"; exit 1; }
	./run_model.sh "$@" > outputs/random_$s.log 2>&1
	if grep -q "^PASS" outputs/random_$s.log; then grep -E "^PASS|cycles per image" outputs/random_$s.log | tail -2
	else echo "FAIL (see simulation/outputs/random_$s.log)"; tail -20 outputs/random_$s.log; fail=1; fi
done
exit $fail
