#!/usr/bin/env bash
# Run the transmitter primitive for secret 0 and secret 1 and print the
# FloatDiv allocation/release events. Set GEM5 first.
set -e
: "${GEM5:=/home/mtp/pranjal}"
BIN="$GEM5/build/X86_MESI_Two_Level/gem5.opt"
SE="$GEM5/configs/example/se.py"
EVAL="$GEM5/mtp_eval"

for S in s0 s1; do
  "$BIN" \
    --outdir="$EVAL/results/run_$S" \
    --debug-flags=FloatDivChan \
    "$SE" -c "$EVAL/transmitter_$S" \
    --cpu-type=DerivO3CPU --caches --l2cache \
    > "$EVAL/logs/floatdiv_$S.log" 2>&1
done

echo "A transient divide that is fast (op_latency 6) for secret 0 and slow (24)"
echo "for secret 1, at the same sequence number, is the transmitter."
for S in s0 s1; do
  echo "--- $S: non-trivial (slow) divides ---"
  grep "op_latency=24" "$EVAL/logs/floatdiv_$S.log" || echo "  none"
done
