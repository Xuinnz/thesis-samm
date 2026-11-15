# Finishing the thesis: what each result means and what to do about it

Written 2026-11-15, after the main study was launched and before any of its
results existed. It is for whoever runs the remaining phases (9 to 11 of
`docs/vm-test-plan.md`). The scripts do the mechanics; this covers the
judgement: for each thing that can come back, what it means, what to do, and
what not to do.

**The principle behind every answer here:** the design was fixed before the
data (load point, seeds, table, tests, exclusion rules, probe limits). A result
is reported under that design, whatever it shows. Nothing in the design is
changed because of a result. When a case is not in this document, stop and ask
the user; do not improvise a rule.

## 1. What is left, in order

| # | Step | Command, from the laptop | Machine time |
| :- | :--- | :--- | :--- |
| 1 | Main study, n = 100 (started 2026-11-15 12:17 UTC) | `infra/vm.sh study main` | about 48 h |
| 2 | GC pass | `infra/vm.sh study gc` | 1.5 h |
| 3 | 2 GB extra | `infra/vm.sh study extra-mem 2048m` | 8 h |
| 4 | 4 GB extra | `infra/vm.sh study extra-mem 4096m` | 8 h |
| 5 | Two-weeks extra | `infra/vm.sh study extra-weeks` | 15 h |
| 6 | Write Chapter 4 from the generated tables and figures | | |

Around each step:

```bash
infra/vm.sh start                      # only when the VM is off
infra/vm.sh update                     # pull; refuses while anything runs there
infra/vm.sh study <command>            # detached; the VM powers off when it ends
infra/vm.sh wait                       # asks Google only; repeat until "VM is off"
infra/vm.sh start
infra/vm.sh fetch benchmark-results/<folder>     # copy into ./vm-results/
infra/vm.sh stop                       # unless the next step starts now
```

`GCP_PROJECT` and `GCP_ZONE` must be set for `infra/vm.sh` (they are not in
the repository). One step at a time. The statistics, tables and figures are
written at the end of every run, under `<folder>/stats/`.

