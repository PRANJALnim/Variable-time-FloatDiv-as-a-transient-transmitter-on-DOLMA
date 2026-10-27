# How to run it and check the results

A step-by-step guide to reproduce the transmitter result on the server. Everything
runs on compute-1 and only writes under `/home/mtp/pranjal`.

## Read this first: do not run `ls` on compute-1

On compute-1 the system `ls` is not the normal one. Running it in a folder that has
a program in it **overwrites that program** with a different file that gem5 cannot
run (details: `../Complete_Work/SERVER_SECURITY_NOTE.md`). The symptom is a gem5 run
that stops at once with

    Inconsistency detected by ld.so: rtld.c: 1494: dl_main: Assertion ...

and a log with nothing in it. So:

* Don't type `ls` in a folder that holds your binaries. Use `find . -maxdepth 1`,
  `stat -c '%s %n' *`, or `echo *` instead.
* Before any run, check the program is intact. A good one says `statically linked`:

```bash
file -b $GEM5/mtp_eval/bin/t_s1
# good:  ELF 64-bit LSB executable, x86-64, ... statically linked ...
# bad:   ELF 64-bit LSB shared object, ... dynamically linked ... no section header
```

If it is bad, rebuild it (step 2). The scripts below do this check for you.

## 1. Get onto the server

Two hops. The password is the same for both; it is in your `credentials` file, so it is not written here.

```bash
ssh mtp@10.5.30.70          # master node
ssh mtp@192.168.1.8         # compute-1 (run everything here)
```

Set one variable on compute-1:

```bash
export GEM5=/home/mtp/pranjal
```

## Shortcut: two scripts do everything below

Copy them to the server and run them:

```bash
# from your own machine, in the Assignment_Submission folder
scp -J mtp@10.5.30.70 verify_transmitter.sh verify_modes.sh mtp@192.168.1.8:/home/mtp/pranjal/mtp_eval/

# on compute-1
cd /home/mtp/pranjal/mtp_eval
bash verify_transmitter.sh      # steps 2-6 below, about 5 minutes
bash verify_modes.sh            # secret 0 and 1 under all five modes and STT, about 10 minutes
```

Their output should look like `proof/script_run_transmitter.txt` and
`proof/script_run_modes.txt`. The slow-divide counts can differ by a few depending on
where the program sits (we saw 2, 3 and 5); what must hold is the zero versus
non-zero pattern described below.

## 2. Build the two programs

Same source built twice: once with the secret = 0 and once with the secret = 1.
Build with `-O0` (see the notes at the bottom).

```bash
mkdir -p $GEM5/mtp_eval/bin
cd $GEM5/mtp_eval/src
gcc -O0 -static -DSEC=0 transmitter.c -o $GEM5/mtp_eval/bin/t_s0
gcc -O0 -static -DSEC=1 transmitter.c -o $GEM5/mtp_eval/bin/t_s1
file -b $GEM5/mtp_eval/bin/t_s1 | cut -c1-80       # must say "statically linked"
objdump -d $GEM5/mtp_eval/bin/t_s1 | grep divsd    # exactly one line: divsd  %xmm1,%xmm0
```

## 3. Run the transmitter with no defense

`--debug-flags=FloatDivChan` turns on my trace and `--debug-file=fdchan.log` writes
it into the output folder. `--mode 0` means DOLMA is off.

```bash
cd $GEM5/attacks
for S in s0 s1; do
  $GEM5/build/X86_MESI_Two_Level/gem5.opt --outdir=$GEM5/mtp_eval/out_$S \
    --debug-flags=FloatDivChan --debug-file=fdchan.log se_run_experiment.py \
    --mem-type SimpleMemory --cmd $GEM5/mtp_eval/bin/t_$S \
    --cpu-type DerivO3CPU --cpu-clock 2GHz --sys-clock 2GHz \
    --l1d_size 32kB --l1d_assoc 8 --l1i_size 32kB --l2_size 2MB --l2_assoc 16 \
    --l2cache --caches --mode 0 --stt 0
done
```

## 4. Check the results

**How many slow (secret-encoding) divides fired?**

```bash
echo "secret 0: $(grep -c 'op_latency=24' $GEM5/mtp_eval/out_s0/fdchan.log)"
echo "secret 1: $(grep -c 'op_latency=24' $GEM5/mtp_eval/out_s1/fdchan.log)"
# expect: secret 0 -> 0,  secret 1 -> 1 or more (we saw 2, 3 and 5)
```

**The busy time of one slow divide** (this is the leak). Each divide prints an ISSUE
line and a FREE line. Busy time = free_tick - issue_tick; 500 ticks = 1 cycle.

