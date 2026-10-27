# Validating Variable-Time FloatDiv as a Transient Transmitter on DOLMA

**Analyzing Security of DOLMA — IIT Kharagpur, CSE**

All results below were produced on the DOLMA gem5 fork running on `compute-1`
(`/home/mtp/pranjal`) and are backed by the files in `proof/`. Every number in this
report can be found in those files.

---

## 1. What the assignment asks

DOLMA is a defense against speculative-execution attacks. One optimisation it
allows is letting *variable-time arithmetic* run speculatively, as long as the
transient operand does not change the timing of non-transient instructions. The
original gem5 model gives every ALU/FPU op a **constant** latency, so that case
was never actually tested.

The task is to show, independently, that a `FloatDiv`-like unit can be a
**transient transmitter**: that the time the shared divider stays busy can be
made to depend on a secret. Formally:

    S  ->  x(S)  ->  L_FloatDiv(x)  ->  O_FU(S)

a secret `S` picks (with **no secret-dependent branch**) the operand `x` of one
divide; the divide's latency `L` depends on `x`; and because the divider is
non-pipelined, its occupancy `O_FU` depends on `S`.

Building the full cross-SMT channel is **not** required here (that is done anyway,
beyond scope, in `../Complete_Work/`).

---

## 2. Required investigation (how the fork models the FP divider)

Studied directly in the fork's source. File names are relative to `src/`.

1. **Mapping.** `divsd` is the macro-op `DIVSD_XMM_XMM`
   (`arch/x86/isa/insts/simd128/floating_point/arithmetic/division.py`), which is
   the micro-op `mdivf`, class `Mdivf` with `op_class = 'SimdFloatDivOp'`
   (`arch/x86/isa/microops/mediaop.isa`). The pool of functional units is built from
   a list of unit descriptions; each lists the op classes it can run. At issue,
   `FUPool::getUnit(opClass, seqNum)` (`cpu/o3/fu_pool.cc`) walks the units that
   support the class, returns the first one not marked busy, and marks it busy by
   storing the instruction's sequence number in `unitBusy[idx]`. In the stock
   configuration `SimdFloatDiv` lives in `SIMD_Unit` (4 copies) and its `OpDesc`
   uses the defaults, `opLat = 1` and `pipelined = True` (`cpu/FuncUnit.py`). The
   older x87 `FloatDiv` lives in `FP_MultDiv` (2 copies, 12 cycles, non-pipelined).
   A fresh run confirms which class the compiled program uses: 100 issues of
   `SimdFloatDiv` and 0 of `FloatDiv` (`proof/stats_excerpt.txt`).
2. **Pipelined or not.** Stock `divsd` is **pipelined with a 1-cycle latency**, so
   as shipped it cannot be a transmitter: its busy time is always one cycle. The
   `x87` divide is non-pipelined. Pipelining is a property of the op *class* in
   this model: `pipelined[opClass]` is cleared if any unit lists that class as
   non-pipelined (`fu_pool.cc`, constructor). After my change the divider is
   non-pipelined (`proof/fupool_from_config.txt`).
3. **How long it stays busy.** In `scheduleReadyInsts()` (`cpu/o3/inst_queue_impl.hh`)
   a multi-cycle op gets an `FUCompletion` event scheduled `op_latency - 1` cycles
   after issue. For a non-pipelined op that event is marked to free the unit; for a
   pipelined op the unit is queued to be freed right away. The unit is therefore
   busy for `op_latency` cycles in total. In the traces, FREE comes exactly
   `op_latency - 1` cycles after ISSUE: 23 cycles for latency 24 and 5 for latency 6.
