#!/usr/bin/env bash
# =============================================================================
# verify_transmitter.sh
#
# Re-checks the FloatDiv transient-transmitter result on the DOLMA gem5 fork,
# using the gem5 binary that is already built with the model changes.
#
#   1-3  same functional unit + same opcode for both secrets, only the operand differs
#   4    operand difference -> different execution latency (6 vs 24 cycles)
#   5    latency difference -> different functional-unit busy interval
#   6    the secret-carrying divide runs while DOLMA-restricted (modes 3 and 4)
#   7    that divide is eventually SQUASHED and never commits
#
# Run it on compute-1:   bash verify_transmitter.sh
# Everything it writes stays under /home/mtp/pranjal/mtp_eval.
#
# WARNING (compute-1): the system `ls` overwrites executables in the folder it is
# run in. Do not type `ls` in a folder that holds your programs. This script never
# calls `ls`, builds into its own bin/ folder, and refuses to run a program that is
# not a plain static executable.   See SERVER_SECURITY_NOTE.md.
# =============================================================================
set -u

GEM5=/home/mtp/pranjal
GEM5_BIN="$GEM5/build/X86_MESI_Two_Level/gem5.opt"
EVAL="$GEM5/mtp_eval"
SRC="$EVAL/src"
BINDIR="${BINDIR:-$EVAL/bin}"          # where the two test programs are built
OUT="${OUT:-$EVAL/verify_fresh}"       # where the proof files are written
mkdir -p "$OUT" "$BINDIR"

# Stop if a program is not a plain statically linked executable (see warning above).
need_static () {
  if ! file -b "$1" | grep -q "statically linked"; then
    echo "STOP: $1 is not a plain static executable:"
    echo "      $(file -b "$1" | cut -c1-100)"
    echo "      Rebuild it and do not run 'ls' in its folder (see SERVER_SECURITY_NOTE.md)."
    exit 1
  fi
}

# One gem5 run of the transmitter.   $1 = name of the output folder   $2 = s0 or s1
# $3 = DOLMA mode (0 off, 1 Default, 2 Conservative, 3 Default memory-only, 4 Conservative memory-only)
# $4 = extra debug flags (optional).  The trace ends up in $OUT/<name>/trace.log
# DOLMA is only switched on by attacks/se_run_experiment.py (it sets cpu.mode).
run_gem5 () {
  need_static "$BINDIR/t_$2"
  local odir="$OUT/$1"; rm -rf "$odir"; mkdir -p "$odir"
  ( cd "$GEM5/attacks" && "$GEM5_BIN" --outdir="$odir" \
      --debug-flags="FloatDivChan${4:+,$4}" --debug-file=trace.log se_run_experiment.py \
      --mem-type SimpleMemory --cmd "$BINDIR/t_$2" \
      --cpu-type DerivO3CPU --cpu-clock 2GHz --sys-clock 2GHz \
      --l1d_size 32kB --l1d_assoc 8 --l1i_size 32kB --l2_size 2MB --l2_assoc 16 \
      --l2cache --caches --mode "$3" --stt 0 ) >"$odir/gem5.out" 2>&1
}

echo "=================================================================="
echo " STEP 0  Build the two secret programs (-O0, static)"
echo "=================================================================="
gcc --version | head -1
( cd "$SRC" \
  && gcc -O0 -static -DSEC=0 transmitter.c -o "$BINDIR/t_s0" \
  && gcc -O0 -static -DSEC=1 transmitter.c -o "$BINDIR/t_s1" ) \
  || { echo "BUILD FAILED"; exit 1; }
need_static "$BINDIR/t_s0"; need_static "$BINDIR/t_s1"
echo "built t_s0 and t_s1:"; file -b "$BINDIR/t_s1" | cut -c1-90
echo "--- the divide instruction in the program (expect exactly one divsd) ---"
objdump -d "$BINDIR/t_s1" | grep -iE "divsd|divpd|fdiv" | head

echo
echo "=================================================================="
echo " STEP 1  No defense (mode 0): secret 0 versus secret 1"
echo "   expect: secret 0 -> 0 slow divides,  secret 1 -> at least 1"
echo "   (the exact number depends on where the program sits; we saw 2, 3 and 5)"
echo "=================================================================="
for S in s0 s1; do
  run_gem5 "base_$S" "$S" 0 ""
  L="$OUT/base_$S/trace.log"
  printf "  secret %s   slow(op_latency=24)=%s   fast(=6)=%s\n" "${S#s}" \
    "$(grep -c 'op_latency=24' "$L")" "$(grep -c 'op_latency=6' "$L")"
