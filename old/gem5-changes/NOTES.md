# Model changes, file by file

These are the exact edits `apply_patches.py` makes. They can also be applied by
hand. Line numbers are approximate and refer to the DOLMA fork.

## src/cpu/o3/SConscript

Register a debug flag next to the existing ones:

    DebugFlag('FloatDivChan')

## src/cpu/o3/inst_queue_impl.hh

Include the generated flag header next to the other debug includes:

    #include "debug/FloatDivChan.hh"

In `scheduleReadyInsts()`, right after the operation latency is looked up:

    op_latency = fuPool->getOpLatency(op_class);

insert the operand-dependent latency. A divide with a zero source operand is
fast, otherwise slow. The value is read from the source registers at issue, so
it works for transient operands too. `SimdFloatDivOp` is the opclass gcc emits
for `divsd` on x86; `FloatDivOp` is the x87 divide. Both are covered:

    if (op_class == FloatDivOp || op_class == SimdFloatDivOp) {
        bool trivial = false;
        for (int i = 0; i < issuing_inst->numSrcRegs(); ++i) {
            if (!issuing_inst->srcRegIdx(i).isFloatReg())
                continue;
            uint64_t bits = cpu->readFloatRegBits(
                                issuing_inst->renamedSrcRegIdx(i));
            if ((bits & 0x7fffffffffffffffULL) == 0ULL)
                trivial = true;
        }
        op_latency = trivial ? Cycles(6) : Cycles(24);
        DPRINTF(FloatDivChan, "[sn:%lli] tid=%i ISSUE FloatDiv trivial=%d "
                "op_latency=%d issue_tick=%llu restricted=%d ctrl=%d data=%d "
                "squashed=%d\n", issuing_inst->seqNum, tid, trivial, op_latency,
                (unsigned long long)curTick(), issuing_inst->isDolmaRestricted(),
                issuing_inst->isControlRestricted(),
                issuing_inst->isDataRestricted(), issuing_inst->isSquashed());
    }

In `processFUCompletion()`, after:

    DPRINTF(IQ, "Processing FU completion [sn:%lli]\n", inst->seqNum);

log the release so the busy interval can be measured as release minus issue:

    if (inst->staticInst->opClass() == FloatDivOp ||
        inst->staticInst->opClass() == SimdFloatDivOp)
        DPRINTF(FloatDivChan, "[sn:%lli] tid=%i FREE FloatDiv free_tick=%llu "
                "squashed=%d\n", inst->seqNum, inst->threadNumber,
                (unsigned long long)curTick(), inst->isSquashed());

Why this gives a secret-dependent busy interval: the divider is non-pipelined, so
the issue logic frees the unit through the completion event scheduled at
`op_latency`, not on the next cycle. Making `op_latency` operand-dependent
therefore makes the occupancy operand-dependent.

## src/cpu/o3/FuncUnitConfig.py

By default `SimdFloatDiv` sits inside the four-wide `SIMD_Unit`. With four copies,
two SMT threads each get their own divider and never contend. Remove it from
`SIMD_Unit` and give it a dedicated unit with a single copy:

    class SimdFP_Div(FUDesc):
        opList = [ OpDesc(opClass='SimdFloatDiv', opLat=24, pipelined=False) ]
        count = 1

`FloatDiv` in `FP_MultDiv` is already non-pipelined in this fork; the script
leaves it as is (or makes it explicit if it was pipelined).

## src/cpu/o3/FUPool.py

Add the new unit to the default pool:

    FUList = [ IntALU(), IntMultDiv(), FP_ALU(), FP_MultDiv(), ReadPort(),
               SIMD_Unit(), SimdFP_Div(), WritePort(), RdWrPort(), IprPort() ]

## Rebuild

These files are compiled into gem5, so a rebuild is required:

    python2 "$(which scons)" build/X86_MESI_Two_Level/gem5.opt -j$(nproc)