```bash
SN=$(grep 'op_latency=24' $GEM5/mtp_eval/out_s1/fdchan.log | grep -oE 'sn:[0-9]+' | head -1)
grep "$SN" $GEM5/mtp_eval/out_s1/fdchan.log
# FREE tick minus ISSUE tick: about 11,500 ticks (23 cycles) for a slow divide,
# about 2,500 ticks (5 cycles) for a fast one -> the busy time depends on the secret
```

## 5. Check that the leaking divide is squashed (never commits)

Run secret 1 again with the commit trace on, then follow that one divide.

```bash
cd $GEM5/attacks
$GEM5/build/X86_MESI_Two_Level/gem5.opt --outdir=$GEM5/mtp_eval/out_commit \
  --debug-flags=FloatDivChan,Commit --debug-file=trace.log se_run_experiment.py \
  --mem-type SimpleMemory --cmd $GEM5/mtp_eval/bin/t_s1 \
  --cpu-type DerivO3CPU --cpu-clock 2GHz --sys-clock 2GHz \
  --l1d_size 32kB --l1d_assoc 8 --l1i_size 32kB --l2_size 2MB --l2_assoc 16 \
  --l2cache --caches --mode 0 --stt 0

T=$GEM5/mtp_eval/out_commit/trace.log
SN=$(grep 'op_latency=24' $T | grep -oE 'sn:[0-9]+' | head -1 | cut -d: -f2)
echo "slow divide = sn:$SN"

# it reaches the head of the ROB and is retired as squashed
# (-A1 also shows the next line, because "Retiring squashed..." has no sequence number)
grep -A1 "Trying to commit head instruction, \[sn:$SN\]" $T
# expect:
#   Trying to commit head instruction, [sn:...] [tid:0]
#   Retiring squashed instruction from ROB.

# and it is never actually committed
grep -c "Committing instruction with \[sn:$SN\]" $T
# expect 0
```

> The commit trace is large. Delete it when you're done: `rm $GEM5/mtp_eval/out_commit/trace.log`

## 6. Run under each DOLMA mode

Same secret-1 program with `--mode` 1 to 4. Modes 1 and 2 protect memory and
registers; modes 3 and 4 are the memory-only versions.

```bash
cd $GEM5/attacks
for M in 1 2 3 4; do
  $GEM5/build/X86_MESI_Two_Level/gem5.opt --outdir=$GEM5/mtp_eval/out_s1_m$M \
    --debug-flags=FloatDivChan --debug-file=fdchan.log se_run_experiment.py \
    --mem-type SimpleMemory --cmd $GEM5/mtp_eval/bin/t_s1 \
    --cpu-type DerivO3CPU --cpu-clock 2GHz --sys-clock 2GHz \
    --l1d_size 32kB --l1d_assoc 8 --l1i_size 32kB --l2_size 2MB --l2_assoc 16 \
    --l2cache --caches --mode $M --stt 0
  L=$GEM5/mtp_eval/out_s1_m$M/fdchan.log
  echo "mode $M: slow divides = $(grep -c 'op_latency=24' $L), restricted divides = $(grep -c 'restricted=1' $L)"
done
# expect: modes 1 and 2 -> slow 0.  Modes 3 and 4 -> slow above 0 (about 6), and the
# slow divide is flagged "restricted=1 ctrl=0 data=1".
# (modes 3 and 4 also contain one slow divide with a junk input that is the same for
#  secret 0 and secret 1; compare with the secret-0 run to see the secret-driven part)
```

For STT, add `--stt 1` to any of these. The expected result is 0 slow divides.

## Things that are easy to get wrong

1. **The `ls` problem** (top of this file). If a run dies at once with the `ld.so`
   message, or `fdchan.log` is empty, run `file -b` on the program first.

2. **Build with `-O0`, not `-O2`.** With an `-O2` build I measured 50 divides, all
   committed and none squashed: no transient divide ran at all, so the experiment
   shows nothing. The secret load and the divide are still in the `-O2` code, and I
   did not find out why the transient divide does not run. An earlier note blamed the
   operand not being visible in the register file; the measurements do not show that.
   `-O0` works, so use it.

3. **DOLMA is turned on only through `attacks/se_run_experiment.py`.** That script
   sets `cpu.mode`; stock `configs/example/se.py` never reads `--mode` (checked). The
   flag is `--mode 0..4`, not `--dolma`. Use `--caches --l2cache`. An earlier note
   says `--ruby` crashes this fork; I did not retest that.

4. **Rebuilding gem5.** The binary on the server already has the model changes, so
   you do not need to. If the model files ever change, your earlier notes say gem5
   builds only under Python 2:
   `python2 "$(which scons)" build/X86_MESI_Two_Level/gem5.opt -j$(nproc)`. I did not
   rebuild it myself.
