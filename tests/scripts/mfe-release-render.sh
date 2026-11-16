#!/usr/bin/env bash
# Offline check (no cluster change): `release.sh --render-only mfe` must render only a Service and a
# Deployment (no ConfigMap), and the other services must still render their ConfigMap.
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

out="$(scripts/release.sh --render-only mfe 2>&1)" || { echo "$out"; fail "render-only mfe exited non-zero"; }
d="$(ls -d .rendered/mfe-* | tail -1)"
[[ -f "$d/service.yaml" && -f "$d/deployment.yaml" ]] || fail "mfe: service.yaml or deployment.yaml missing in $d"
[[ ! -s "$d/configmap.yaml" ]] || fail "mfe: a configmap was rendered but mfe has none"
grep -q "kind: Deployment" "$d/deployment.yaml" || fail "mfe deployment is not a Deployment"
grep -q "no Secret for mfe" <<<"$out" || fail "expected 'no Secret for mfe' in the output"

out="$(scripts/release.sh --render-only risk-domain 2>&1)" || { echo "$out"; fail "render-only risk-domain exited non-zero"; }
r="$(ls -d .rendered/risk-domain-* | tail -1)"
grep -q "kind: ConfigMap" "$r/configmap.yaml" || fail "risk-domain lost its ConfigMap"
echo "PASS"
