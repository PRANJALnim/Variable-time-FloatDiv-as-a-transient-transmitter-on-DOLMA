# Results (baseline model, no defense)

All runs use the DerivO3CPU with classic caches. The Ruby path is not needed for
this experiment and its se.py wiring is broken in this fork, so runs use
`--caches --l2cache` rather than `--ruby`.

## 1. Transmitter primitive

The transmitter is a single divide reached through a mistrained bounds check.
The guard `if (idx < array_size)` is trained taken, then called out of bounds;
the divide runs on the mispredicted path and is squashed. The divide's operand
is `x = (double)secret_bit`, so the operand is zero for secret 0 and non-zero for
secret 1. The model makes a zero-operand divide fast and a non-zero divide slow.

Same dynamic instruction, two runs that differ only in the secret byte:

    seqNum 50225   secret 0:  op_latency = 6    (trivial operand)
    seqNum 50225   secret 1:  op_latency = 24   (non-trivial operand)

Functional-unit busy interval for that instruction, measured from the
allocation and release trace (1000 ticks = 2 cycles at 2 GHz):

    secret 0:  free - issue = 36,278,500 - 36,276,000 =  2,500 ticks  (~5 cyc)
    secret 1:  free - issue = 36,287,500 - 36,276,000 = 11,500 ticks  (~23 cyc)

The instruction is squashed, not committed. In the commit trace the divide
reaches the head of the reorder buffer and is discarded:

    Trying to commit head instruction, [sn:50225]
    Retiring squashed instruction from ROB.

Both secret runs finish at the identical simulated tick (45,599,500), which
confirms the divide has no architectural effect.

This establishes the required chain: transient secret -> operand-dependent divide
latency -> secret-dependent functional-unit occupancy -> squashed.

## 2. Covert channel

Sender and receiver run as the two SMT threads of one core and share a single
non-pipelined divider. The sender keeps the divider busy for secret bit 1 and
leaves it free for secret bit 0. The receiver times batches of its own divides.

Receiver batch time (TSC cycles), 200 samples per run:

    sender bit = 1 :  median 9637   (min 9380, max 9656)
    sender bit = 0 :  median 6839   (min 6838, max 6973)

The distributions do not overlap: the slowest bit-0 sample (6973) is well below
the fastest bit-1 sample (9380). A threshold near 8000 recovers the bit with no
errors across all samples. The receiver therefore reads the secret purely from
contention for the shared divider.

## Reproducing

Run `scripts/run_transmitter.sh` and `scripts/run_channel.sh`. Exact seqNums and
tick values depend on the build but the two-way separation is stable.
