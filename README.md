# thesis-samm
##  SAMM: Stratified Autonomous Memory Management
A Profile-Guided Arena Allocator for Deterministic Memory Management in 1GB-Constrained Node.JS Microservices

## Brief Rationale
The global semiconductor industry's pivot toward high-bandwidth memory for AI workloads has triggered a sustained contraction in general-purpose DRAM supply, driving up costs and making the traditional strategy of "scaling out" memory-hungry applications economically unviable. This forces a return to software-level efficiency, yet Node.js's default V8 garbage collector was never designed for this constraint: its reactive, generational heuristics treat the heap as an undifferentiated space, causing short-lived and long-lived objects to interleave, fragment memory into unusable "Swiss cheese" patterns, and trigger unpredictable stop-the-world pauses that culminate in premature out-of-memory crashes.

Existing mitigations, such as arena-based allocation, only partially address this because they rely on static, manually authored rules that cannot adapt to the evolving, non-linear object lifespans of real production workloads. Meanwhile, machine-learning-based allocators like LLAMA prove predictive routing can reduce fragmentation substantially, but their reliance on live neural inference introduces latency penalties incompatible with nanosecond-scale allocation budgets.

This gap — between the adaptability of predictive models and the determinism required by constrained systems — motivates SAMM: an architecture that moves the intelligence offline, compiles it into a static O(1) routing table, and executes it through a lightweight Zig sidecar. The rationale is thus twofold: economically, extending the useful life of memory-constrained infrastructure through better software rather than more hardware; and architecturally, proving that predictive determinism is achievable without paying an inference tax at runtime.

## Objectives
This study aims to empirically evaluate the architectural viability of the Stratified Autonomous Memory Manager (SAMM) as a deterministic alternative to Node.js's default V8 garbage collector under strict 1GB memory constraints. Specifically, it seeks to characterize the memory and execution performance of the Baseline V8 Engine under near-saturation stress, in terms of Peak Resident Set Size, P99 tail latency, and mean sustained throughput.

It further aims to characterize the same performance dimensions for the SAMM Engine under identical stress conditions, capturing how offline K-means temporal clustering, statistical variance thresholding, and proportional spatial quota enforcement jointly affect memory density and latency predictability.

Finally, the study aims to determine whether the observed differences between SAMM and the Baseline V8 Engine across these three metrics are statistically significant, using Bonferroni-adjusted inferential testing, in order to establish whether the architectural intervention produces a measurable and defensible improvement over reactive garbage collection in resource-constrained environments.

## Methodology
This research employs a quantitative experimental design using systems-level benchmarking under a controlled two-condition comparative methodology, with System Type (Baseline V8 vs. Full SAMM Architecture) as the sole independent variable. Prior to comparative testing, a preliminary ML output validation run verifies routing accuracy via a misclassification matrix before the system is subjected to high-concurrency stress. The study draws on a hybrid data strategy: the Azure Functions Trace 2019 dataset parameterizes realistic Markov-chain traffic states, Gaussian jitter, and payload-size distributions for the Grafana k6 load generator, while primary telemetry (call-site hashes, allocation sizes, object lifespans) is captured via a native Shadow Profiler using Node.js's napi_add_finalizer mechanism, active only during the offline training phase to avoid contaminating performance measurements.

Collected telemetry feeds an offline ML Refinery built in Python (scikit-learn, pandas), which performs K-means clustering with K-means++ seeding and Elbow-Method K-selection to discover temporal strata, computes per-call-site variance to assign Bump or Slab allocation policies, and calculates high-watermark spatial quotas to partition the 1GB heap proportionally. These outputs are compiled into a static routing table consumed by a Zig sidecar allocator interfaced with Node.js via Node-API's zero-copy buffer mechanism, bypassing the V8 heap entirely during execution.

