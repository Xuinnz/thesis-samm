# docker/samm-environment/Dockerfile
#
# Build context MUST be the repository root, not this directory —
# this Dockerfile COPYs from profiler/, zig-allocator/ and server/ at
# the repo root. Build with:
#   docker build -f docker/samm-environment/Dockerfile -t samm-enabled .
#
# Experimental-group image. Deliberately mirrors
# docker/baseline-environment/Dockerfile layer for layer — same base
# image, same Node version, same profiler build, same runtime contents —
# so that the only difference between the two measured conditions is
# the presence of the Zig sidecar allocator and the branch it enables
# in server/routes/_alloc-utils.js. Anything else that differed between
# the images would be a confound in the comparison.

# ---------------------------------------------------------------------
# Stage 1: builder
# Compiles the Shadow Profiler addon AND the Zig allocator, then
# installs production dependencies. Build tools (python3, make, g++,
# zig) live ONLY here and never reach the runtime image.
# ---------------------------------------------------------------------
FROM node:22-bookworm-slim AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        make \
        g++ \
        curl \
        xz-utils \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Pinned, not "latest": the allocator uses std.Build and std.posix APIs
# that move between Zig releases, and a silently newer toolchain would
# be an uncontrolled variable in a measured build.
ARG ZIG_VERSION=0.15.2
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
        | tar -xJ -C /opt \
    && ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig \
    && zig version

WORKDIR /app

# --- Build the native profiler addon ---
# Also populates node-gyp's header cache, which the Zig build needs.
COPY profiler/package.json profiler/package-lock.json* ./profiler/
RUN cd profiler && npm install --omit=dev

COPY profiler/binding.gyp ./profiler/
COPY profiler/src ./profiler/src
COPY profiler/index.js ./profiler/
RUN cd profiler && npx node-gyp rebuild

# --- Build the Zig sidecar allocator ---
# The header path is passed explicitly rather than left to build.zig's
# `node -v` probe: in a container the cache location is known exactly,
# and an explicit path fails loudly instead of silently building against
# the wrong Node version's headers.
COPY zig-allocator/build.zig ./zig-allocator/
COPY zig-allocator/src ./zig-allocator/src
COPY zig-allocator/index.js ./zig-allocator/
RUN cd zig-allocator && \
    zig build -Doptimize=ReleaseFast \
        -Dnode-headers="/root/.cache/node-gyp/$(node -v | sed 's/^v//')/include/node" && \
    test -f zig-out/lib/samm_allocator.node

# --- Install server dependencies ---
COPY server/samm-enabled/package.json server/samm-enabled/package-lock.json* ./server/samm-enabled/
RUN cd server/samm-enabled && npm install --omit=dev

# ---------------------------------------------------------------------
# Stage 2: runtime
# No compiler toolchain here — keeps the resource-constrained
# container's contents limited to exactly what runs during measurement.
# ---------------------------------------------------------------------
FROM node:22-bookworm-slim AS runtime

# jemalloc, mirroring the baseline image. Installed but NOT active: it only
# takes effect when LD_PRELOAD names it at `docker run` time. Present so the
# SAMM condition can be run on the same C allocator as the baseline it is
# compared against -- SAMM still uses malloc for System-classified call-sites,
# capacity fallbacks and Node's own internals, so leaving it on glibc while the
# baseline runs jemalloc would compare two things at once.
RUN apt-get update && \
    apt-get install -y --no-install-recommends libjemalloc2 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Profiler: compiled addon + JS wrapper
COPY --from=builder /app/profiler/build ./profiler/build
COPY --from=builder /app/profiler/index.js ./profiler/
COPY --from=builder /app/profiler/node_modules ./profiler/node_modules
COPY --from=builder /app/profiler/package.json ./profiler/

# Allocator: compiled .node addon + JS wrapper
COPY --from=builder /app/zig-allocator/zig-out ./zig-allocator/zig-out
COPY --from=builder /app/zig-allocator/index.js ./zig-allocator/
# Boot-time guard: the table is only valid for the workload it was fit against.
COPY zig-allocator/workload_check.js ./zig-allocator/
COPY zig-allocator/workload_fingerprint.json ./zig-allocator/

# Server: shared routes + samm entrypoint + its node_modules
COPY --from=builder /app/server/samm-enabled/node_modules ./server/samm-enabled/node_modules
COPY server/routes ./server/routes
COPY server/samm-enabled/server.js ./server/samm-enabled/
COPY server/samm-enabled/package.json ./server/samm-enabled/

RUN mkdir -p /app/datasets/shadow-telemetry/raw

# This image exists only to run the allocator-routed condition, so the
# switch is on by default. server.js refuses to start without it rather
# than quietly producing baseline numbers under a SAMM label.
ENV SAMM_ALLOCATOR_ENABLED=true

EXPOSE 3000

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD node -e "require('http').get('http://localhost:3000/health', (r) => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

WORKDIR /app/server/samm-enabled
CMD ["node", "server.js"]
