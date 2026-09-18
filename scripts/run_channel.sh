#!/usr/bin/env bash
# Run the covert channel for sender bit 1 and bit 0, then print the receiver's
# median batch time for each. A clear gap means the bit was recovered. Set GEM5.
set -e
: "${GEM5:=/home/mtp/pranjal}"
BIN="$GEM5/build/X86_MESI_Two_Level/gem5.opt"
SE="$GEM5/configs/example/se.py"
EVAL="$GEM5/mtp_eval"

for B in 1 0; do
  "$BIN" \
    --outdir="$EVAL/results/chan_bit$B" \
    "$SE" --smt --num-cpus=1 \
    --cpu-type=DerivO3CPU --caches --l2cache \
    -c "$EVAL/sender;$EVAL/receiver" -o "$B;" \
    > "$EVAL/logs/chan_bit$B.log" 2>&1
done

for B in 1 0; do
  printf "sender bit=%s  ->  receiver median cycles/batch: " "$B"
  grep -E '^[0-9]+$' "$EVAL/logs/chan_bit$B.log" | sort -n | \
    awk '{a[NR]=$1} END{print a[int(NR/2)]"  (n="NR", min="a[1]", max="a[NR]")"}'
done
