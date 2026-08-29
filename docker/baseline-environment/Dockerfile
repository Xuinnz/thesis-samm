# docker/baseline-environment/Dockerfile
#
# Build context MUST be the repository root, not this directory —
# this Dockerfile COPYs from profiler/ and server/ at the repo root.
# Build with:
#   docker build -f docker/baseline-environment/Dockerfile -t samm-baseline .
#
# This single image serves TWO distinct purposes in the study, toggled
# purely by the SHADOW_PROFILER_ENABLED env var at `docker run` time:
#
#   1. Characterization pass (profiler ON)  -> produces training_trace.csv
#   2. Final benchmark, 100 cycles (profiler OFF) -> baseline V8 condition
#
# Using ONE image for both is a deliberate methodological choice, not
# a convenience shortcut: it guarantees the environment that generates
# SAMM's training telemetry is byte-for-byte identical to the
# environment SAMM is later benchmarked against. Two separately built
# images — even from identical-looking Dockerfiles — would not offer
# that guarantee.

# ---------------------------------------------------------------------
# Stage 1: builder
# Compiles the Shadow Profiler native addon and installs production
# dependencies. Build tools (python3, make, g++) live ONLY here and
# never reach the final runtime image.
# ---------------------------------------------------------------------
FROM node:22-bookworm-slim AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        make \
        g++ \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# --- Build the native profiler addon ---
COPY profiler/package.json profiler/package-lock.json* ./profiler/
RUN cd profiler && npm install --omit=dev

COPY profiler/binding.gyp ./profiler/
COPY profiler/src ./profiler/src
COPY profiler/index.js ./profiler/
RUN cd profiler && npx node-gyp rebuild

# --- Install server dependencies ---
COPY server/baseline-v8/package.json server/baseline-v8/package-lock.json* ./server/baseline-v8/
RUN cd server/baseline-v8 && npm install --omit=dev

# ---------------------------------------------------------------------
# Stage 2: runtime
# No compiler toolchain here — smaller image, and it keeps the
# resource-constrained container's contents limited to exactly what
# runs during measurement (nothing that could plausibly affect RSS
# under the 1GB ceiling beyond the intended server + profiler).
# ---------------------------------------------------------------------
FROM node:22-bookworm-slim AS runtime

WORKDIR /app

# Profiler: compiled addon + JS wrapper (no source, no build tools needed)
COPY --from=builder /app/profiler/build ./profiler/build
COPY --from=builder /app/profiler/index.js ./profiler/
COPY --from=builder /app/profiler/node_modules ./profiler/node_modules
COPY --from=builder /app/profiler/package.json ./profiler/

# Server: shared routes + baseline entrypoint + its node_modules
COPY --from=builder /app/server/baseline-v8/node_modules ./server/baseline-v8/node_modules
COPY server/routes ./server/routes
COPY server/baseline-v8/server.js ./server/baseline-v8/
COPY server/baseline-v8/package.json ./server/baseline-v8/

# The profiler writes here by default (see profiler/index.js
# OUTPUT_PATH). Created up front so the container doesn't need
# write-permission surprises on first run; mount a host volume over
# this path during characterization so training_trace.csv survives
# after the container exits (see docker-compose.yml).
RUN mkdir -p /app/datasets/shadow-telemetry/raw

EXPOSE 3000

# Lightweight healthcheck hitting the server's own /health route.
# Uses Node directly rather than curl/wget to avoid adding packages
# to the runtime image.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD node -e "require('http').get('http://localhost:3000/health', (r) => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

WORKDIR /app/server/baseline-v8
CMD ["node", "server.js"]