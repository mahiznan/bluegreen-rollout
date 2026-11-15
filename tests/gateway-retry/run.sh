#!/usr/bin/env bash
# Tests the gateway's Retry filter against a fake upstream. Needs NO cluster: it starts the
# gateway jar on :9085 and a fake upstream on :9099, then checks what the upstream received.
#
#   tests/gateway-retry/run.sh
#
# Expected: a request whose connection is closed before any answer is retried (2 hits, 200) for both
# GET and POST, with the POST body resent intact; a 503 answer and a timeout are NOT retried (1 hit).
set -euo pipefail
cd "$(dirname "$0")/../.."
JAR=services/gateway/target/gateway.jar
[[ -f "$JAR" ]] || (cd services/gateway && mvn -B -q package -DskipTests)
for p in 9085 9099; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then echo "port $p is already in use"; exit 1; fi
done

PIDS=()
cleanup() { for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT

python3 tests/gateway-retry/fake_upstream.py & PIDS+=($!)
( exec env SERVER_PORT=9085 PAYMENT_API_LIVE_URL=http://127.0.0.1:9099 RISK_DOMAIN_LIVE_URL=http://127.0.0.1:9099 \
    java -jar "$JAR" >/dev/null 2>&1 ) & PIDS+=($!)
for _ in $(seq 1 60); do curl -sf localhost:9085/actuator/health/readiness >/dev/null && break; sleep 1; done
curl -sf localhost:9085/actuator/health/readiness >/dev/null || { echo "gateway did not start"; exit 1; }

HOST="Host: gateway.apps-crc.testing"; ORIGIN="Origin: http://mfe.apps-crc.testing"
post() { curl -s -o /dev/null -w '%{http_code}' -m 12 -X POST localhost:9085/api/v1/payments/authorize \
           -H "$HOST" -H "$ORIGIN" -H "X-Case: $1" -H 'Content-Type: application/json' -d "{\"orderId\":\"$1\"}"; }
get()  { curl -s -o /dev/null -w '%{http_code}' -m 12 "localhost:9085/api/risk/score?amount=49.9" -H "X-Track: live" -H "X-Case: $1"; }
hits() { curl -s localhost:9099/stats | python3 -c "import json,sys; print(json.load(sys.stdin)['hits'].get(sys.argv[1], 0))" "$1"; }
bodies_equal() { curl -s localhost:9099/stats | python3 -c "import json,sys; b=json.load(sys.stdin)['bodies'].get(sys.argv[1], []); print(len(b) == 2 and b[0] == b[1] and b[0] != '')" "$1"; }

FAILED=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS  $1 ($2)"; else echo "  FAIL  $1: got $2, expected $3"; FAILED=1; fi; }

echo "closed connection (the router-reload race):"
check "POST status"            "$(post flaky:p1)" 200
check "POST upstream hits"     "$(hits 'POST flaky:p1')" 2
check "POST body resent intact" "$(bodies_equal 'POST flaky:p1')" True
check "GET status"             "$(get flaky:g1)" 200
check "GET upstream hits"      "$(hits 'GET flaky:g1')" 2
echo "answers that must NOT be retried:"
check "POST 503 status"        "$(post err503)" 503
check "POST 503 upstream hits" "$(hits 'POST err503')" 1
check "GET 503 status"         "$(get err503)" 503
check "GET 503 upstream hits"  "$(hits 'GET err503')" 1
check "POST timeout status"    "$(post slow)" 504
check "POST timeout upstream hits" "$(hits 'POST slow')" 1

[[ "$FAILED" == 0 ]] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
