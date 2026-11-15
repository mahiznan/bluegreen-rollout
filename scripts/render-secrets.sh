#!/usr/bin/env bash
# Simulates the pipeline pulling a release's secrets from a vault at build time.
# Usage: render-secrets.sh <service> <commit>   prints KEY=value lines (nothing if the service has no secret)
#
# The value is derived from service + commit, so every release has a DIFFERENT secret and a
# different fingerprint. Nothing is stored anywhere: it is recomputed on each release.
set -euo pipefail
svc="${1:?service}"; commit="${2:?commit}"

value() { printf 'demo-vault:%s:%s' "$1" "$2" | shasum -a 256 | cut -c1-24; }

case "$svc" in
  payment-api) echo "PAYMENT_API_KEY=$(value payment-api "$commit")" ;;
  risk-domain) echo "RISK_API_KEY=$(value risk-domain "$commit")" ;;
  *) ;;  # the gateway has no secret
esac
