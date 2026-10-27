/*
 * sender.c -- covert-channel SENDER  (runs as one SMT thread)
 * ---------------------------------------------------------------------------
 * Modulates the SHARED non-pipelined FloatDiv unit according to a secret bit:
 *
 *   bit == 1 : a dependent chain of divides -> the divider is kept BUSY
 *   bit == 0 : only additions               -> the divider is left FREE
 *
 * The receiver on the sibling SMT thread senses this as divider contention.
 * The bit is read from argv[1] (default 1). This is the transmit side of a
 * functional-unit-contention channel -- the sender legitimately knows its own
 * secret, so a branch on the bit here is fine (the covert part is that the
 * effect leaks across threads through shared-FU timing).
 */
#include <stdlib.h>

volatile double sink;

#ifndef ITERS
#define ITERS 2000000L      /* long enough to outlast the receiver's sampling */
#endif

int main(int argc, char **argv) {
    int    bit = (argc > 1) ? atoi(argv[1]) : 1;
    double acc = 1.0;

    if (bit) {
        /* dependent divides: one outstanding divide at a time, back to back,
         * so the single divider is ~continuously occupied. */
        for (long i = 0; i < ITERS; i++)
            acc = 7.0 / (acc + 1.0);
    } else {
        /* only adds: the divider is never requested. */
        for (long i = 0; i < ITERS; i++)
            acc = acc + 1.0000001;
    }

    sink = acc;             /* keep the work live */
    return 0;
}
