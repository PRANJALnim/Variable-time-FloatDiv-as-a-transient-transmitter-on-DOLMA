#!/usr/bin/env bash
# Build the workload binaries. Run from anywhere; set GEM5 first.
set -e
: "${GEM5:=/home/mtp/pranjal}"
SRC="$GEM5/mtp_eval/src"
OUT="$GEM5/mtp_eval"

cd "$SRC"
gcc -O0 -static -o "$OUT/transmitter_s0" -DSEC=0 transmitter.c
gcc -O0 -static -o "$OUT/transmitter_s1" -DSEC=1 transmitter.c
gcc -O0 -static -o "$OUT/sender"   sender.c
gcc -O0 -static -o "$OUT/receiver" receiver.c
echo "built: transmitter_s0 transmitter_s1 sender receiver"
