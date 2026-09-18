/*
 * cacheutils.h
 * ---------------------------------------------------------------------------
 * Tiny subset of transient-fail's libcache used by the FloatDiv experiments.
 * Adds rdtsc() for the covert-channel receiver's timing.
 */
#ifndef CACHEUTILS_H
#define CACHEUTILS_H

#include <stdint.h>

/* Evict one address from the cache (widen a speculation window). */
static inline void flush(void *p) {
    asm volatile("clflush 0(%0)\n" : : "c"(p) : "rax");
}

/* Memory-ordering fences. */
static inline void mfence(void) { asm volatile("mfence" ::: "memory"); }
static inline void lfence(void) { asm volatile("lfence" ::: "memory"); }

/* Touch a byte so the compiler cannot optimise the access away. */
static inline void maccess(void *p) {
    asm volatile("movq (%0), %%rax\n" : : "c"(p) : "rax");
}

/* Serialised timestamp counter -- the receiver's clock. */
static inline uint64_t rdtsc(void) {
    uint32_t lo, hi;
    asm volatile("lfence\n\t"
                 "rdtsc\n\t"
                 "lfence\n\t"
                 : "=a"(lo), "=d"(hi)::"memory");
    return ((uint64_t)hi << 32) | lo;
}

#endif /* CACHEUTILS_H */
