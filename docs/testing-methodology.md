# Testing and Evaluation Methodology

This chapter describes how SAMM (Stratified Autonomous Memory Manager) is
evaluated. The evaluation has four parts: (1) validation of the profile-guided
model that produces the routing table, (2) a microbenchmark of allocation cost
in isolation, (3) an internal validation under controlled load, and (4) an
external validation, the main study, under a realistic workload. The chapter
closes with the statistical procedures applied to the main study. The rules
for choosing the load point and for treating terminated runs were fixed on
2026-11-13, before any data from the corresponding experiments was examined.

---

## 1. Experimental Environment

### 1.1 Hardware and operating system

All reported experiments run on a dedicated-core cloud virtual machine (Google
Cloud `t2d-standard-4`: four AMD EPYC cores without simultaneous
multithreading, 16 GB of memory) running Ubuntu 24.04 LTS on on-demand
capacity. Earlier measurements taken on a development laptop (AMD Ryzen 5
6600H under WSL2) are treated as pilot data. They are not combined with the
virtual-machine results.

The cores are allocated as follows: core 0 to the operating system, core 1 to
the server container, and cores 2 and 3 to the load generator. Separating the
load generator from the system under test prevents the two from competing for
CPU time.

### 1.2 Container constraints

Every server instance runs in a Docker container limited to **1,024 MB of
memory with swap disabled** (`--memory=1024m --memory-swap=1024m`) and **one
vCPU** (`--cpus=1.0`, pinned with `--cpuset-cpus=1`). These limits represent
the 1 GB-constrained microservice the thesis targets.

### 1.3 Software

Node.js 22 (`node:22-bookworm-slim`), k6 v0.55.0, Zig 0.15.2, and jemalloc
5.3.0 as the C allocator underneath both main-study conditions. The
environment record for each run includes the machine type, zone, kernel
version, Docker version, transparent huge page mode, container image
identifiers, and the SHA-256 hash of the compiled routing table.

### 1.4 Workload