done

echo
echo "=================================================================="
echo " STEP 2  Functional-unit busy time of each slow divide (secret 1)"
echo "   busy = free_tick - issue_tick;  500 ticks = 1 cycle at 2 GHz"
echo "=================================================================="
L1="$OUT/base_s1/trace.log"
for SN in $(grep 'op_latency=24' "$L1" | grep -oE 'sn:[0-9]+' | sort -u); do
  ISS=$(grep "$SN" "$L1" | grep ISSUE | grep -oE 'issue_tick=[0-9]+' | cut -d= -f2 | head -1)
  FRE=$(grep "$SN" "$L1" | grep FREE  | grep -oE 'free_tick=[0-9]+'  | cut -d= -f2 | head -1)
  [ -n "$ISS" ] && [ -n "$FRE" ] && echo "  slow  $SN  busy=$((FRE-ISS)) ticks (=$(( (FRE-ISS)/500 )) cycles)"
done
FSN=$(grep 'op_latency=6' "$L1" | grep -oE 'sn:[0-9]+' | head -1)
ISS=$(grep "$FSN" "$L1" | grep ISSUE | grep -oE 'issue_tick=[0-9]+' | cut -d= -f2 | head -1)
FRE=$(grep "$FSN" "$L1" | grep FREE  | grep -oE 'free_tick=[0-9]+'  | cut -d= -f2 | head -1)
[ -n "$ISS" ] && echo "  fast  $FSN  busy=$((FRE-ISS)) ticks (=$(( (FRE-ISS)/500 )) cycles)"
echo "  expect: slow ~11500 ticks (23 cycles), fast ~2500 ticks (5 cycles)"

echo
echo "=================================================================="
echo " STEP 3  The slow divide is squashed and never commits"
echo "=================================================================="
SLOWSN=$(grep 'op_latency=24' "$L1" | grep -oE 'sn:[0-9]+' | head -1 | cut -d: -f2)
echo "  following sn:$SLOWSN with the commit trace switched on"
run_gem5 "commit_s1" "s1" 0 "Commit"
CL="$OUT/commit_s1/trace.log"
PROOF="$OUT/commit_s1/squash_proof.txt"
{
  echo "### FloatDivChan: the slow divide issued and freed the unit (it executed)"
  grep -E "\[sn:$SLOWSN\].*(ISSUE|FREE)" "$CL"
  echo
  echo "### Commit stage: did sn:$SLOWSN reach the head of the ROB, and was it squashed?"
  grep -A1 -E "Trying to commit head instruction, \[sn:$SLOWSN\]" "$CL"
  echo
  echo "### Commit stage: was sn:$SLOWSN ever actually committed? (must be empty)"
  grep -E "Committing instruction with \[sn:$SLOWSN\]" "$CL"
} > "$PROOF"
cat "$PROOF"
echo "  committed count for sn:$SLOWSN = $(grep -cE "Committing instruction with \[sn:$SLOWSN\]" "$CL")   (expect 0)"
rm -f "$CL"          # the full commit trace is large; the small proof file is kept

echo
echo "=================================================================="
echo " STEP 4  The four DOLMA modes, secret 1"
echo "   modes 1,2 (memory+register protection): expect slow = 0"
echo "   modes 3,4 (memory-only):                expect slow > 0, divide shows restricted=1"
echo "   (modes 3,4 also contain one secret-independent slow divide with junk input)"
echo "=================================================================="
for M in 1 2 3 4; do
  run_gem5 "dolma_s1_m$M" "s1" "$M" ""
  L="$OUT/dolma_s1_m$M/trace.log"
  printf "  mode %s   slow(24)=%-3s   divides flagged restricted=%s\n" "$M" \
    "$(grep -c 'op_latency=24' "$L")" "$(grep -c 'restricted=1' "$L")"
done

echo
echo "=================================================================="
echo " DONE.  Proof files are in: $OUT"
echo "=================================================================="
du -sh "$OUT"
df -h / | tail -1
