# infra: the benchmark VM

Three scripts, no infrastructure-as-code tool: there is one VM, and stopping
and starting it is a single `gcloud` command.

| Script | Where it runs | What it does |
|---|---|---|
| `vm.sh` | laptop (needs the `gcloud` CLI) | create, start, stop, status, ssh, fetch results, delete |
| `provision.sh` | the VM, once | installs Docker, Node 22, k6 v0.55.0, Zig 0.15.2, the Python environment and the Node headers; clones the repository; builds both images; writes `infra-environment.txt` |
| `then-poweroff.sh` | the VM | runs a long job and powers the VM off when it ends |

**Not yet run against a real project.** They were written and syntax-checked on
the laptop, where `gcloud` is not installed; the download URLs were checked,
and `then-poweroff.sh` was tested with `KEEP_ON=1`. Expect to fix small things
on first use.

## First time

On the laptop, after installing the gcloud CLI and `gcloud auth login`:

```bash
export GCP_PROJECT=<your project id>
```

```bash
infra/vm.sh create
```

```bash
infra/vm.sh ssh
```

On the VM (copy `infra/provision.sh` over first, or paste it):

```bash
bash provision.sh https://github.com/<you>/samm-final.git
```

Log out and back in, run the test suite and record the probe reference as the
script's last lines say, then follow `docs/vm-test-plan.md` from Phase 3.

## Every session

```bash
infra/vm.sh start
```

Probe first: a stopped VM can come back on different hardware.

```bash
PROBE_REFERENCE=results/probe-reference K6_STARTUP_LIMIT_S=<set in Phase 3> PROBE_CPU=1 internal-validation/host-probe.sh results/probe-$(date +%F)
```

Long jobs go through `then-poweroff.sh` inside `tmux`, so they survive a
dropped connection and the VM stops by itself:

```bash
infra/then-poweroff.sh logs/main-study.log env K=<locked> N=100 CONDITIONS="jemalloc samm" CPUSET_CPUS=1 K6_TASKSET=2,3 RESULTS_DIR=benchmark-results/main-study server/scripts/run_replicates.sh
```

Back on the laptop, copy results off before deleting anything:

```bash
infra/vm.sh fetch benchmark-results
```

```bash
infra/vm.sh stop
```

## Cost

- `t2d-standard-4` on demand: about $0.17 an hour (us-central1; check the
  console). The main study is about 40 hours.
- A stopped VM costs only its disk (100 GB balanced; check the console for the
  monthly rate).
- Set a budget alert in the Billing console (Budgets & alerts), for example at
  $50, as a backstop for a VM left running.
- `infra/vm.sh delete` ends all cost, and deletes the disk with every result
  on it. Fetch first.
