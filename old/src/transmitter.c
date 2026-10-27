/*
 * transmitter.c -- FloatDiv transient-transmitter primitive (gem5 / DOLMA)
 *
 *        S  ->  x(S)  ->  L_FloatDiv(x)  ->  O_FU(S)
 *
 * A transient secret bit selects, without a secret-dependent branch, the
 * operand of one divide. The patched model makes the divide's latency depend on
 * the operand (fast when a source operand is zero, slow otherwise), so on a
 * non-pipelined divider the busy interval becomes secret-dependent. The result
 * is never read here; the leak (functional-unit occupancy) is observed from the
 * model through the FloatDivChan debug flag.
 *
 * Layout follows a Spectre-PHT proof of concept: train the bounds check taken,
 * flush the bound so it resolves late, then call out of bounds so the divide
 * runs transiently and is squashed.
 *
 * Build the two secret cases with -DSEC=0 and -DSEC=1.
 */
#include <stdint.h>
#include <stddef.h>
#include "cacheutils.h"

#ifndef SEC
#define SEC 0
#endif

#define TRAIN_ROUNDS 60
#define OOB_EVERY    6
#define DIVISOR      3.0
#define ARRAY_SIZE   16

static struct {
    uint8_t pub[ARRAY_SIZE];
    uint8_t secret;
} region;

uint64_t        array_size = ARRAY_SIZE;   /* the bound, kept in memory */
volatile double sink;

static void transmit(size_t idx) {
    if (idx < array_size) {                  /* branch we mistrain then squash */
        uint8_t s = region.pub[idx] & 1u;    /* transient secret bit           */
        double  x = (double)s;               /* branchless secret -> operand    */
        double  z = x / DIVISOR;             /* the transmitting divide         */
        sink += z;                           /* consume transiently             */
    }
}

int main(void) {
    for (size_t i = 0; i < ARRAY_SIZE; i++) region.pub[i] = 0;
    region.secret = SEC;
    const size_t oob_index = ARRAY_SIZE;     /* pub[ARRAY_SIZE] == secret */

    for (int round = 0; round < TRAIN_ROUNDS; round++) {
        flush(&array_size);                  /* widen the speculation window */
        mfence();
        size_t idx = (round % OOB_EVERY == OOB_EVERY - 1)
                       ? oob_index
                       : (size_t)(round % ARRAY_SIZE);
        transmit(idx);
        mfence();
    }
    return 0;
}
