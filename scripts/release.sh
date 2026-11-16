#!/usr/bin/env bash
# Builds and deploys ONE release of a service, named after the git commit. It does not bind any
# Route, so nobody receives traffic until scripts/bind.sh says so.
#
# Usage: scripts/release.sh [--render-only] [--rebuild] [-y] <service>
#   --render-only  write the rendered YAML to .rendered/ and validate it; changes nothing in the cluster
#   --rebuild      build the image again even if <service>:<commit> already exists
#
# Steps: clean-tree check -> build image (tag = commit) -> ConfigMap + Secret -> Service + Deployment -> wait
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RENDER_ONLY=0; REBUILD=0; NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --render-only) RENDER_ONLY=1 ;;
    --rebuild)     REBUILD=1 ;;
    -y)            YES=1 ;;
    -*)            die "unknown option $1" ;;
    *)             NAME="$1" ;;
  esac
  shift
done
[[ -n "$NAME" ]] || die "usage: scripts/release.sh [--render-only] [--rebuild] [-y] <service>"

cd "$ROOT"
SERVICE_DIR="services/$NAME"
[[ -d "$SERVICE_DIR/k8s" ]] || die "$SERVICE_DIR/k8s does not exist"
need oc git envsubst rsync shasum
oc whoami >/dev/null 2>&1 || die "not logged in to the cluster (oc login)"
NAMESPACE="$(namespace)"

# ---- 1. The release id: the last commit that touched this service's directory ----
COMMIT="$(git log -1 --format=%h -- "$SERVICE_DIR")"
[[ -n "$COMMIT" ]] || die "no commit touches $SERVICE_DIR yet. Commit it first."
DIRTY="$(git status --porcelain -- "$SERVICE_DIR")"
if [[ -n "$DIRTY" ]]; then
  if [[ "$RENDER_ONLY" == 1 ]]; then
    COMMIT="${COMMIT}-dirty"
    echo "WARNING: uncommitted changes in $SERVICE_DIR. Rendering as '$COMMIT' for inspection only."
  else
    echo "$DIRTY" >&2
    die "uncommitted changes in $SERVICE_DIR. Commit them first, so the commit hash really identifies this release."
  fi
fi
IMAGE="$REGISTRY/$NAMESPACE/$NAME:$COMMIT"
info "service=$NAME commit=$COMMIT namespace=$NAMESPACE"
info "image=$IMAGE"

# ---- 2. Render the templates ----
OUT="$ROOT/.rendered/$NAME-$COMMIT"
mkdir -p "$OUT"
for f in configmap service deployment; do
  # A service without a template for this kind (the mfe has no ConfigMap) is skipped.
  [[ -f "$SERVICE_DIR/k8s/$f.tmpl.yaml" ]] || continue
  render "$SERVICE_DIR/k8s/$f.tmpl.yaml" >"$OUT/$f.yaml"
done
DEPLOY="$(grep -m1 '^  name:' "$OUT/deployment.yaml" | awk '{print $2}')"
SECRET_LINES="$("$ROOT/scripts/render-secrets.sh" "$NAME" "$COMMIT")"
info "rendered to .rendered/$NAME-$COMMIT/ (deployment: $DEPLOY)"

if [[ "$RENDER_ONLY" == 1 ]]; then
  oc apply --dry-run=client -f "$OUT" >/dev/null && info "YAML is valid (client-side check)"
  if [[ -n "$SECRET_LINES" ]]; then
    info "a Secret $NAME-$COMMIT-secrets would be created with keys: $(sed 's/=.*//' <<<"$SECRET_LINES" | tr '\n' ' ')"
  else
    info "no Secret for $NAME"
  fi
  info "render-only: the cluster was not changed"
  exit 0
fi

# ---- 3. Build the image in the cluster, tagged with the commit ----
if [[ "$REBUILD" == 0 ]] && oc get istag "$NAME:$COMMIT" >/dev/null 2>&1; then
  info "image $NAME:$COMMIT already exists, skipping the build (use --rebuild to force)"
