#!/usr/bin/env bash
# "What is in prod?" One table: Route -> Service -> image tag -> the commit the running pod reports.
# Read-only. Usage: scripts/status.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need oc git
cd "$ROOT"
NAMESPACE="$(namespace)"
echo "Project: $NAMESPACE"
echo

FMT='%-12s %-10s %-26s %-6s %-9s %-10s %s\n'
printf "$FMT" SERVICE ROLE TARGET READY IMAGE-TAG POD-COMMIT NOTE

# Prints one table row for a release Service/Deployment.
row() { # service role target note
  local svc="$1" role="$2" target="$3" note="$4" ready img tag podc
  ready="$(oc get deploy "$target" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo '-')"
  [[ "$ready" == /* ]] && ready="0$ready"
  img="$(oc get deploy "$target" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  tag="${img##*:}"; [[ -n "$img" ]] || tag="-"
  podc="$(oc exec "deploy/$target" -- printenv GIT_COMMIT 2>/dev/null || true)"; [[ -n "$podc" ]] || podc="?"
  # The pod's own report is the source of truth. The object name must agree with it.
  if [[ "$podc" != "?" && "$tag" != "-" && "$podc" != "$tag" ]]; then note="MISMATCH: pod reports $podc. $note"; fi
  printf "$FMT" "$svc" "$role" "$target" "$ready" "$tag" "$podc" "$note"
}

commit_time() { git show -s --format=%ct "$1" 2>/dev/null || echo 0; }

for svc in payment-api risk-domain; do
  live="$(route_target "$svc")"; prev="$(route_target "$svc-preview")"
  if [[ -z "$live" && -z "$prev" ]]; then
    printf "$FMT" "$svc" "-" "(no Routes yet)" "" "" "" ""
  elif [[ "$live" == "$prev" ]]; then
    row "$svc" "live+prev" "$live" "same release on both Routes"
  else
    row "$svc" "live" "$live" ""
    pnote=""
    lt="$(commit_time "${live#"$svc"-}")"; pt="$(commit_time "${prev#"$svc"-}")"
    if [[ "$pt" -gt "$lt" ]]; then pnote="next release (pilot)"; elif [[ "$pt" -lt "$lt" ]]; then pnote="previous release (rollback target)"; fi
    row "$svc" "preview" "$prev" "$pnote"
  fi
  # Releases that exist but no Route points at
  for d in $(oc get deploy -l "app=$svc" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    if [[ "$d" != "$live" && "$d" != "$prev" ]]; then row "$svc" "unbound" "$d" "no Route points here"; fi
  done
done

if oc get deploy gateway >/dev/null 2>&1; then row gateway single gateway ""; else printf "$FMT" gateway - "(not deployed)" "" "" "" ""; fi

echo
echo "Addresses:"
for r in gateway payment-api payment-api-preview risk-domain risk-domain-preview; do
  h="$(route_host "$r")"; [[ -n "$h" ]] && printf '  %-22s http://%s\n' "$r" "$h"
done
exit 0