The realistic workload replays traffic modelled on the Azure Functions 2019
trace. A Markov chain over traffic states sets the per-minute arrival rate;
payload sizes are drawn from the trace's memory distribution; and requests are
spread over six endpoints, each standing for one allocation pattern (`cache`,
`fetch`, `process`, `ingest`, `aggregate`, `batch`). A load factor *k* scales
the arrival rate by *k* and every deliberate hold time by 1/*k*. This keeps the
expected live memory (arrival rate × hold time, by Little's Law) constant while
CPU pressure rises with *k*.

Every random draw (traffic schedule, endpoint choice, payload size, hold time)
comes from a seeded generator, so a given seed produces a byte-identical
request stream.

---

## 2. Measurement Integrity Controls

### 2.1 Host health probe

Before each batch of runs and at least once a day, a host probe
(`internal-validation/host-probe.sh`) checks that the machine is fit to
measure:

1. **Clock rate.** The monotonic clock is compared against an NTP server over
   60 seconds and must run within ±1 % of real time. With chrony running, the
   clock must also be reported as synchronised.
2. **Load-generator start-up time.** The time for k6 to build its first virtual
   user must stay within a limit set from the reference run.
3. **V8 allocation microbenchmark.** Must stay within 0.90–1.10× of the
   reference.
4. **Garbage-collection time per collection.** Must not exceed 1.10× the
   reference.

The reference is recorded once on the virtual machine, and the limit for check
2 is derived from it. Both are written down before any benchmark is run and
are not changed afterwards. A failed probe stops the campaign until the cause
is resolved.

### 2.2 Observer-effect controls

The lifetime profiler, the garbage-collection observer and the per-second
allocator statistics endpoint all execute inside the measured process. They
are therefore disabled in every measured run and used only in separate
instrumented runs whose performance figures are not reported. Container
metrics (memory, CPU, page faults) are read from the host's cgroup files,
which costs the container nothing.

### 2.3 Software verification

Before experiments begin, the allocator's test suite must pass: table-compiler
fixture tests, Zig unit tests (hash parity, routing, bump and slab arenas),
zero-copy, finalizer reclamation and deterministic region-reclamation tests,
and the dashboard rendering tests.

---

## 3. Model Validation

### 3.1 Workload characterization

The workload is profiled at *k* = 1.0 (maximum 500 requests per second, 10
minutes, seed 19870601) with the shadow profiler enabled. Profiling at a load
well below the machine's saturation point keeps queueing delay from inflating
the observed object lifetimes. The resulting trace is summarised per call site
(allocation sizes, lifetimes, overhang past request end, concurrency) and
compared with the pilot profile as a sanity check: sizes should agree, while
timings may differ between machines.

### 3.2 Layer 1: reachability oracle

**Purpose.** Layer 1 assigns each call site either to a managed arena, whose
memory is reclaimed when the request's region closes, or to the System heap.
The classifier is trained on overhang measured at finalization, which includes
garbage-collection delay. Its decisions are therefore validated against an
independent ground truth: whether each object is still reachable after its
request has ended.

**Procedure.** The baseline server is run with the profiler disabled and a
reachability oracle enabled. The oracle holds a weak reference to every Buffer
allocated and forces a full, synchronous garbage collection every 10 ms. An
object that survives a forced collection was reachable at that instant.
Reachability is monotone, so each object's death time is bounded between the
last collection that found it alive and the first that found it dead. This
interval is compared with the end of the object's request. The workload uses
the training load's allocation shape at a reduced arrival rate (maximum 100
requests per second, 5 minutes). It is run twice: once with the training seed
and once with a held-out seed (2025).

**Classification of objects.** With slack δ = 50 ms after request end, an
object is labelled *request-scoped* if it was found dead within δ. It is
labelled *escaped* if a collection found it alive later than δ; escaped
objects are further divided into *brief* (dead within 1 s) and *long*. Objects
whose death interval straddles the threshold are labelled *ambiguous*, and
objects still alive at shutdown are *censored*. Ambiguous and censored objects
are excluded from scoring.

**Scoring.** Following the evaluation of allocation-site pretenuring by
Blackburn et al., each decision is graded:

| Ground truth \ Decision | Managed (Bump or Slab) | System heap |
|---|---|---|
| Request-scoped | Good | Neutral (missed optimisation) |
| Escaped | Bad (brief or long) | Neutral (correct) |

Grades are reported weighted by object count, by bytes, and by byte-seconds
(bytes × lifetime). They are reported per call site and in aggregate, together
with their sensitivity to δ (0–1,000 ms) and to slower collection rates
replayed offline, and the agreement of each site's label between the two
seeds. Reachability is a necessary but not a sufficient condition for harm, so
the "bad" share is an upper bound on misrouting harm.

### 3.3 Layer 3: data-derived pool ceiling

**Purpose.** The pool ceiling has previously been set as a fixed fraction β =
0.75 of the memory available after the V8 baseline and the System reservation
are deducted. Memory outside the pool (the V8 heap, the System heap, refused
allocations served by malloc, and page cache) cannot be observed during
characterization, which runs without SAMM. β is therefore derived from a run
with SAMM.

**Procedure.** SAMM is run at the locked load point (Section 5.4) with
per-second sampling of its committed pool bytes and the container's memory.
Memory outside the pool is computed as memory.current − committed bytes. The
ceiling is set to C = container limit − peak outside-pool memory − 32 MB
margin, and β = C ÷ pool hard limit. The table is recompiled with this β and
the run repeated once, because a different ceiling changes the volume of
fallback allocations. The table is then frozen for all subsequent experiments,
and its hash, workload fingerprint and image identifier are recorded.

---

## 4. Microbenchmark

**Purpose.** To measure the cost of an allocation in isolation, separated from
network, scheduling and request-handling effects.

**Procedure.** Allocation traces extracted from the characterization run are
replayed against seven allocator layers (from the raw arena engine to the
complete Node.js path) and against V8's own Buffer allocation. Each runs with
and without page writes, five trials per cell, plus thirty trials for the
`aggregate` trace, on one pinned core.

**Measures.** Nanoseconds per allocation, and the breakdown of an allocation's
time across layers.

---

## 5. Internal Validation

### 5.1 Purpose and rationale

Under realistic traffic, throughput and latency move together: bursts raise
both at once, so a difference between allocators cannot be attributed to
either. The internal validation separates them by measuring throughput under
constant saturation and latency under constant, unsaturated load.

### 5.2 Configurations

glibc malloc, jemalloc, and SAMM (on jemalloc). Where implemented,
page-retaining jemalloc, SAMM with page return, tuned glibc, and an
application-level Buffer pool are added.

### 5.3 Experiments

**Experiment I-1: Calibration.** A closed-loop load is stepped through
increasing numbers of virtual users (e.g. 50 to 500). For each configuration
this identifies the knee where throughput stops rising, the capacity (highest
valid throughput), the saturation level used in Experiment I-2, and the rates
for Experiment I-3.

**Experiment I-2: Throughput at saturation.** A closed-loop load with a fixed
number of virtual users keeps the server saturated throughout. The measure is
completed requests per second in a steady measurement window, with CPU time
per request and page faults per request as explanatory measures. A run is
valid only if the CPU was saturated, no request failed, no out-of-memory kill
occurred, and throughput was stable within the window (coefficient of
variation and drift within limits).

**Experiment I-3: Latency below saturation.** An open-loop load at fixed
arrival rates below saturation. The measure is the full distribution of
processing time, defined as request duration minus the request's deliberate
hold time, reported at p50, p90, p95, p99 and p99.9. Two comparisons are made:
all configurations at the same absolute rates, and each configuration at the
same fraction (80 % and 95 %) of its own capacity.

**Experiment I-4: Instrumented run.** Experiment I-2 is repeated for SAMM with
allocator counters sampled each second (fallback allocations, budget
refusals, detach failures). Its performance figures are not reported.

**Experiment I-5: Order control.** Experiments I-1 to I-3 are repeated with
the configuration order reversed, to detect drift over the session.

### 5.4 Selection of the stress point

The main study runs at the machine's near-saturation stress point, which is
located before the study begins by a rule fixed in advance.

**Rule.** The stress point is the lowest load factor *k* whose peak arrival
rate is at or above the capacity of both configurations, as measured by the
closed-loop calibration (Experiment I-1). Under an open-loop workload a server
cannot serve more than it is offered, so at any lower load the achieved
throughput of the configuration with the higher capacity would reflect the
offered rate rather than its own limit, and the difference between the
configurations would be understated. The rule draws on the calibration, an
experiment separate from the main study, and applies the same criterion to
both configurations.

**Survival guard.** Before the study, the baseline is run at the selected *k*
for 10 minutes on three seeds. If fewer than two of the three runs complete,
the load is reduced by one level for both configurations, and the change is
recorded.

---

## 6. External Validation (Main Study)

### 6.1 Design

A two-condition comparison:

- **Control:** the Node.js server with V8's default Buffer allocation on
  jemalloc.
- **Treatment:** the same server with SAMM on jemalloc.

Both run on the same C allocator, so the arena allocator is the only
difference between them. The study uses **n = 100 replicates per condition**,
each a 10-minute run of the realistic workload at the locked stress point.

### 6.2 Seeds and ordering

Each of the 100 replicates is assigned its own seed, and both conditions within
a replicate use it. The two conditions therefore serve identical request
streams within a replicate, while the seeds vary across replicates so that the
workload distribution is sampled rather than a single fixed draw. The order of
the two conditions alternates between replicates, so that slow drift in the
host and any effect of running first are spread equally across conditions.
Each result records its seed, order position, image identifier and
routing-table hash.

### 6.3 Dependent variables

| Variable | Definition |
|---|---|
| **Throughput** | Achieved requests per second over the run (k6 `http_reqs` rate). Dropped requests count against it. |
| **Tail latency** | 99th percentile of processing time (p95 also reported) |
| **Peak memory** | Peak resident memory of the container (cgroup `memory.peak`, reset at the start of the run) |

CPU utilisation, page faults per request, dropped and failed requests,
end-to-end latency, and allocator counters are recorded as supporting
measures.

### 6.4 Supporting runs

A pilot of two to three runs precedes the study to confirm stability. A
separate garbage-collection-instrumented pass records collection counts and
pause times. Its other figures are not used, because the observer perturbs the
treatment condition.

### 6.5 Hypotheses

For each dependent variable *m*:

- H₀: there is no difference in *m* between the SAMM engine and the baseline V8
  engine.
- H₁: there is a difference in *m* between them (two-sided).

---

## 7. Supplementary Experiments

These address questions raised by the review panel. They use smaller samples
(about 15–20 replicates per condition) and are reported as secondary results.

**S-1: Memory limit.** The study is repeated at 2 GB and 4 GB container limits.
The routing table and β are re-derived for each limit, because Layer 3 sizes
the pool from the container's limit. Runs use the main-study load. Optionally,
they are repeated with hold times scaled ×2 and ×4 to keep memory pressure
proportional to the limit.

**S-2: Traffic drift.** Traffic models are built separately from days 1–7 and
days 8–14 of the Azure trace. The table is trained on the first week and
evaluated on both, contrasting in-distribution and shifted traffic. The second
week is measured on the first week's scale (its traffic-state thresholds and
its memory anchor), because on its own percentiles every week is a quarter idle
and a quarter busy by construction. Memory percentiles are published for days
1–12 only, so the second week's payload model uses days 8–12. Each week's
traffic character (share of burst and idle states, request rates, hold times)
is reported.

---

## 8. Statistical Analysis

### 8.1 Assumption checks

For each dependent variable, the normality of each condition's sample is
tested with the **Shapiro–Wilk test** and the homogeneity of the two variances
with **Levene's test**.

### 8.2 Hypothesis tests

- **Independent-samples t-test.** If both normality and homogeneity of
  variance hold for a metric, an independent-samples t-test compares the mean
  of the SAMM engine with that of the baseline V8 engine.
- **Mann–Whitney U test.** If either assumption is violated for a metric, the
  Mann–Whitney U test is applied as the non-parametric alternative (McKnight &
  Najab, 2010).

Because both conditions in a replicate share a seed (Section 6.2), the two
samples are positively related rather than strictly independent. Tests for
independent samples do not use that relation, and when it is positive they
overstate the variance of the difference. They are therefore conservative
here: a true difference is harder to declare significant, and a false one is
not made easier.

### 8.3 Multiple comparisons and significance

Three dependent variables are tested on the same data, so a **Bonferroni
correction** is applied (Abdi, 2007): the significance level is α = 0.05 / 3 ≈
**0.017** per metric. A p-value below 0.017 for a metric leads to rejection of
the null hypothesis for that metric.

### 8.4 Practical effect

The **relative percentage difference** between the conditions is calculated
for each metric: the reduction in peak resident memory, the change in tail
latency, and the difference in mean sustained throughput.

### 8.5 Runs terminated by an out-of-memory kill

A terminated run's metrics cover only the time it ran, so it is excluded from
that condition's sample for the three tests; the tests accommodate unequal
sample sizes. Survival is reported separately, as the number of completed runs
per condition. Because the runs that complete are the less demanding ones,
excluding terminated runs favours the condition that lost more of them. As a
check, throughput over the full 10-minute window is also reported with
terminated runs included. If more than about 10 % of a condition's runs are
terminated, survival is reported as the principal result and the metric tests
are qualified accordingly.

### 8.6 Classifier evaluation

The Layer 1 oracle matrix (Section 3.2) is reported descriptively: the
proportions of good, bad and neutral decisions under each weighting, with
their sensitivity to δ and the agreement of each site's label between the
training seed and the held-out seed.

---

## 9. Threats to Validity

- **Internal.** Host variability is controlled by the health probe, core
  pinning, paired seeds and order rotation. Instrumentation is confined to
  runs whose performance figures are not reported.
- **Construct.** Processing time removes deliberate hold time from request
  duration. Reachability, as used by the oracle, is an upper bound on misuse.
  Container memory includes page cache charged to the cgroup.
- **External.** The workload is synthetic, though modelled on a production
  trace. Results apply to Buffer-heavy Node.js services under a 1 GB limit,
  extended to 2 and 4 GB by experiment S-1. Layer 1's fixed two-cluster split
  assumes a workload contains both request-scoped and escaping call sites.
- **Conclusion.** Bonferroni correction controls the family-wise error rate.
  The selection rules of Sections 5.4 and 8.5 were fixed before the data they
  govern were examined. The shared seed makes the independent-samples tests
  conservative (Section 8.2).
