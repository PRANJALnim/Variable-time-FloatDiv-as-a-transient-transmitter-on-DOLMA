/*
 * receiver.c -- covert-channel RECEIVER  (runs as the sibling SMT thread)
 * ---------------------------------------------------------------------------
 * Repeatedly times a batch of its OWN dependent divides. Each divide needs the
 * shared non-pipelined divider, so:
 *
 *   sender bit == 1 (divider busy) -> receiver divides must wait -> batch SLOW
 *   sender bit == 0 (divider free) -> receiver divides run freely -> batch FAST
 *
 * Prints one timing sample (in TSC cycles) per line. Run once against a
 * bit-1 sender and once against a bit-0 sender; the timing distributions
 * separate, and that separation IS the recovered secret bit.
 */
#include <stdio.h>
#include "cacheutils.h"

volatile double sink;

#ifndef SAMPLES
#define SAMPLES 200
#endif
#ifndef BATCH
#define BATCH   200         /* dependent divides timed per sample */
#endif

int main(void) {
    double acc = 1.0;

    for (int s = 0; s < SAMPLES; s++) {
        uint64_t t0 = rdtsc();
        for (int k = 0; k < BATCH; k++)
            acc = 7.0 / (acc + 1.0);      /* dependent -> serialised on divider */
        uint64_t t1 = rdtsc();
        printf("%llu\n", (unsigned long long)(t1 - t0));
    }

    sink = acc;
    return 0;
}
