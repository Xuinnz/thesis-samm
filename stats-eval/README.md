# stats-eval

| Folder | What | Run |
|---|---|---|
| `hypothesis-testing/` | The main study's statistics, exactly as the approved methodology states them: Shapiro-Wilk and Levene, then an independent-samples t-test or Mann-Whitney U, Bonferroni alpha = 0.017, relative percentage difference; run completion and full-window throughput. The assumption checks are part of the same script. | `venv/bin/python stats-eval/hypothesis-testing/main_study_stats.py benchmark-results/main-study` |
| `matrix-validation/` | Layer 1's routing decisions against the reachability oracle. | `venv/bin/python stats-eval/matrix-validation/oracle_matrix.py datasets/oracle/<run> [...]` |
| `assumption-testing/` | Empty: the assumption checks live in `hypothesis-testing/main_study_stats.py`, because they decide which test runs. | |

`main_study_stats.py` was written and tested (`test_main_study_stats.py`, on
generated studies with known answers) on 2026-11-13, before any main-study run
existed. It writes `stats/tables.md` into the results folder: Chapter 4's
completion, performance and hypothesis-test tables, filled in.
