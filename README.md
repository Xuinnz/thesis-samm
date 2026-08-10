# thesis-samm


### Project Repository
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