Before steps 3 to 5 the VM needs a git name and email (`git config --global
user.name` / `user.email`, the user's): each extra commits its retrained table
on its own branch. The script refuses without them. Ask the user; do not
invent an identity.

## 2. Rules that hold until the last extra is finished

1. **While a run is in progress, nothing touches the VM** except `infra/vm.sh
   wait` and `infra/vm.sh status`. No ssh "just to look", no pull.
2. **No commit may change the measured system** until every extra is done:
   `server/routes`, `server/baseline-v8`, `server/samm-enabled`, `profiler`,
   `zig-allocator`, `docker`, `load-generator`, `server/scripts/_bench-lib.sh`,
   `server/scripts/run_replicates.sh`, the processed Azure models, and
   `infra/study.env`. A resume would be refused (the campaign lock), and it
   would be right to refuse. Documentation and analysis scripts are free.
3. **Never** `CAMPAIGN_ALLOW_CHANGE=1` or `--allow-integrity-errors` for a
   number that goes into the thesis. They exist for diagnosis.
4. **Never edit, delete or re-run an individual result.** A killed run is a
   result. An interrupted run leaves no result file and is run again by the
   resume; that is the only "re-run" there is.
5. **Never change after seeing a result:** k, β or the table, seeds, buffer
   mode, the probe's limits, the 5 % failed-request rule, the timing-suspect
   rule, the 10 % survival rule, α, or which test is used.
6. A `REFUSED` or an `ERROR` is information. Read it, find the cause, and if
   the cause is not one of the cases below, ask the user.
7. Commits carry only the user's identity, the user pushes, and the manuscript
   drafts and the `ismm` branch are not pushed to the public repository.

## 3. The main study while it runs

Expected to end near 2026-11-17 12:30 UTC (200 runs of 14.2 minutes, eleven
probes). A 60-hour shutdown timer is the backstop.

**If the VM is off before about 2026-11-17 10:00 UTC, it stopped early.** Start
it, and read the end of the log:
`infra/vm.sh ssh --command 'cd ~/samm-final && tail -n 40 "$(ls -t results/study-main-*.log | head -1)"'`

| The log ends with | It means | Do |
| :--- | :--- | :--- |
| `finished ... with exit 0`, statistics printed | It is complete | Section 4 |
| `the host probe failed 7 times in a row`, exit 3 | The host stayed slow for over an hour | Stop the VM, wait a few hours, `infra/vm.sh study main` again. It resumes. If it happens three times, tell the user: the machine may need to be recreated, which is theirs to decide |
| `three runs in a row produced no result file`, exit 4 | The harness broke (a build, k6, the port, the disk) | Find the cause in the log above that line. Fix the cause only if it is outside the measured system (disk full, a stray container); otherwise ask the user. Then resume |
| `REFUSED` in preflight | The checkout is dirty, on another branch, or something else is running | Put it back as it was (`git status`, `git switch main`, `docker ps`). Resume |
| `ERROR: this folder's campaign was started with different settings` | Something in the measured system or `infra/study.env` changed since the launch | Find what (`git log`, `git status` on the VM) and put it back. Do not override |
| No `finished` line at all | The VM was stopped from outside (maintenance, a crash, the shutdown timer) | Note the time in the runbook. Resume. The run that was cut off left no file and is run again |
| `The statistics did not run`, with integrity errors | The runs are done but the folder is not one sample | Section 4.1 |

Resuming never loses or repeats a finished run.

## 4. Reading the main study's report

`benchmark-results/main-study/stats/report.txt`. Read its sections in order;
each one below can change how the next is read.

### 4.1 Section 0, integrity

| It says | Do |
| :--- | :--- |
| `Integrity: ok` | Go on |
| `N replicates in the folder, 100 planned` | The campaign is not finished. Resume it |
| Any other error (a seed, the table, the order, the buffer mode, telemetry) | Stop. Nothing was tested, by design. Copy the errors to the user. Do not test around them |
| Warning: `different values of image_layers_sha256` | The image was rebuilt from scratch part-way (a cleared build cache). Its source is locked, so say so in the limitations and go on |
| Warning: `host probe attempt(s) failed` | Go on, and read section 6 of the report (4.5 below) |
| Warning: `different values of git_commit` | Harmless if rule 2 was kept. Check it was |

### 4.2 Section 1, run completion. This decides how everything else is framed

A run counts as killed if Docker says the container ended, the kernel
recorded an OOM kill, the CPU counters were gone at teardown, or more than
5 % of its requests failed. The pilot already showed the baseline dying on a
heavy seed (seed 20261115: 965 MB and alive on 13 November, OOM-killed on 15
November), so expect some.

| Outcome | What the thesis says | What not to do |
| :--- | :--- | :--- |
| No run killed in either condition | The three tests are the result | |
| Some killed, at most 10 % in each condition | The three tests are the result; the completion table is reported with them | |
| **More than 10 % of one condition killed** (the report prints this in capitals) | **Survival is the principal result**, as fixed on 2026-11-13: lead with the completion table and the full-window throughput, which counts every run. The three tests follow and describe only the runs that completed | Do not present the tests as the headline. Do not drop the heavy seeds from the other condition to "match" |
| The baseline loses many runs, SAMM few | As above. Add the warning that the baseline's completing runs are its lighter seeds, so its mean memory and latency look better than they are; the paired supplement (section 5 of the report: only replicates where both completed) is the like-for-like comparison, labelled supplementary | Do not call the paired result the approved test. It is not |
| SAMM loses more runs than the baseline | Report it exactly so. It counts against SAMM. The β passes showed SAMM within 53 MiB of the limit on a heavy seed, so it is possible | Do not retrain, change β, or call the kills an artefact |
| Both lose most of their runs | The stress point is beyond both inside 1 GiB. Report it. Whether to run a second study at k = 1.5 is the user's decision, and it would be reported as a second study, not as a replacement | Do not lower k and re-run on your own |
| Several runs "timing-suspect" (more than about 5) | The host stalled repeatedly. They are excluded already. Tell the user, with the replicate numbers | |

Fisher's exact test on survival is printed as supplementary. Report it as
that.

### 4.3 Sections 2 and 3, the three tests

The test for each metric (t-test or Mann-Whitney U) is chosen by the
assumption checks, automatically. Report what was chosen and why; both
outcomes are legitimate. The decision compares p with 0.0167 (Bonferroni over
three metrics), not with 0.05.

| Result | Say | Do not say |
| :--- | :--- | :--- |
| H₀ rejected, and the relative change favours SAMM (lower memory or P99, higher throughput) | SAMM was significantly better on this metric, with the relative change and the effect size | |
| H₀ rejected, and the change is against SAMM | SAMM was significantly worse on this metric. **Expect this for peak memory**: SAMM reserves its pool and sat at 84-95 % of the limit in the β passes, above the baseline. It is the cost of the design and goes in the results as such | Do not soften it, move it to a footnote, or explain it away. The thesis's claim is the trade: more memory held, for less CPU, fewer page faults and lower latency |
| H₀ not rejected | No significant difference was found on this metric at n = 100 | "A trend", "marginally significant", "would be significant without the correction" |
| p between 0.0167 and 0.05 | Not rejected at the adjusted α. State p | Do not switch to α = 0.05 for that metric |
| Throughput: no difference, or a small one | Expected. At k = 2.0 the peak rate (1,000 req/s) is above the baseline's capacity (about 877 req/s in Phase 8) but below SAMM's (about 1,185), and most minutes are below both. The main study's throughput gap is the baseline's shortfall at peaks, not the capacity gap; Phase 8 measures the capacity gap | Do not quote Phase 8's +34.5 % as the main study's result |
| Mann-Whitney chosen for every metric | Normal for latency and for memory near a hard limit (skewed). Report the rank-biserial effect size the script gives | |

Supporting measures (section 4 of the report: P95, CPU, page faults, dropped
iterations) are descriptive. They are not tested and are not called
significant.

### 4.4 Section 5, the paired supplement

Outside the approved method, labelled so, and never the headline. Its use is
the case in 4.2 where one condition lost its heavy seeds. If it disagrees with
the approved tests, report both and say which is the approved one.

### 4.5 Section 6, host-health sensitivity

Only present if a probe failed during the campaign.

| It says | Do |
| :--- | :--- |
| `decision unchanged` for all three | One sentence in the methods: a slow stretch of the host was detected between replicates A and B; leaving those replicates out does not change any decision |
| `DECISION CHANGES` for a metric | The all-runs result stays the reported one. Report the sensitivity result beside it, say plainly that the decision depends on those replicates, and tell the user before writing the conclusion |

`figures/campaign_order.png` shows the same thing by eye: a slow stretch is a
step in both conditions at once.

## 5. The GC pass

Three replicates with V8's GC observer on. It answers one question: is the
difference between the conditions the garbage collector rather than the
allocator? `main-study-gc/gc_summary.md` gives GC pause time per run for each
condition and the CPU time of the clean runs of the same replicates.

| Outcome | Say |
| :--- | :--- |
| GC pause differs by a small share of the CPU difference (as at k = 1.0 in September) | GC scheduling does not account for the difference |
| GC pause difference is a large share of it (say, over half) | Say so. Part of SAMM's saving is then fewer or shorter collections, which is still an effect of where Buffers live, but the attribution changes. Tell the user before writing it up |
| A container died during the pass | Its counts cover only the time it lived; the summary notes it. Do not re-run it for a cleaner table without asking |

Never compare latency, throughput or CPU from this folder with anything. The
statistics refuse it if it is mixed into another folder.

## 6. The extras

Each is one command, on its own branch, and returns the VM to `main` when it
finishes. n = 15: the same tests, with much less power.

| Outcome | Meaning | Do |
| :--- | :--- | :--- |
| `REFUSED: git has no user.name` | Section 1 | Ask the user |
| `the beta pass ... did not survive` | SAMM died in a 2 GB or 4 GB container at this load. Unexpected | Stop. Report to the user with the pass's result file. Do not lower β by hand |
| `the confirming run gives beta = X, below the Y applied` | The pool sized by pass 1 is too large once it is in use | Stop. The method iterates once. Applying X is a second iteration and a stated deviation: the user decides |
| β printed above 1 and applied as 1.0 | The pool cannot exceed what the container allows. Expected at 2 GB and 4 GB (the rehearsal gave 1.03) | State it in the write-up |
| The command stopped part-way | The VM is still on the extra's branch | Run the same command again: it continues from the step it reached. Do not `git switch main` by hand while the table is uncommitted |
| No run killed, and SAMM's peak memory well above the baseline's | Expected: memory is no longer the constraint, and SAMM's ceiling grows with the container while its floors do not | Report memory as the cost; the comparison of interest is now CPU per request, page faults and latency |
| A test not significant at n = 15 | "Not detected at n = 15." With 15 runs only large effects are detectable | Do not write "no effect", and do not add runs after seeing the p-value |
| Week 1 and week 2 give the same picture | The expected and honest result: the two weeks differ by under 1 % in mean rate. It shows the table is not tuned to one week's traffic; it is a mild drift test, not surge against off-peak | Do not test "week 1 against week 2" formally unless the user asks; compare the two rows of `extras-summary.md` |
| Week 2 clearly worse for SAMM | The table trained on week 1 did not carry over. A real finding | Report it; tell the user |

`benchmark-results/extras-summary.md` puts the main study and every extra
side by side (`server/scripts/study.sh stats` rewrites it).

## 7. What goes into Chapter 4

| Source | Goes into |
| :--- | :--- |
| `main-study/stats/tables.md` | The three main-study tables, pasted as generated |
| `main-study/stats/figures/primary_distributions.png` | The distribution figure |
| `main-study/stats/figures/campaign_order.png` | Methods or appendix: the campaign in run order |
| `main-study/host-health.tsv`, `campaign.json` | Methods: how many probes, all passed or not; the locked settings |
| `main-study-gc/gc_summary.md` | The GC control |
| `extras-summary.md` | The panel's extra results |
| `docs/vm-test-plan.md`, Phases 6 to 8 | β, the microbenchmark, internal validation |

Numbers are copied from the generated files, never retyped from memory or
rounded differently. Phase 8 is reported from the k = 2.5 pass, with the
k = 2.0 pass as its supplement, and with both latency views: by absolute rate
SAMM is lowest; by share of its own capacity it does worst, because memory,
not CPU, is its limit.

Limitations that must appear, whatever the results: one machine type; Layer 1
fixed at two clusters; β derived from one run and confirmed on three seeds,
at one load point; the image
rebuilt per run (same source, same layers); the VM slowed once by up to 18 %
within a boot on 2026-11-15, which is why the probe now runs inside the
campaign.

## 8. Stop and ask the user when

- an integrity error is anything other than an unfinished campaign;
- a decision changes in the host-health sensitivity check;
- a β step refuses;
- the host probe keeps failing across three resumes;
- more than about five runs are timing-suspect;
- a fix would touch the measured system (rule 2);
- any result seems to call for changing the design;
- the case is not in this document.
