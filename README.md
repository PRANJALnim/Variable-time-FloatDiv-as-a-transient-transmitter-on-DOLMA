# Variable-time FloatDiv as a transient transmitter on DOLMA

DOLMA is a speculative-execution defense built on transient non-observability.
As a performance optimization it lets some variable-time arithmetic execute
speculatively, on the assumption that transient operand values cannot influence
the timing of non-transient instructions. The gem5 model used in the original
DOLMA evaluation gives every FP/ALU operation a constant latency, so that
assumption is never actually tested for operand-dependent arithmetic.

This project adds operand-dependent latency to the FloatDiv unit in the DOLMA
gem5 model and checks whether the divide can act as a transient transmitter:

    S  ->  x(S)  ->  L_FloatDiv(x)  ->  O_FU(S)

A transient secret bit S selects, without any secret-dependent branch, the
operand of a single divide. The divide's latency depends on that operand, and
because the divider is non-pipelined its busy interval (occupancy) becomes
secret-dependent. The occupancy is then read back across an SMT sibling thread
by timing contention for the shared divider.

## What is demonstrated

1. Transmitter primitive. The same opcode on the same functional unit, with only
   the operand changing as a function of a transient secret, produces a
   different functional-unit busy interval. The transmitting divide runs on a
   mispredicted path and is squashed, so it never commits.

2. Covert channel (baseline). A sender and a receiver run as the two SMT threads
   of one out-of-order core and share a single non-pipelined divider. The sender
   modulates the divider by a secret bit; the receiver recovers the bit by timing
   its own divides. Under baseline the two cases separate cleanly and the bit is
   recovered with no errors.

## Layout

    src/                 sender/receiver/transmitter sources and timing helpers
    gem5-changes/        the model changes, and a script that applies them
    scripts/             build and run helpers
    results/             measured numbers from the runs
    docs/                short writeup of how it works

## Requirements

- The DOLMA gem5 fork (github.com/efeslab/dolma), x86, Ruby MESI_Two_Level.
- This fork builds under Python 2 only.
- A C compiler for the workload binaries.

Paths below assume the fork lives at $GEM5 and the workspace at $GEM5/mtp_eval.

## Applying the model changes

    cd $GEM5
    python3 gem5-changes/apply_patches.py       # or follow gem5-changes/NOTES.md by hand
    python2 "$(which scons)" build/X86_MESI_Two_Level/gem5.opt -j$(nproc)

The changes are:

- FloatDiv/SimdFloatDiv get an operand-dependent latency in the issue logic
  (fast when a source operand is zero, slow otherwise).
- SimdFloatDiv is pulled out of the shared SIMD unit into a dedicated,
  non-pipelined divider with count 1, so both SMT threads contend for it.
- A FloatDivChan debug flag prints functional-unit allocation and release, so
  the busy interval, thread id, sequence number and squash status are visible.

gem5-changes/NOTES.md lists the exact edits, file by file.

## Building the workloads

    cd $GEM5/mtp_eval/src
    gcc -O0 -static -o ../transmitter transmitter.c
    gcc -O0 -static -o ../sender      sender.c
    gcc -O0 -static -o ../receiver    receiver.c

-O0 keeps the divide and the guarding branch intact; -static is required for
gem5 syscall-emulation mode.

## Running

Transmitter primitive (secret 0 vs secret 1):

    scripts/run_transmitter.sh

Covert channel (sender bit 1 vs bit 0):

    scripts/run_channel.sh

Both scripts print the numbers used in results/RESULTS.md.

## Notes on the model

The occupancy leak only exists because the divider is non-pipelined. A pipelined
unit is released the cycle after issue regardless of latency, so its busy
interval would not depend on the operand. This is the property the FloatDiv unit
already has in the model, and the one the SimdFloatDiv unit is given here.
