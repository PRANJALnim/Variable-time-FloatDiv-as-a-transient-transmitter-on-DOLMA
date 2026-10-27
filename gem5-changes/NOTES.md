# The gem5 model changes, in plain words

Four files in the DOLMA gem5 fork are changed. The full, authoritative diff is
`model_changes.patch` (this is the real `git diff` taken from the server, not a
reconstruction). Apply it from the gem5 root with:

    cd /home/mtp/pranjal
    git apply mtp_eval/.../model_changes.patch      # or:  patch -p1 < model_changes.patch

Then rebuild (Python 2):

    python2 "$(which scons)" build/X86_MESI_Two_Level/gem5.opt -j$(nproc)

The four changes and why each is needed:

## 1. `src/cpu/o3/FuncUnitConfig.py` — make the divider a single, slow, non-pipelined unit

By default `SimdFloatDiv` (the SSE double-precision divide, `divsd`) lives inside
the shared `SIMD_Unit`, which has `count = 4`. With four copies, the two SMT
threads never actually fight over one divider. The change:

- removes `SimdFloatDiv` from `SIMD_Unit`, and
- adds a dedicated unit with **one** copy that is **non-pipelined**:

      class SimdFP_Div(FUDesc):
          opList = [ OpDesc(opClass='SimdFloatDiv', opLat=24, pipelined=False) ]
          count = 1

Non-pipelined is the key property: the unit stays *busy for the whole operation*,
so how long it is occupied equals the operation latency.

## 2. `src/cpu/o3/FUPool.py` — actually install that unit

`SimdFP_Div()` is added to `DefaultFUPool.FUList` so the CPU really builds one.

## 3. `src/cpu/o3/inst_queue_impl.hh` — make the divide's latency depend on its operand

This is the heart of the experiment. When a divide is about to issue, the model
now looks at the *value* of its floating-point source operand:

- if a source operand is zero  -> latency = **6** cycles  (fast)
- otherwise                    -> latency = **24** cycles (slow)

The value is read from the register file at issue time, so it works even for a
transient (speculative) operand. It matches **both** `FloatDivOp` (x87 `fdiv`)
and `SimdFloatDivOp` (SSE `divsd`) — gcc emits `divsd`, so `SimdFloatDivOp` is
the one that matters here.

Two debug traces are added under a new `FloatDivChan` flag:
- an **ISSUE** line (latency, operand class, and the DOLMA restricted/squashed
  status of the instruction), and
- a **FREE** line when the functional unit is released.

So the functional-unit busy interval is simply `free_tick - issue_tick`.

## 4. `src/cpu/o3/SConscript` — register the `FloatDivChan` debug flag

Needed so the traces above compile and can be turned on with
`--debug-flags=FloatDivChan`.

---

# The required investigation (answered from this fork's code)

The full version, with file names and the evidence, is Section 2 of the report. In
short:

1. **How are FloatDiv operations mapped to functional units?**
   By op class. `divsd` is the macro-op `DIVSD_XMM_XMM`, which is the micro-op
   `mdivf` with `op_class = 'SimdFloatDivOp'`. `FUPool::getUnit(opClass, seqNum)`
   returns the first unit that supports that class and is not marked busy, and marks
   it busy by storing the instruction's sequence number in `unitBusy[idx]`. In the
   stock configuration this class lived in the 4-copy `SIMD_Unit` with the default
   `opLat = 1` and `pipelined = True`; after the change it is the dedicated
   `SimdFP_Div`.

2. **Pipelined or non-pipelined?**
   Stock `divsd`: pipelined, 1 cycle, so it could never be a transmitter. After the
   change: non-pipelined. (Pipelining is a property of the op class: it is cleared
   if any unit lists the class as non-pipelined.) The old x87 `FloatDiv` in
   `FP_MultDiv` is non-pipelined with 12 cycles.

3. **How long does the unit stay busy after a multi-cycle op issues?**
   `op_latency` cycles. The issue logic schedules an `FUCompletion` event
   `op_latency - 1` cycles after issue; for a non-pipelined op that event frees the
   unit, and the unit is usable again the cycle after. In the traces FREE appears
   exactly `op_latency - 1` cycles after ISSUE (23 and 5 cycles for latencies 24
   and 6).

4. **How is the unit eventually released?**
   `FUCompletion::process()` calls `processFUCompletion()`, which calls
   `FUPool::freeUnitNextCycle(fu_idx)`. That queues the unit on `unitsToBeFreed`, and
   `FUPool::processFreeUnits()` (called every cycle from `DefaultIEW`) clears
   `unitBusy[idx]`. The FREE trace line is printed inside `processFUCompletion()`.
   A squashed instruction still holds the unit for the full time.

Because the unit is non-pipelined (points 2 and 3) and the latency is now
operand-dependent (change 3), the **busy interval becomes operand-dependent**, and
the operand is chosen by the secret, so the busy interval encodes the secret.
