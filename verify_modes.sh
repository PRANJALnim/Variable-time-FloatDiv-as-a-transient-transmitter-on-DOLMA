#!/usr/bin/env bash
# =============================================================================
# verify_modes.sh -- run the transmitter under every DOLMA mode and with STT.
#
#   mode 0 baseline | 1 Default (M+R) | 2 Conservative (M+R)
#                   | 3 Default (memory only) | 4 Conservative (memory only)
#   --stt 1 turns the DOLMA modes into their STT versions.
#   "M+R" = memory and register protection, "M" = memory only.
#
# For each setting it counts the slow (op_latency=24) divides:
#   slow > 0  -> a secret-dependent occupancy is produced (the transmitter fires)
#   slow = 0  -> it is not
# Modes 3 and 4 also show one secret-independent slow divide (junk input); compare
# the secret-1 count with the secret-0 count to see the secret-driven part.
#
# Run on compute-1:   bash verify_modes.sh        (takes several minutes)
# Same warning as verify_transmitter.sh: never run `ls` in a folder with your programs.
# =============================================================================
set -u

GEM5=/home/mtp/pranjal
GEM5_BIN="$GEM5/build/X86_MESI_Two_Level/gem5.opt"
EVAL="$GEM5/mtp_eval"
SRC="$EVAL/src"
BINDIR="${BINDIR:-$EVAL/bin}"
OUT="${OUT:-$EVAL/verify_fresh/modes}"
mkdir -p "$OUT" "$BINDIR"

need_static () {
  if ! file -b "$1" | grep -q "statically linked"; then
    echo "STOP: $1 is not a plain static executable: $(file -b "$1" | cut -c1-80)"
    echo "      Rebuild it and do not run 'ls' in its folder (see SERVER_SECURITY_NOTE.md)."
    exit 1
  fi
}

( cd "$SRC" \
  && gcc -O0 -static -DSEC=0 transmitter.c -o "$BINDIR/t_s0" \
  && gcc -O0 -static -DSEC=1 transmitter.c -o "$BINDIR/t_s1" ) || { echo "BUILD FAILED"; exit 1; }
need_static "$BINDIR/t_s0"; need_static "$BINDIR/t_s1"

# $1 = s0 or s1    $2 = mode    $3 = stt (0 or 1)
run () {
  need_static "$BINDIR/t_$1"
  local odir="$OUT/$1_m$2_stt$3"; rm -rf "$odir"; mkdir -p "$odir"
  ( cd "$GEM5/attacks" && "$GEM5_BIN" --outdir="$odir" \
      --debug-flags=FloatDivChan --debug-file=fdchan.log se_run_experiment.py \
      --mem-type SimpleMemory --cmd "$BINDIR/t_$1" \
      --cpu-type DerivO3CPU --cpu-clock 2GHz --sys-clock 2GHz \
      --l1d_size 32kB --l1d_assoc 8 --l1i_size 32kB --l2_size 2MB --l2_assoc 16 \
      --l2cache --caches --mode "$2" --stt "$3" ) >"$odir/gem5.out" 2>&1
  local L="$odir/fdchan.log"
  # gem5 prints which defense it is running; show that name so the row is self-explanatory
  local name; name=$(grep -E "Baseline|DOLMA-|STT-" "$odir/gem5.out" | head -1 | sed 's/^[[:space:]]*//')
  printf "  %s  mode=%s stt=%s  %-26s slow(24)=%-3s restricted=%s\n" "$1" "$2" "$3" "${name:-?}" \
    "$(grep -c 'op_latency=24' "$L" 2>/dev/null)" "$(grep -c 'restricted=1' "$L" 2>/dev/null)"
}

echo "=== secret 1, all five modes, STT off ==="
for m in 0 1 2 3 4; do run s1 "$m" 0; done
echo "=== secret 1, the four DOLMA modes with STT on ==="
for m in 1 2 3 4; do run s1 "$m" 1; done
echo "=== secret 0 (reference), all five modes, STT off ==="
for m in 0 1 2 3 4; do run s0 "$m" 0; done
echo "=== done ==="
du -sh "$OUT"; df -h / | tail -1