4. **How it is released.** When the event fires, `FUCompletion::process()` calls
   `processFUCompletion()`, which calls `FUPool::freeUnitNextCycle(fu_idx)`. That puts
   the unit on `unitsToBeFreed`, and `FUPool::processFreeUnits()` — called once per
   cycle from `DefaultIEW` (`cpu/o3/iew_impl.hh`) — clears `unitBusy[idx]`. The unit
   is usable again one cycle after the FREE trace line, i.e. `op_latency` cycles after
   issue. A squashed instruction still holds the unit for the full time: all 48 divides
   that were already squashed when they released the unit were busy for the full
   5 cycles (`proof/busy_by_squash_status.txt`).

Conclusion of the investigation: with a non-pipelined unit, **busy interval =
op_latency**. So if `op_latency` is made operand-dependent, occupancy becomes
operand-dependent.

---

## 3. The model change

Four small edits (full diff: `gem5-changes/model_changes.patch`, explained in
`gem5-changes/NOTES.md`):

- **`FuncUnitConfig.py` / `FUPool.py`** — pull `SimdFloatDiv` out of the 4-wide
  shared SIMD unit and give it a dedicated unit with **one** copy that is
  **non-pipelined** (`SimdFP_Div`, `opLat=24`, `pipelined=False`). One copy means
  the two SMT threads must share it; non-pipelined means occupancy = latency.
- **`inst_queue_impl.hh`** — at issue, read the *value* of the divide's
  floating-point source operands from the register file: if a source is zero the
  latency is **6** cycles, otherwise **24**. This is the operand-dependent latency.
  A `divsd` shows three float sources in the trace (the dividend, the divisor, and
  the dividend register again, because it is also the destination); in this program
  the divisor is 3.0, so only the dividend can be zero. The
  hook covers both `FloatDivOp` and `SimdFloatDivOp`. Two trace lines (ISSUE, FREE)
  are emitted under a new `FloatDivChan` debug flag, recording latency, the
  instruction's DOLMA status, and whether it is squashed.
- **`SConscript`** — register the `FloatDivChan` flag.

The exact values 6 and 24 are arbitrary. The assignment only needs
`L(fast) != L(slow)`.

The binary on the server already contains these changes: its `config.ini` shows the
dedicated unit (`proof/fupool_from_config.txt`), and `--debug-help` lists the
`FloatDivChan` flag.

---

## 4. The transmitter (no secret-dependent branch)

`src/transmitter.c`. The secret becomes the operand with plain arithmetic, not a
branch:

```c
uint8_t s = region.pub[idx] & 1u;   // transient secret bit (read out of bounds)
double  x = (double)s;              // branchless: secret -> operand
double  z = x / DIVISOR;            // the ONE transmitting divide (divsd)
```

- `S = 0` → `x = 0.0` → divide hits the **fast** (6-cycle) class.
- `S = 1` → `x = 1.0` → divide hits the **slow** (24-cycle) class.

The secret is reached only on a mistrained bounds check (`if (idx < array_size)`
trained taken, then called out of bounds with the bound flushed so it resolves
late), so the divide runs **transiently** and is squashed. The only branch is that
bounds check, and it depends on the index, not on the secret. Exactly one `divsd`
instruction is emitted (`objdump`: `divsd %xmm1,%xmm0`), so the *same opcode on
the same unit* is used for both secret values. The two binaries differ only in the
constant stored into `region.secret`.

---

## 5. The seven required demonstrations — with evidence

| # | What must be shown | Result | Evidence file |
|---|---|---|---|
| 1 | Same FU class in both secret cases | `SimdFP_Div` (FUList6), 100 `SimdFloatDiv` issues | `fupool_from_config.txt`, `stats_excerpt.txt` |
| 2 | Same opcode in both cases | one `divsd` (`SimdFloatDivOp`) | `verify_run.log` (objdump) |
| 3 | Only the operand differs with the secret | `x=(double)s`, branchless | `src/transmitter.c` |
| 4 | Operand → different latency | 6 cyc (S=0) vs 24 cyc (S=1) | `base_s0.fdchan.log`, `base_s1.fdchan.log` |
| 5 | Latency → different FU busy interval | 2,500 vs 11,500 ticks | `base_s1.fdchan.log`, `busy_by_squash_status.txt` |
| 6 | Op may run while transient / DOLMA-restricted | DOLMA modes 3 and 4: divide issues `restricted=1`, slow | `pipeline_join_modes_0_1_3.txt`, `operand_bits_secret1.txt` |
| 7 | Op is eventually squashed, never commits | committed=0, "Retiring squashed" | `squash_proof.txt` |

