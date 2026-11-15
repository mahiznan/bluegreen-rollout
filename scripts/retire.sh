#!/usr/bin/env bash
# Removes one release's objects and its image tag. Refuses if a Route still points at it.
# Usage: scripts/retire.sh [-y] <service> <commit>
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need oc
cd "$ROOT"
NAMESPACE="$(namespace)"

ARGS=(); for a in "$@"; do [[ "$a" == "-y" ]] && YES=1 || ARGS+=("$a"); done
SVC="${ARGS[0]:?usage: scripts/retire.sh [-y] <service> <commit>}"; COMMIT="${ARGS[1]:?commit}"
TARGET="$SVC-$COMMIT"

if [[ "$SVC" == "gateway" ]]; then
  # The gateway is a single Deployment: only its old config and image tag can go.
  CURRENT="$(oc get deploy gateway -o jsonpath='{.metadata.labels.commit}' 2>/dev/null || true)"
  [[ "$CURRENT" != "$COMMIT" ]] || die "gateway commit $COMMIT is the one running now"
  echo "will delete: ConfigMap gateway-$COMMIT-config and image tag gateway:$COMMIT"
  confirm
  oc delete configmap -l "app=gateway,commit=$COMMIT" --ignore-not-found
else
  for r in "$SVC" "$SVC-preview"; do
    [[ "$(route_target "$r")" != "$TARGET" ]] || die "Route '$r' still points at $TARGET. Swap or re-bind first."
  done
  echo "will delete everything labelled app=$SVC,commit=$COMMIT (Deployment, Service, ConfigMap, Secret) and image tag $SVC:$COMMIT"
  oc get deploy,svc,configmap,secret -l "app=$SVC,commit=$COMMIT" -o name
  confirm
  oc delete deployment,service,configmap,secret -l "app=$SVC,commit=$COMMIT" --ignore-not-found
fi
oc tag -d "$SVC:$COMMIT" 2>/dev/null || true
info "retired $TARGET"
