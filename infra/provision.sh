#!/usr/bin/env bash
#
# provision.sh -- run ONCE on a fresh benchmark VM (Ubuntu 24.04), as the login
# user. Installs exactly the tool versions the study uses, clones the
# repository, builds the two images and records the environment.
#
#   curl/scp this file to the VM, then:   bash provision.sh <git clone URL>
#
# Safe to run again: each step checks before it installs.
set -euo pipefail

REPO_URL="${1:?usage: provision.sh <git clone URL of samm-final>}"
K6_VERSION=0.55.0
ZIG_VERSION=0.15.2
NODE_MAJOR=22

say() { printf '\n== %s\n' "$*"; }

say "system packages"
sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates curl git jq tmux xz-utils util-linux \
  python3 python3-venv python3-pip build-essential chrony

say "Docker"
if ! command -v docker >/dev/null; then
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER"
fi

say "Node $NODE_MAJOR"
if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]')" != "$NODE_MAJOR" ]; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
  sudo apt-get install -y -qq nodejs
fi

say "k6 v$K6_VERSION"
if ! k6 version 2>/dev/null | grep -q "v$K6_VERSION"; then
  curl -fsSL "https://github.com/grafana/k6/releases/download/v${K6_VERSION}/k6-v${K6_VERSION}-linux-amd64.tar.gz" | tar -xz -C /tmp
  sudo install -m 0755 "/tmp/k6-v${K6_VERSION}-linux-amd64/k6" /usr/local/bin/k6
fi

say "Zig $ZIG_VERSION"
if ! zig version 2>/dev/null | grep -qx "$ZIG_VERSION"; then
  curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" | sudo tar -xJ -C /opt
  sudo ln -sf "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig
fi

say "repository"
[ -d "$HOME/samm-final/.git" ] || git clone "$REPO_URL" "$HOME/samm-final"
cd "$HOME/samm-final"

say "Python environment"
[ -x venv/bin/python ] || python3 -m venv venv
venv/bin/pip install -q -r requirements.txt

say "Node headers for the Zig addon build (zig-allocator/build.zig reads node-gyp's cache)"
npx --yes node-gyp install >/dev/null

say "images (sg docker: the group change above is not active in this shell yet)"
sg docker -c "docker build -q -f docker/baseline-environment/Dockerfile -t samm-baseline:bench . && \
              docker build -q -f docker/samm-environment/Dockerfile -t samm-enabled:bench ."

say "environment record -> infra-environment.txt"
{
  echo "date: $(date -u +%FT%TZ)"
  echo "machine type: $(curl -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/machine-type || echo unknown)"
  echo "zone: $(curl -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/zone || echo unknown)"
  echo "cpu: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2-)  x$(nproc), threads per core: $(lscpu | awk -F: '/Thread\(s\) per core/{gsub(/ /,"",$2); print $2}')"
  echo "kernel: $(uname -r)"
  echo "cgroup: $(stat -fc %T /sys/fs/cgroup)   (the study needs cgroup2fs)"
  echo "swap: $(swapon --show --noheadings | wc -l) device(s)   (the study needs 0)"
  echo "THP enabled: $(cat /sys/kernel/mm/transparent_hugepage/enabled)   defrag: $(cat /sys/kernel/mm/transparent_hugepage/defrag)   (the design expects madvise)"
  echo "docker: $(sg docker -c 'docker version -f {{.Server.Version}}')   node: $(node --version)   k6: $(k6 version | head -1)   zig: $(zig version)   python: $(venv/bin/python --version)"
  echo "images: $(sg docker -c "docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep -E 'samm-(baseline|enabled):bench' | tr '\n' ' '")"
  echo "clock: $(chronyc tracking | grep -E 'Leap status|System time' | tr '\n' ' ')"
  echo "repository: $(git rev-parse HEAD)"
} | tee infra-environment.txt

cat <<'NEXT'

Done. Log out and back in once (so `docker` works without sg), then:
  cd ~/samm-final/zig-allocator && PATH="$PWD/../venv/bin:$PATH" ./run_tests.sh
  cd ~/samm-final && PROBE_CPU=1 internal-validation/host-probe.sh results/probe-reference reference
and continue with docs/vm-test-plan.md, Phase 3.
NEXT
