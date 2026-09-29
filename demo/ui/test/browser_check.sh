#!/usr/bin/env bash
#
# Paints the charts in a real browser and asserts pixels actually landed.
#
# jsdom cannot do this: with no canvas, uPlot's draw path never calls
# series.stroke(), which is where the "charts render blank" bug lived. This
# serves test/visual.html, loads it headless, and reads the verdict it writes
# into the DOM.
#
# Usage: ./test/browser_check.sh            (CHROME=/path/to/chrome to override)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CHROME="${CHROME:-}"
if [[ -z "$CHROME" ]]; then
  for c in "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe" \
           "/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" \
           "$(command -v google-chrome || true)" "$(command -v chromium || true)"; do
    [[ -n "$c" && -x "$c" ]] && { CHROME="$c"; break; }
  done
fi
[[ -n "$CHROME" ]] || { echo "SKIP: no Chrome or Edge found (set CHROME=...)"; exit 0; }

PORT="${PORT:-9211}"
# serve_fixture.js serves the real pages with canned data and a stream that
# ENDS, which is what lets a headless browser finish loading and be inspected.
node "$HERE/test/serve_fixture.js" "$PORT" 60 >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
sleep 1

dump() {
  timeout 120 "$CHROME" --headless=new --disable-gpu --virtual-time-budget=6000 \
    --window-size=1512,900 --dump-dom "http://localhost:$PORT/$1" 2>/dev/null || true
}

fail=0

# 1. the harness: does a line leave pixels on the canvas at all?
VERDICT="$(dump 'test/visual.html' | grep -o 'id="verdict"[^>]*>[^<]*' | sed 's/.*>//')"
echo "browser_check  visual.html : ${VERDICT:-no verdict found}"
[[ "$VERDICT" == OK* ]] || fail=1

# 2. the real pages: do they build their charts and show live numbers?
for page in "" "v2.html"; do
  name="${page:-index.html}"
  dom="$(dump "$page")"
  canvases="$(printf '%s' "$dom" | grep -o '<canvas' | wc -l)"
  # A rendered page has replaced its em-dash placeholders with numbers.
  numbers="$(printf '%s' "$dom" | grep -oE 'id="(kpi-faults|hero-rps|health-score-value)"[^>]*>[0-9,]+' | wc -l)"
  echo "browser_check  ${name} : ${canvases} canvases, ${numbers} live values"
  if (( canvases < 3 || numbers < 1 )); then echo "browser_check: ${name} FAILED"; fail=1; fi
done

(( fail == 0 )) || { echo "browser_check: FAILED"; exit 1; }
echo "browser_check: all pages OK"