### Details

**Points 1–4 — baseline counts.** Running the two secret binaries with no defense
(`--mode 0`):

    transmitter_s0  slow(op_latency=24)=0   fast(=6)=100
    transmitter_s1  slow(op_latency=24)=2   fast(=6)=98

Secret 0 produces **no** slow divide; secret 1 produces slow divides. Same unit,
same `divsd`, only the operand changed. (`verify_run.log`, STEP 1.) The count for
secret 1 is not a constant of nature: the same source built at two other paths gave
**5** and **3** slow divides instead of 2 (`operand_bits_secret1.txt`,
`script_run_transmitter.txt`), while secret 0 always gave 0. What matters is zero
versus more than zero.

**Point 5 — the busy interval actually differs.** For secret 1, the slow divide
`sn:49256` (`base_s1.fdchan.log`):

    ISSUE ... op_latency=24 issue_tick=34267500
    FREE  ...               free_tick =34279000     busy = 11,500 ticks (23 cyc)

A fast divide in the same run: busy = **2,500 ticks (5 cyc)**. At 2 GHz, 500 ticks
= 1 cycle. The unit then becomes reusable one cycle after FREE (Section 2). The
occupancy of the shared unit is secret-dependent — this is the transmitter.

**Point 6 — runs while transient / DOLMA-restricted.** In the memory-only DOLMA
modes (`--mode 3` and `4`) the divide that carries the secret is flagged restricted
by DOLMA, yet it issues, gets the slow latency, and is later squashed:

    [sn:50536] ISSUE FloatDiv trivial=0 op_latency=24 restricted=1 ctrl=0 data=1   (mode 3)

The pipeline trace shows the chain for that instance
(`pipeline_join_modes_0_1_3.txt`): the secret-byte load completes at tick
35,535,000, the reload of the converted value at 35,539,500, and the divide issues
at 35,540,000, one cycle later, with dividend 1.0. Under full DOLMA (`--mode 1`
and `2`) this never happens; Section 6 explains the difference.

**Point 7 — eventually squashed, never commits.** Re-running secret 1 with the
commit trace and following the slow divide `sn:49256` end to end
(`squash_proof.txt`):

    [sn:49256] ISSUE FloatDiv ... op_latency=24     tick 34,267,500   (it executed...)
    [sn:49256] FREE  FloatDiv ... squashed=0        tick 34,279,000   (...and occupied the FU)
    commit: Trying to commit head instruction, [sn:49256]   tick 34,321,500
    commit: Retiring squashed instruction from ROB.         (squashed, not committed)

The "Committing instruction with [sn:49256]" line never appears (committed
count = 0). The divide finished using the unit before it was squashed (FREE shows
`squashed=0`; it was retired as squashed 42,500 ticks, 85 cycles, later). So the
transmitting divide occupies the shared unit during the transient window, then is
squashed and has no architectural effect. As a cross-check, a secret-1 run issued
100 `SimdFloatDiv` ops and committed 50, exactly the 50 in-bounds rounds; the
secret-carrying divides can only come from the out-of-bounds rounds, which are
never architecturally executed (`stats_excerpt.txt`).

---

## 6. Which DOLMA modes let the transmitter fire (all five modes + STT)

DOLMA has five modes, plus an STT comparison switch (`cpu/base.cc`):

- 0 = off
- 1 = DOLMA-Default, 2 = DOLMA-Conservative — memory **and** register protection
  ("M+R")
- 3 = DOLMA-Default Memory-Only, 4 = DOLMA-Conservative Memory-Only — memory
  protection only ("M")
