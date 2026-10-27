#ifndef CACHEUTILS_H
#define CACHEUTILS_H
#include <stdint.h>
static inline void flush(void *p){ asm volatile("clflush 0(%0)\n"::"c"(p):"rax"); }
static inline void mfence(void){ asm volatile("mfence":::"memory"); }
static inline void lfence(void){ asm volatile("lfence":::"memory"); }
static inline void maccess(void *p){ asm volatile("movq (%0), %%rax\n"::"c"(p):"rax"); }
static inline uint64_t rdtsc(void){
    uint32_t lo,hi;
    asm volatile("lfence\n\trdtsc\n\tlfence\n\t":"=a"(lo),"=d"(hi)::"memory");
    return ((uint64_t)hi<<32)|lo;
}
#endif
