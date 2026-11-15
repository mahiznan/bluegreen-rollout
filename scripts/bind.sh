#!/usr/bin/env bash
# Changes what the Routes point to. This is the ONLY script that touches Routes, and the only
# thing a "flip" ever is: no Deployment, Pod, ConfigMap or Secret is modified.
#
#   bind.sh init <service> <commit>      create both Routes, both -> that release (first deploy only)
#   bind.sh preview <service> <commit>   point the PREVIEW Route at that release (pilot opens)
#   bind.sh swap <service>               exchange live and preview (the flip, and also the rollback)
#   bind.sh gateway                      create the single gateway Route
#
# Add -y to skip the confirmation question.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need oc envsubst
cd "$ROOT"
NAMESPACE="$(namespace)"   # also verifies we are in the right project

ARGS=()
for a in "$@"; do [[ "$a" == "-y" ]] && YES=1 || ARGS+=("$a"); done
set -- "${ARGS[@]+"${ARGS[@]}"}"
CMD="${1:-}"

usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1; }

# Creates or updates a Route. Variables are exported because envsubst reads the environment.
apply_route() {
  export ROUTE_NAME="$1" NAME="$2" TARGET="$3"
  envsubst '${ROUTE_NAME} ${NAME} ${TARGET}' <"$ROOT/routes/route.tmpl.yaml" | oc apply -f - >/dev/null
}

patch_route() {
  [[ -n "$2" ]] || die "refusing to patch Route '$1' to an empty target"
  oc patch route "$1" --type=merge -p "{\"spec\":{\"to\":{\"name\":\"$2\"}}}" >/dev/null
}

show() {
  echo
  printf '  %-26s -> %s\n' "$1" "$(route_target "$1")"
  echo "    http://$(route_host "$1")"
}

case "$CMD" in
  init)
    SVC="${2:?service}"; COMMIT="${3:?commit}"; TARGET="$SVC-$COMMIT"
    require_ready "$TARGET"
    if [[ -n "$(route_target "$SVC")" || -n "$(route_target "$SVC-preview")" ]]; then
      echo "Routes for $SVC already exist (live -> $(route_target "$SVC"), preview -> $(route_target "$SVC-preview"))."
      echo "init will point BOTH at $TARGET."
      confirm
    fi
    apply_route "$SVC" "$SVC" "$TARGET"
    apply_route "$SVC-preview" "$SVC" "$TARGET"
    info "both Routes of $SVC now point at $TARGET"
    show "$SVC"; show "$SVC-preview"
    ;;

  preview)
    SVC="${2:?service}"; COMMIT="${3:?commit}"; TARGET="$SVC-$COMMIT"
    [[ -n "$(route_target "$SVC-preview")" ]] || die "no Routes for $SVC yet. Run: scripts/bind.sh init $SVC <commit>"
    require_ready "$TARGET"
    CURRENT="$(route_target "$SVC-preview")"
    if [[ "$CURRENT" == "$TARGET" ]]; then info "preview of $SVC already points at $TARGET"; exit 0; fi
    echo "live    -> $(route_target "$SVC")"
    echo "preview -> $CURRENT   (this release is no longer reachable by any Route afterwards)"
    echo "preview will point at $TARGET instead."
    echo "If $CURRENT is the rollback target left by the last flip, that rollback is gone."
    confirm
    patch_route "$SVC-preview" "$TARGET"
    info "preview of $SVC -> $TARGET"
    show "$SVC-preview"
    ;;

  swap)
    SVC="${2:?service}"
    LIVE="$(route_target "$SVC")"; PREV="$(route_target "$SVC-preview")"
    [[ -n "$LIVE" && -n "$PREV" ]] || die "Routes for $SVC are missing. Run: scripts/bind.sh init $SVC <commit>"
    [[ "$LIVE" != "$PREV" ]] || die "live and preview of $SVC already point at the same release ($LIVE). Nothing to swap."
    # Both sides must be healthy: after the swap each one receives the other's traffic.
    require_ready "$LIVE"; require_ready "$PREV"
    echo "swap $SVC:"
    echo "  live    $LIVE  ->  $PREV"
    echo "  preview $PREV  ->  $LIVE   (kept as the rollback target)"
    confirm
    # Live first: that is the change users feel. In between, both hostnames serve $PREV, which is harmless.
    T1="$(date +%s)"; patch_route "$SVC" "$PREV"; T2="$(date +%s)"
    patch_route "$SVC-preview" "$LIVE"; T3="$(date +%s)"
    info "swapped. live patched at $(date -r "$T1" +%H:%M:%S) (epoch $T1), preview at $(date -r "$T3" +%H:%M:%S) (epoch $T3)"
    echo "   The router reloads within a few seconds; new requests then use the new binding."
    show "$SVC"; show "$SVC-preview"
    ;;

  gateway)
    require_ready gateway
    apply_route gateway gateway gateway
    info "gateway Route created"
    show gateway
    ;;

  *) usage ;;
esac
