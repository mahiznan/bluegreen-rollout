#!/usr/bin/env bash
# Swaps live and preview for several services, in the order given, optionally waiting between them.
# Each swap is `bind.sh swap`. All services are checked BEFORE the first swap, so a problem stops
# you before anything moves and never leaves a half-done flip.
#
# Usage: scripts/flip.sh [-y] [--dry-run] [--gap SECONDS] <service> [<service> ...]
#   scripts/flip.sh -y --gap 5 risk-domain payment-api    # promote: callee first
#   scripts/flip.sh -y --gap 5 payment-api risk-domain    # roll back: caller first
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need oc
cd "$ROOT"
NAMESPACE="$(namespace)"

GAP=0; DRY=0; SERVICES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y)        YES=1 ;;
    --dry-run) DRY=1 ;;
    --gap)     shift; GAP="${1:?--gap needs a number of seconds}" ;;
    -*)        die "unknown option $1" ;;
    *)         SERVICES+=("$1") ;;
  esac
  shift
done
[[ ${#SERVICES[@]} -ge 1 ]] || die "usage: scripts/flip.sh [-y] [--dry-run] [--gap SECONDS] <service> [<service> ...]"

# Check everything first
for s in "${SERVICES[@]}"; do
  live="$(route_target "$s")"; prev="$(route_target "$s-preview")"
  [[ -n "$live" && -n "$prev" ]] || die "$s: Routes are missing"
  [[ "$live" != "$prev" ]] || die "$s: live and preview already point at the same release ($live)"
  require_ready "$live"; require_ready "$prev"
  printf '  %-12s live %-26s -> %s\n' "$s" "$live" "$prev"
done
echo "order: ${SERVICES[*]}   gap between swaps: ${GAP}s"
[[ "$DRY" == 0 ]] || { info "dry run: nothing was changed"; exit 0; }
confirm

START="$(date +%s)"
n=0
for s in "${SERVICES[@]}"; do
  n=$((n + 1))
  "$ROOT/scripts/bind.sh" swap "$s" -y
  if [[ "$n" -lt "${#SERVICES[@]}" && "$GAP" -gt 0 ]]; then info "waiting ${GAP}s before the next swap"; sleep "$GAP"; fi
done
END="$(date +%s)"
echo
info "flip started at epoch $START ($(date -r "$START" +%H:%M:%S)) and finished at epoch $END ($(date -r "$END" +%H:%M:%S))"
echo "   timeline relative to the start of the flip:  scripts/timeline.sh <results.csv> $START"
