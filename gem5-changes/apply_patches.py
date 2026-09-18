#!/usr/bin/env python3
"""
Apply the model changes for the variable-time FloatDiv transmitter to a clean
DOLMA gem5 fork. Run from the gem5 root:

    python3 gem5-changes/apply_patches.py

The script is idempotent: running it twice makes no further changes. After it
runs, rebuild with the Python 2 scons command from the README.

Changes:
  1. src/cpu/o3/SConscript          register the FloatDivChan debug flag
  2. src/cpu/o3/inst_queue_impl.hh  operand-dependent divide latency + trace
  3. src/cpu/o3/FuncUnitConfig.py   dedicated single non-pipelined divider
  4. src/cpu/o3/FUPool.py           add that divider to the default pool
"""
import os
import re
import sys


def edit(path, fn):
    with open(path) as f:
        before = f.read()
    after = fn(before)
    if after != before:
        with open(path, "w") as f:
            f.write(after)
        print("patched", path)
    else:
        print("unchanged", path)


# 1. debug flag
def sconscript(s):
    if "FloatDivChan" in s:
        return s
    return s.replace("    DebugFlag('IQ')",
                     "    DebugFlag('IQ')\n    DebugFlag('FloatDivChan')", 1)


# 2. issue-logic latency hook + allocation/release trace
HOOK = """op_latency = fuPool->getOpLatency(op_class);
                // ==== variable-time FloatDiv transmitter hook ====
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
                    DPRINTF(FloatDivChan, "[sn:%lli] tid=%i ISSUE FloatDiv "
                            "trivial=%d op_latency=%d issue_tick=%llu "
                            "restricted=%d ctrl=%d data=%d squashed=%d\\n",
                            issuing_inst->seqNum, tid, trivial, op_latency,
                            (unsigned long long)curTick(),
                            issuing_inst->isDolmaRestricted(),
                            issuing_inst->isControlRestricted(),
                            issuing_inst->isDataRestricted(),
                            issuing_inst->isSquashed());
                }"""

FREE = ('DPRINTF(IQ, "Processing FU completion [sn:%lli]\\n", inst->seqNum);\n'
        '    if (inst->staticInst->opClass() == FloatDivOp ||\n'
        '        inst->staticInst->opClass() == SimdFloatDivOp)\n'
        '        DPRINTF(FloatDivChan, "[sn:%lli] tid=%i FREE FloatDiv '
        'free_tick=%llu squashed=%d\\n", inst->seqNum, inst->threadNumber,\n'
        '                (unsigned long long)curTick(), inst->isSquashed());')


def inst_queue(s):
    if '#include "debug/FloatDivChan.hh"' not in s:
        s = s.replace('#include "debug/IQ.hh"',
                      '#include "debug/IQ.hh"\n#include "debug/FloatDivChan.hh"', 1)
    if "variable-time FloatDiv transmitter hook" not in s:
        s = s.replace("op_latency = fuPool->getOpLatency(op_class);", HOOK, 1)
    if "FREE FloatDiv" not in s:
        s = s.replace(
            'DPRINTF(IQ, "Processing FU completion [sn:%lli]\\n", inst->seqNum);',
            FREE, 1)
    return s


# 3. dedicated single non-pipelined divider
DIV_CLASS = ("class SimdFP_Div(FUDesc):\n"
             "    opList = [ OpDesc(opClass='SimdFloatDiv', opLat=24, "
             "pipelined=False) ]\n"
             "    count = 1\n\n"
             "class ReadPort(FUDesc):")


def func_unit_config(s):
    if "class SimdFP_Div" in s:
        return s
    # remove SimdFloatDiv from the shared SIMD_Unit
    s = re.sub(r"\n[ \t]*OpDesc\(opClass='SimdFloatDiv'[^\n]*\n", "\n", s, count=1)
    # make FloatDiv explicitly non-pipelined (no-op if already so)
    s = s.replace("OpDesc(opClass='FloatDiv', opLat=12)",
                  "OpDesc(opClass='FloatDiv', opLat=12, pipelined=False)", 1)
    return s.replace("class ReadPort(FUDesc):", DIV_CLASS, 1)


# 4. add the divider to the default pool
def fu_pool(s):
    if "SimdFP_Div()" in s:
        return s
    return s.replace("SIMD_Unit(), WritePort()",
                     "SIMD_Unit(), SimdFP_Div(), WritePort()", 1)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    targets = [
        ("src/cpu/o3/SConscript", sconscript),
        ("src/cpu/o3/inst_queue_impl.hh", inst_queue),
        ("src/cpu/o3/FuncUnitConfig.py", func_unit_config),
        ("src/cpu/o3/FUPool.py", fu_pool),
    ]
    for rel, fn in targets:
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            print("missing", path, "(run from the gem5 root)")
            continue
        edit(path, fn)


if __name__ == "__main__":
    main()