- `--stt 1` turns a DOLMA mode into its STT (speculative taint tracking) equivalent

"Fires" below means a secret-driven slow divide occurs, i.e. the occupancy depends
on the secret. It does **not** mean a second thread can see it; that is the next
experiment (Section 8).

**Table A — first sweep** (binary at `mtp_eval/transmitter_s1`; `proof/dolma_modes_table.txt`).
Slow (24-cycle) divides for secret 1:

| mode | config | slow divides | fires? |
|---|---|---|---|
| 0 | Baseline | 2 | yes |
| 1 | DOLMA-Default (M+R) | 0 | no |
| 2 | DOLMA-Conservative (M+R) | 0 | no |
| 3 | DOLMA-Default (M) | 6 | yes |
| 4 | DOLMA-Conservative (M) | 8 | yes |
| 1 | STT-Spectre (M+R) | 0 | no |
| 2 | STT-Futuristic (M+R) | 0 | no |
| 3 | STT-Spectre (M) | 0 | no |
| 4 | STT-Futuristic (M) | 0 | no |

**Table B — the same experiment on a second build** (binary at
`mtp_eval/study_verify/bin`, STT off; `operand_bits_secret1.txt`,
`operand_bits_secret0.txt`). Each divide's operand was recorded at issue:

| mode | slow, secret 1 | of which dividend = 1.0 | slow, secret 0 |
|---|---|---|---|
| 0 | 5 | 5 | 0 |
| 1 | 0 | 0 | 0 |
| 2 | 0 | 0 | 0 |
| 3 | 6 | 5 | 1 |
| 4 | 10 | 9 | 1 |

The two tables agree on the pattern: the transmitter fires in modes 0, 3 and 4 and
not in modes 1 and 2. A third run, by the final `verify_modes.sh` at yet another
path, gave 3, 0, 0, 6, 6 for modes 0 to 4 and 0 for all four STT settings
(`script_run_modes.txt`). The counts move with the build, so only the
zero/non-zero pattern should be quoted.

**The one extra slow divide in modes 3 and 4 is not the secret.** In both
secret-1 and secret-0 runs the same divide (`sn:47645` in mode 3, `sn:57146` in
mode 4) has a junk dividend, `0x4bd0e0`, that is neither 0 nor 1.0. It is slow only
because the junk is non-zero. The cause was not traced; a reload that runs ahead of
the store it depends on would produce it (that is a guess). This is why the
secret-driven count is the "dividend = 1.0" column.

**Why the modes differ.**

* *Code.* `ROB::insertInst` sets control restriction on every instruction younger
  than an unresolved branch only when `!isDolmaMemOnly()`, so modes 3 and 4 skip it
  (`cpu/o3/rob_impl.hh`). In the memory-only modes a load that is younger than an
  unresolved branch becomes a *data inducer*, and its dependents get
  `data=1` (`inst_queue_impl.hh`, `wakeDependentInstructions`). The traces agree:
  every restricted divide in modes 3 and 4 is `restricted=1 ctrl=0 data=1`, while
  `ctrl=1` shows up only in modes 1 and 2 (154 of 204 divides in mode 1, the other 50
  being unrestricted; 163 of 213 in mode 2, the other 50 being `ctrl=0 data=1`).
* *Pipeline trace* (`pipeline_join_modes_0_1_3.txt`, secret 1). This trace is a
  partial record: it captured 153 of the 199 divides issued in mode 1, 69 of 106 in
  mode 0 and 55 of 109 in mode 3 (I did not find out why). Among the squashed
  divides it did capture, those whose secret-byte load had already finished before
  the divide issued number 5 in mode 0 (all five secret divides), 5 in mode 3 (four
  with dividend 1.0 plus the junk one), and **none of the 115 in mode 1**. In mode 0
  the load completes about 9 cycles before the reload and the divide issues one
  cycle after that. So in the full-DOLMA modes the divide does not just see a stale
  register: the secret load itself has not finished when the divide issues. The
  population-level evidence is stronger still: none of the 402 divides issued in
  modes 1 and 2 had the dividend 1.0.