For the primary benchmarking stage, both conditions are subjected to identical burst-traffic workloads across n = 200 independent test cycles (100 per condition) within Docker containers capped at 1.0 vCPU and 1GB RAM with swap disabled. Resulting data on Peak RSS, P99 latency, and mean sustained throughput undergo Shapiro-Wilk and Levene's assumption testing, followed by an independent samples t-test or Mann-Whitney U test as appropriate, with a Bonferroni-adjusted significance threshold of α = 0.017 applied across the three metrics.


## Project Repository
```bash
samm-thesis/
├── .github/
│   └── workflows/                # CI/CD pipelines for automated statistical runs and Zig builds
├── datasets/
│   ├── azure-trace-2019/
│   │   ├── raw/                  # Original invocations and memory files from Shahrad et al.
│   │   └── processed/            # Filtered dataset containing only burst-eligible HTTP traffic
│   └── shadow-telemetry/
│       ├── raw/                  # training_trace.csv (Call-Site ID, Alloc Size, Lifespan)
│       └── processed/            # Cleaned telemetry after right-censoring removal
├── preprocessing/
│   ├── phase1-azure-simulation/
│   │   ├── 01-data-cleaning/     # Scripts for HTTP filtering, burst qualification, and zero treatment
│   │   ├── 02-data-transformation/ # Markov-chain transition matrix and Gaussian jitter extraction
│   │   └── 03-normalization/     # Scripts scaling Azure memory percentiles relative to 1GB P99
│   └── phase2-ml-telemetry/
│       ├── 04-missing-value-handling/ # Drops records where finalization_time IS NULL
│       ├── 05-feature-engineering/ # Computes mean (μ) and variance (σ²) per call-site
│       └── 06-log-transformation/  # Applies log(x+1) to lifespans to prevent centroid collapse
├── load-generator/
│   ├── k6-scenarios/             # Grafana k6 scripts that execute the test cycles
│   └── traffic-models/           # State machines driving Ramp/Burst/Cooldown/Idle states
├── ml-refinery/
│   ├── clustering/               # K-means++ logic to discover temporal strata (Short/Medium/Long)
│   ├── policy-assignment/        # Routes low-variance (low std) sites to Bump, high-variance to Slab
│   ├── quota-calculation/        # Computes the high-watermark spatial partitions for the 1GB heap
│   └── table-compiler/           # Bakes the clustering decisions into a static O(1) routing table
├── profiler/
│   ├── src/                      # Native C++/Zig source for napi_add_finalizer lifespan tracking
│   └── bindings/                 # Build configuration for the Node-API middleware
├── server/
│   ├── baseline-v8/              # Control group: standard Node.js microservice relying on default GC
│   ├── samm-enabled/             # Experimental group: microservice bypassing V8 for managed objects
│   └── routes/                   # Shared REST API endpoints for benchmark parity
├── zig-allocator/
│   ├── src/
│   │   ├── node-api-interface/   # Zero-copy buffer mechanism bridging JS and native memory
│   │   ├── routing-table/        # The O(1) execution engine that intercepts allocations
│   │   └── arenas/
│   │       ├── bump-allocator/   # Linear allocation for highly predictable, low-variance objects
│   │       └── slab-allocator/   # Fixed-size pool allocation for noisy, higher-variance objects
│   └── tests/                    # Zig unit tests for memory safety and router accuracy
├── stats-eval/
│   ├── assumption-testing/       # Shapiro-Wilk and Levene's tests for normality/homoscedasticity
│   ├── hypothesis-testing/       # t-tests / Mann-Whitney U with Bonferroni correction (α = 0.017)
│   └── matrix-validation/        # Pre-stress test routing misclassification matrix generators
├── docker/
│   ├── baseline-environment/     # Dockerfile capped at 1GB RAM, 1.0 vCPU, swap disabled
│   └── samm-environment/         # Identical constraints but configured with the Zig sidecar
└── docs/
    ├── manuscript/               # Thesis paper source (LaTeX or Markdown)
    ├── diagrams/                 # Mermaid/PlantUML source for architecture flows
    └── figures/                  # Generated plots for Peak RSS, P99 latency, and throughput
```