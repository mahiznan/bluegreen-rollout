# Shared helpers. Sourced by the other scripts, never run directly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS_DOMAIN="${APPS_DOMAIN:-apps-crc.testing}"
REGISTRY="image-registry.openshift-image-registry.svc:5000"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">> $*"; }

need() {
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "'$c' is not installed"; done
}

# Asks before doing something that replaces what a Route points to. -y or YES=1 skips it.
confirm() {
  if [[ "${YES:-}" == "1" ]]; then return 0; fi
  read -r -p "Continue? [y/N] " answer </dev/tty
  [[ "$answer" == y* || "$answer" == Y* ]] || die "aborted"
}

# The project every script works in. A guard, because project 1 (payments-rollout) lives in
# my-project with Routes and Deployments of the SAME names, and a mix-up would rewrite them.
# Create it once with:  oc new-project bluegreen
EXPECTED_NAMESPACE="${BLUEGREEN_NAMESPACE:-bluegreen}"
namespace() {
  local ns; ns="$(oc project -q)"
  [[ "$ns" == "$EXPECTED_NAMESPACE" ]] || die "current project is '$ns' but this demo runs in '$EXPECTED_NAMESPACE'. Run: oc project $EXPECTED_NAMESPACE   (create it once with: oc new-project $EXPECTED_NAMESPACE)"
  echo "$ns"
}

# What a Route currently points to (empty if the Route does not exist).
route_target() { oc get route "$1" -o jsonpath='{.spec.to.name}' 2>/dev/null || true; }
route_host()   { oc get route "$1" -o jsonpath='{.spec.host}' 2>/dev/null || true; }

# Number of READY pod addresses behind a Service. A Route pointing at 0 makes the router answer 503.
ready_count() {
  local ips
  ips=$(oc get endpoints "$1" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
  if [[ -z "$ips" ]]; then echo 0; else wc -w <<<"$ips" | tr -d ' '; fi
}

require_ready() {
  oc get service "$1" >/dev/null 2>&1 || die "Service '$1' does not exist"
  local n; n=$(ready_count "$1")
  [[ "$n" -ge 1 ]] || die "Service '$1' has no ready pods. Binding a Route to it would make the router return 503."
}

# Fills ${NAME} ${COMMIT} ${IMAGE} ${NAMESPACE} ${APPS_DOMAIN} in a template.
# Only these variables are replaced, so nothing else with a dollar sign is touched.
render() {
  NAME="$NAME" COMMIT="${COMMIT:-}" IMAGE="${IMAGE:-}" NAMESPACE="$NAMESPACE" APPS_DOMAIN="$APPS_DOMAIN" \
    envsubst '${NAME} ${COMMIT} ${IMAGE} ${NAMESPACE} ${APPS_DOMAIN}' <"$1"
}