else
  oc get bc/"$NAME" >/dev/null 2>&1 || { info "creating BuildConfig and ImageStream '$NAME'"; oc new-build --binary --strategy=docker --name="$NAME"; }
  STAGE="$(mktemp -d)"
  trap 'rm -rf "${STAGE:?}"' EXIT
  rsync -a --exclude target/ --exclude k8s/ --exclude node_modules/ --exclude dist/ "$SERVICE_DIR"/ "$STAGE"/
  # The commit is passed as a build arg set ON THE BuildConfig. Do NOT use `oc start-build --build-arg`:
  # for binary builds (--from-dir) it is silently ignored, and the image would report "unknown".
  info "building (the commit is baked in as GIT_COMMIT=$COMMIT)"
  BUILD_ARGS="{\"name\":\"GIT_COMMIT\",\"value\":\"$COMMIT\"}"
  if [[ "$NAME" == "mfe" ]]; then
    # The page is built with the commit and the gateway URL baked in (VITE_* are read by `vite build`).
    GW_HOST="$(route_host gateway)"
    [[ -n "$GW_HOST" ]] || die "the gateway Route does not exist yet (scripts/bind.sh gateway). The mfe is built with its URL."
    BUILD_ARGS="$BUILD_ARGS,{\"name\":\"VITE_GATEWAY_URL\",\"value\":\"http://$GW_HOST\"}"
    info "the mfe is built with VITE_GATEWAY_URL=http://$GW_HOST"
  fi
  oc patch "bc/$NAME" --type=merge \
    -p "{\"spec\":{\"strategy\":{\"dockerStrategy\":{\"buildArgs\":[$BUILD_ARGS]}}}}" >/dev/null
  oc start-build "$NAME" --from-dir="$STAGE" --follow --wait
  oc tag "$NAME:latest" "$NAME:$COMMIT"
fi

# ---- 4. Apply: config first, then the Secret, then the workload ----
if [[ -f "$OUT/configmap.yaml" ]]; then oc apply -f "$OUT/configmap.yaml"; fi
if [[ -n "$SECRET_LINES" ]]; then
  ENVFILE="$(mktemp)"
  trap 'rm -f "${ENVFILE:?}"; rm -rf "${STAGE:-/nonexistent-stage}"' EXIT
  printf '%s\n' "$SECRET_LINES" >"$ENVFILE"
  oc create secret generic "$NAME-$COMMIT-secrets" --from-env-file="$ENVFILE" --dry-run=client -o yaml \
    | oc label --local -f - app="$NAME" commit="$COMMIT" -o yaml \
    | oc apply -f -
fi
oc apply -f "$OUT/service.yaml" -f "$OUT/deployment.yaml"

# ---- 5. Wait until it is really ready ----
oc rollout status "deployment/$DEPLOY" --timeout=300s

# ---- 6. Verify the pod really runs THIS commit (the image's baked value, not the object name) ----
POD_COMMIT="$(oc exec "deploy/$DEPLOY" -- printenv GIT_COMMIT 2>/dev/null || true)"
if [[ "$POD_COMMIT" != "$COMMIT" ]]; then
  die "the running pod reports GIT_COMMIT='$POD_COMMIT', expected '$COMMIT'. The image was not built with this commit. Do not bind this release."
fi
info "verified: the running pod reports commit $POD_COMMIT"
echo
oc get pods -l "app=$NAME,commit=$COMMIT"
echo
info "release $NAME-$COMMIT is running but NOT bound to any Route."
if [[ "$NAME" == "gateway" ]]; then
  echo "   next: scripts/bind.sh gateway"
else
  echo "   first release of $NAME : scripts/bind.sh init $NAME $COMMIT"
  echo "   a later release        : scripts/bind.sh preview $NAME $COMMIT   (pilot opens)"
fi
