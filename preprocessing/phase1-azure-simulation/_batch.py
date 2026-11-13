"""
Day ranges and per-batch folders for Phase 1 (the Azure trace preprocessing).

With no settings, every script reads all published days and writes where it
always has, so the main study's traffic and payload models are untouched.

  AZURE_DAYS=1-7             use only these days of the trace (inclusive)
  AZURE_BATCH=d01-d07        name of the batch; its files go under
                             intermediate/<batch>/ and processed/<batch>/
                             (default: derived from AZURE_DAYS)
  AZURE_SCALE_FROM=d01-d07   measure this batch on THAT batch's scale: its
                             traffic-state thresholds and its memory anchor,
                             instead of this batch's own

Why AZURE_SCALE_FROM exists: a minute is Idle below the 25th percentile of the
batch's own traffic and busy above the 75th, and payload sizes are divided by
the batch's own 99th-percentile app. So every batch is a quarter "idle", a
quarter "busy" and tops out at the same payload by construction, however busy
or heavy the week really was. Measuring a second week on the first week's scale
is what lets a surge, a quiet week or heavier apps show up at all.
"""

import os
import re

_ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                      "datasets", "azure-trace-2019"))


def _parse_days():
    raw = os.environ.get("AZURE_DAYS", "").strip()
    if not raw:
        return None
    m = re.fullmatch(r"(\d+)-(\d+)", raw)
    if not m or int(m.group(1)) > int(m.group(2)):
        raise SystemExit(f"AZURE_DAYS must look like 1-7 (got {raw!r})")
    return int(m.group(1)), int(m.group(2))


DAYS = _parse_days()
BATCH = os.environ.get("AZURE_BATCH", "").strip() or (f"d{DAYS[0]:02d}-d{DAYS[1]:02d}" if DAYS else "")
SCALE_FROM = os.environ.get("AZURE_SCALE_FROM", "").strip()

RAW_DIR = os.path.join(_ROOT, "raw")


def intermediate(step):
    """intermediate/<step>, or intermediate/<batch>/<step> for a batch."""
    return os.path.join(_ROOT, "intermediate", BATCH, step) if BATCH else os.path.join(_ROOT, "intermediate", step)


def processed(kind, batch=None):
    """processed/<kind>, or processed/<batch>/<kind> for a batch."""
    batch = BATCH if batch is None else batch
    return os.path.join(_ROOT, "processed", batch, kind) if batch else os.path.join(_ROOT, "processed", kind)


def day_of(path):
    m = re.search(r"\.d(\d+)\.csv$", os.path.basename(path))
    return int(m.group(1)) if m else None


def select_days(files):
    """The files whose day falls in AZURE_DAYS (all of them when it is unset)."""
    if DAYS is None:
        return list(files)
    kept = [f for f in files if day_of(f) is not None and DAYS[0] <= day_of(f) <= DAYS[1]]
    return kept


def describe():
    days = f"days {DAYS[0]}-{DAYS[1]}" if DAYS else "all days"
    where = f"batch '{BATCH}'" if BATCH else "the default folders"
    extra = f", on the scale of '{SCALE_FROM}'" if SCALE_FROM else ""
    return f"{days} -> {where}{extra}"