* *What is not established.* Where exactly the secret load is held back in modes 1
  and 2. Ordinary in-bounds loads still issue before their guarding branch resolves
  in mode 1 (98 of the 100 retired records of the secret-byte load), so it is not a
  blanket "wait for the branch" rule. The control restriction that only M+R applies
  is the obvious candidate, but I did not trace the stall point.

**What this means.** In the memory-only modes a restricted divide runs with the
secret and holds the unit for the longer time. DOLMA states that it allows
variable-time arithmetic on transient data and relies on its contention rules to
keep that unobservable, so this is the primitive the assignment asks about, present
under that configuration. In the full modes the secret never reaches the divide, so
there is nothing to observe. STT (Table A) stops it in every mode; STT stalls
restricted loads (`inst_queue_impl.hh`).

---

## 7. Conclusion

All seven points hold, with logs to back each one:

> **Transient secret → operand-dependent FloatDiv latency → secret-dependent FU occupancy.**

`FloatDiv` (specifically the SSE `divsd` / `SimdFloatDivOp`) is validated as a
candidate transient transmitter on this DOLMA gem5 model. The primitive fires with no
defense and under both memory-only DOLMA modes (`--mode 3`, `4`), where the divide is
DOLMA-restricted and still produces the slow occupancy. It does not fire under
full DOLMA (`--mode 1`, `2`) or STT, because the secret never reaches the divide's
operand there.

---

## 8. Limits of this result

* **The latency rule is a controlled model**, as the assignment asks: a divide with a
  zero source takes 6 cycles, otherwise 24. It says nothing about real hardware.
* **"Fires" is not "observable".** I showed the unit's occupancy depends on the
  secret. Whether a sibling SMT thread can measure it through DOLMA's contention
  rules is the cross-SMT experiment. One lead: the code that evicts a younger
  restricted occupant looks the occupant up with
  `rob->findInst(issuing_inst->threadNumber, ...)`, and `findInst` searches only
  that thread's own list, so an occupant from the other thread would not be found.
  I have not tested what that does.
* **The hook reads the register file at issue**, which can lag the value being
  forwarded. The junk-dividend divide above is a visible case, so slow-divide counts
  are a little noisy.
* **The compiler matters.** Built with `-O2`, the same source produced 50 divides,
  all committed, none squashed and none with the secret: no transient divide ran at
  all (`operand_bits_secret1.txt`, last block). The secret load and the divide are
  still in the `-O2` code; why the transient divide does not run was not traced.
  Use `-O0`.
* **Small samples.** Two to ten secret-driven events per run. For a fixed binary at
  a fixed path the simulator is deterministic: three repeats of the baseline run
  gave identical counts, and the DOLMA counts (154 and 213 restricted divides)
  matched logs made days earlier.

---

## 9. Scope note

The assignment asks only for the transmitter primitive, which is everything
above. The full sibling-SMT covert channel (sender/receiver sharing the one
divider, the receiver recovering the bit by timing contention) is **not required
here** and is included separately in `../Complete_Work/` with its own verified
results.

---

## 10. How to reproduce

See `run.md` for exact, paste-able commands. In short, on `compute-1`:

```bash
cd /home/mtp/pranjal/mtp_eval
bash verify_transmitter.sh        # rebuilds -O0, runs Section 5, prints the numbers
bash verify_modes.sh              # Section 6: secret 1 across all 5 modes + STT
```

**Read this first.** On compute-1 the system `ls` overwrites executables in the
folder it is run in (`../Complete_Work/SERVER_SECURITY_NOTE.md`). Do not run `ls` in
a folder that holds your binaries, and check each binary with `file -b` before a
run: it must say `statically linked`. The scripts do this check.
