#!/usr/bin/env bash
# Turns a k6 CSV (--out csv=...) into "who served what, when". For each user group it prints
# SEGMENTS: consecutive seconds in which the same set of (eapi/domain) pairs appeared.
# A change of set is a release change; a segment with two pairs is a mix.
#
# Usage: scripts/timeline.sh <k6.csv> [epoch]
#   epoch  make t=0 that moment (use the epoch printed by flip.sh), otherwise t=0 is the first sample
[[ -f "${1:-}" ]] || { echo "usage: scripts/timeline.sh <k6.csv> [epoch]" >&2; exit 1; }
CSV="$1"; EPOCH="${2:-}"
awk -F, -v epoch="$EPOCH" '
$1 == "pairs" {
  ts = $2 + 0; group = $8
  n = split($18, kv, "&"); e = ""; d = ""
  for (i = 1; i <= n; i++) { split(kv[i], kvp, "="); if (kvp[1] == "eapi") e = kvp[2]; if (kvp[1] == "domain") d = kvp[2] }
  pair = e "/" d
  cnt[ts, group, pair]++
  if (!(group in gseen)) { gseen[group] = 1; groups[++ng] = group }
  if (!((group, pair) in pseen)) { pseen[group, pair] = 1; pairs[group, ++np[group]] = pair }
  if (min == "" || ts < min) min = ts
  if (ts > max) max = ts
}
function flush(g,   i, p, line) {
  if (segStart == "") return
  line = sprintf("  t=%4d..%-4d (%3ds)  ", segStart - base, segEnd - base, segEnd - segStart + 1)
  for (i = 1; i <= np[g]; i++) { p = pairs[g, i]; if (segCnt[p] > 0) line = line sprintf("%s=%d  ", p, segCnt[p]) }
  if (segMixed) line = line " <- MIX"
  print line
}
END {
  if (min == "") { print "no pairs rows in the CSV"; exit }
  base = (epoch != "") ? epoch + 0 : min
  printf "t=0 is %s\n", (epoch != "") ? "the given epoch " epoch : "the first sample"
  for (gi = 1; gi <= ng; gi++) {
    g = groups[gi]
    printf "\n%s users\n", g
    segStart = ""; prevSet = ""
    for (t = min; t <= max; t++) {
      set = ""; present = 0
      for (i = 1; i <= np[g]; i++) { p = pairs[g, i]; if (cnt[t, g, p] > 0) { set = set "|" p; present++ } }
      if (set == "") continue
      if (set != prevSet) {
        flush(g)
        for (k in segCnt) delete segCnt[k]
        segStart = t; segMixed = (present > 1)
        prevSet = set
      }
      segEnd = t
      for (i = 1; i <= np[g]; i++) { p = pairs[g, i]; segCnt[p] += cnt[t, g, p] }
    }
    flush(g)
  }
}' "$CSV"
