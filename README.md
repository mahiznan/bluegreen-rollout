# Blue/green releases with pilot routing on OpenShift (CRC)

Two releases of every service run side by side. **Live users** keep using one release, **pilot users**
reach the new one through a separate address, and promoting the new release is a **change of Routes only**:
no Deployment, Pod, ConfigMap or Secret of a running service is touched. A k6 load test sends traffic from
both user groups while releases are flipped and rolled back, and counts **which release answered each
request**, at both hops.

It is the second project of a pair. [`../payments-rollout`](../payments-rollout/README.md) made a single
Deployment replace itself without dropping requests (probes, graceful shutdown). This one adds a release
model on top. The design rationale is in [`PLAN.md`](PLAN.md); this file is the guide for running and
testing it.

**This is a local learning project on OpenShift Local (CRC).** The "JWT" of the real system is replaced by
plain headers, there is one pod per release, and all numbers below come from single runs generated from one
Mac (see [Caveats](#caveats)).

## Contents

1. [Status](#1-status)
2. [The idea in one page](#2-the-idea-in-one-page)
3. [Release lifecycle and the flip](#3-release-lifecycle-and-the-flip)
4. [Repository layout](#4-repository-layout)
5. [Prerequisites and one-time setup](#5-prerequisites-and-one-time-setup)
6. [Quick start: deploy and open the pilot](#6-quick-start-deploy-and-open-the-pilot)
7. [Scripts reference](#7-scripts-reference)
8. [Configuration, ConfigMaps and Secrets](#8-configuration-configmaps-and-secrets)
9. [Test guide](#9-test-guide)
10. [Measured results](#10-measured-results)
11. [Findings](#11-findings)
12. [Troubleshooting](#12-troubleshooting)
13. [Cleanup](#13-cleanup)
14. [Limits and what is next](#14-limits-and-what-is-next)

---

## 1. Status

| Phase | What | State |
|---|---|---|
| 0 | Repo, plan | Done |
| 1 | Capacity prep (CRC disk grown to 50 GB, old `payment-api` scaled to 0) | Done |
| 2 | `risk-domain` (domain API) | Done, tested locally and in the cluster |
| 3 | `payment-api` (eAPI) calls the domain through the gateway | Done |
| 4 | `gateway` (Spring Cloud Gateway): edge rule, CORS, static routes | Done |
| 5 | `release.sh`, `bind.sh`, `status.sh`, Routes, project guard | Done, run on the cluster |
| 6 | Release B opened to the pilot | Done, run on the cluster |
| 7 | k6 pair counter, baseline | Done, results in `results/` |
| 8 | Flip, rollback, wrong-order flip under load; retrying gateway; reload stress | Done, results in `results/` |
| 9 | Failure drills (pilot bug, broken release, retire) | **Procedures written below, not yet run** |
| 10 | React MFE (Vite build) | **Not built yet** |
| 11 | This README with the final results | Updated after Phases 9 and 10 |

Every test in section 9 is marked **Verified** (it was run and the evidence is named) or **Not yet run**
(the procedure and the expected result are written, but the expectation is a prediction, not a measurement).

---

## 2. The idea in one page

"Blue" and "green" exist only as concepts. Nothing in OpenShift is named blue, green, v1 or v2.

| Concept | What it is in OpenShift |
|---|---|
| A **release** of a service | A set of objects named after the service **and the git commit**: `Deployment`, `Service`, `ConfigMap`, `Secret`, e.g. `payment-api-c8cd594` |
| Pod name | The Kubernetes default: `payment-api-c8cd594-5b7fd9db7c-6g458` |
| **live** | Whichever release `Service` the **live Route** points to |
| **preview** | Whichever release `Service` the **preview Route** points to |
| **The flip** | `oc patch route` changing which `Service` a Route points to (see [swap](#the-swap)) |
| "What is in prod?" | `scripts/status.sh`: Route, Service, image tag, and the commit the running pod reports |

### The release id is the git commit

The release of a service is **the last git commit that touched `services/<name>/`**
(`git log -1 --format=%h -- services/<name>`). Code, Dockerfile and config all live in that directory, so a
config-only change is also a new commit and a new release. `release.sh` **refuses to run if that directory
has uncommitted changes**, so one hash can never stand for two different contents. The commit is baked into
the image as `GIT_COMMIT` and each pod reports it in every response, so the running pod, not the object name,
is the source of truth.

### Addresses

There is **one public gateway URL**, and one **Route pair** per service. The pairs are what get swapped.

| Service | Live Route | Preview Route |
|---|---|---|
| `mfe` (what users browse; **Phase 10, not built**) | `mfe-bluegreen.apps-crc.testing` | `mfe-preview-bluegreen.apps-crc.testing` |
| `payment-api` (eAPI) | `payment-api-bluegreen.apps-crc.testing` | `payment-api-preview-bluegreen.apps-crc.testing` |
| `risk-domain` (domain API) | `risk-domain-bluegreen.apps-crc.testing` | `risk-domain-preview-bluegreen.apps-crc.testing` |
| `gateway` (single release, no pair) | `gateway-bluegreen.apps-crc.testing` | none |

The host names are `<route>-<project>.apps-crc.testing`; the project is `bluegreen`.

### Request flow

```
 Browser, page loaded from mfe... (live) or mfe-preview... (pilot)
   |  JavaScript calls the ONE gateway URL; the browser adds  Origin: <that MFE host>
   |  and the page sends X-User-Group (simulating the JWT claim)
   v
 gateway-bluegreen.apps-crc.testing        Spring Cloud Gateway, one deployment, static config
   edge rule: Origin (+ X-User-Group for the preview origin)  ->  TRACK  (live | pilot)
   stamps X-Track, overwrites any X-Track the client sent
        |  /api/v1/payments/**   track=live  -> payment-api-bluegreen...        (live Route)
        v                        track=pilot -> payment-api-preview-bluegreen... (preview Route)
 payment-api-<commit>        the eAPI: calls the gateway for a risk score, forwards X-Track
        |
        v   internal hop: http://gateway:8080  (the cluster Service, not a Route)
 gateway:  track=live  -> risk-domain-bluegreen...
           track=pilot -> risk-domain-preview-bluegreen...
        v
 risk-domain-<commit>        returns its score and its own identity
```

The gateway reaches the backends **through the Routes** (so the OpenShift router resolves the current
release), which is why a flip needs no gateway change. Its configuration is static.

### The edge decision

The track is decided **once, at the edge**, from the browser's `Origin` header (the MFE host the page came
from) and, for the preview origin, the simulated group. Both MFEs call the same gateway URL, so the `Host`
header cannot tell live from pilot, but `Origin` can, and page JavaScript cannot change it.

| `Origin` | Path | `X-User-Group` | Track | Result |
|---|---|---|---|---|
| `mfe-...` (live) | `/api/v1/payments/**` | any | `live` | live addresses |
| `mfe-preview-...` | `/api/v1/payments/**` | `pilot` | `pilot` | preview addresses |
| `mfe-preview-...` | `/api/v1/payments/**` | not `pilot` | | **403** |
| missing or any other origin | any | | | **403** |
| any | any other path, e.g. `/api/risk/...` | | | **404** (the domain API is internal only) |
| (internal hop, `Host` is not the public gateway host) | `/api/risk/**` | | from the incoming `X-Track` | missing or invalid `X-Track` = **403** |
| preflight `OPTIONS` from an allowed origin | | | | answered by CORS, no track needed |

`curl` and `http` send no `Origin`, so every request in this guide adds one explicitly. That is also how
k6 plays "a user on the live MFE" versus "a user on the preview MFE".

### The identity block

Every service reports who it is, and the domain's identity is **piped through the eAPI** into the final
response, so one response shows both hops:

```json
{
  "authId": "auth_...",
  "status": "PENDING_REVIEW",
  "orderId": "o-1",
  "replayed": false,
  "risk": { "score": 50, "decision": "REVIEW", "ruleSet": "strict" },
  "served": {
    "eapi":   { "service": "payment-api", "commit": "5467749", "pod": "payment-api-5467749-...", "secretFingerprint": "..." },
    "domain": { "service": "risk-domain", "commit": "b5490fc", "pod": "risk-domain-b5490fc-...", "secretFingerprint": "..." }
  },
  "receipt": "rcpt-ec979abb"
}
```

`secretFingerprint` is the first 8 hex characters of the SHA-256 of the release's secret: it proves which
secret a release runs without revealing it. `receipt` exists only in release B of `payment-api` (an additive
field added in Phase 6). `replayed:true` answers come from the eAPI's memory and do **not** call the domain
again, so k6 never counts them as a pair.

### Services

| Service | Stack | Role | Pods |
|---|---|---|---|
| `gateway` | Spring Cloud Gateway (WebFlux), Boot 4.0.9 + Spring Cloud 2025.1.4 | edge decision, routing, CORS, retry | 1 (single release) |
| `payment-api` | Spring Boot 4.1.2, Java 25 | eAPI: validates, asks for a risk score, simulates a 200 to 800 ms bank call | 1 per release |
| `risk-domain` | Spring Boot 4.1.2, Java 25 | domain API: `GET /api/risk/score?amount=`, score = amount / 20, capped at 99 | 1 per release |
| `mfe` | React + Vite (Phase 10) | the page users browse | 1 per release |

The gateway is on Boot 4.0.x because the latest GA Spring Cloud (2025.1.x) targets Boot 4.0.x; Spring Cloud
2026.0 targets Boot 4.2 and is still a release candidate.

---

## 3. Release lifecycle and the flip

Two releases of a service are called **A** (old) and **B** (new). They are just two commits.

```
S0  live -> A      preview -> A     first deploy only (no second release yet)
S1  deploy B's objects              not routed yet; nobody receives traffic
S2  bind preview -> B               THE PILOT OPENS   (live -> A, preview -> B)
S3a pilot OK       -> SWAP          live -> B, preview -> A   (A is kept as the rollback target)
S3b pilot not OK   -> do nothing to live; fix forward (deploy C, bind preview -> C) or close the pilot
S4  rollback       -> SWAP again    live -> A, preview -> B, instant because A is still running
S5  next release C goes to preview, so it REPLACES whatever is on preview
    (CRC cannot hold three releases per service, so the old rollback target is gone from then on)
```

### The swap

Promotion exchanges the two Routes of a service. Under the hood `bind.sh swap` runs exactly this, live first:

```bash
oc patch route payment-api         --type=merge -p '{"spec":{"to":{"name":"<preview release>"}}}'
oc patch route payment-api-preview --type=merge -p '{"spec":{"to":{"name":"<live release>"}}}'
```

It changes only `spec.to.name`. The OpenShift router watches Routes, rebuilds its host-to-pods table and
reloads. Both releases keep running the whole time, so no request is sent to a Service without ready pods,
which is the one thing that would make the flip fail (the router answers `503 Application is not available`).
`bind.sh` therefore **checks that the target has ready pods before it patches anything**.

Preview then always points at the other release: after a flip it holds the previous release as the rollback
target, and **rollback is the same swap**.

### Flip order across services

A Route change is applied by the router within seconds, and two Routes can never change atomically, so for
a few seconds live traffic meets a mix of releases. Three rules follow, all measured in section 10:

1. **Promote callee first:** `risk-domain`, then `payment-api` (then the MFE). Live users then briefly see
   (**old eAPI, new domain**), which backward compatibility protects.
2. **Roll back caller first:** `payment-api`, then `risk-domain`. Rolling the domain back first would give
   live users (**new eAPI, old domain**), the unsafe direction. So the same command
   `flip.sh payment-api risk-domain` is a correct rollback but a **wrong-order promotion**.
3. **Because a swap moves both Routes, the pilot group experiences the opposite order.** During a correct
   promotion the pilot users briefly get (new eAPI, old domain) while their release is swapped away. It
   affects testers only and lasts about as long as the gap between swaps. Expect it; it is not a fault.

### Timing

In every run with a measured flip, the Route changes took effect at **about +2 s, +7 s and +12 s after the
start of `flip.sh --gap 5`**: the router applies the first change almost at once and the next ones on its
reload tick, about 5 seconds apart (Run 1 shows the same 5-second spacing, measured from a different epoch).
So the two Routes of one service move up to 5 seconds apart, the live mix lasts about 10 seconds and the pilot
mix about 5. **Adjacent releases must therefore be backward compatible for 10 to 15 seconds.**

---

## 4. Repository layout

```
PLAN.md                         the design, with the reasoning and every decision
README.md                       this file
services/
  gateway/                      Spring Cloud Gateway (single release)
    src/main/java/.../TrackFilter.java   the edge decision (Origin + X-User-Group -> X-Track)
    src/main/java/.../CorsConfig.java    CORS for exactly the two MFE origins
    src/main/resources/application.yaml  static routes, pool limits, Retry filter
    k8s/*.tmpl.yaml                      ConfigMap, Service, Deployment templates
  payment-api/                  the eAPI (src, Dockerfile, k8s templates)
  risk-domain/                  the domain API (src, Dockerfile, k8s templates)
routes/route.tmpl.yaml          the binding layer: one template for every Route
scripts/
  lib.sh                        shared helpers and the project guard
  release.sh                    build + deploy one release (binds nothing)
  bind.sh                       init / preview / swap / gateway: the only script that touches Routes
  flip.sh                       swap several services in an order, with an optional gap
  status.sh                     the "what is in prod?" table
  retire.sh                     remove one release (refuses if a Route points at it)
  render-secrets.sh             the simulated vault (derives a secret per release)
  timeline.sh                   k6 CSV -> segments of "which pair served when"
k6/pairs.js                     the load test and the pair counter
tests/gateway-retry/            local test of the gateway Retry filter (no cluster needed)
results/                        saved k6 summaries (*.txt are committed, *.csv are ignored)
```

Release objects (`services/*/k8s`) and binding objects (`routes/`) are kept apart on purpose: a release is
immutable and named by commit, a Route is just an address.

---

## 5. Prerequisites and one-time setup

### Tools on your machine

| Tool | Used for |
|---|---|
| `oc` 4.17, logged in to CRC | everything in the cluster |
| `k6` | the load tests |
| HTTPie (`http`) and `jq` | the manual requests in this guide |
| `git`, `envsubst` (Homebrew `gettext`), `rsync`, `shasum` | `release.sh` |
| JDK 25 and Maven | only to run a service locally; images are built **in the cluster** |

### CRC capacity

The cluster is small, and this project needs room for about 5 to 7 pods plus builds.

| Resource | Needed | How it was provided |
|---|---|---|
| VM disk | builds are evicted below about 4.9 GB free; each build adds layers | `crc stop`, `crc config set disk-size 50`, `crc start` (50 GB total, 27 GB free afterwards) |
| Schedulable memory | pod requests: `risk-domain` 96 Mi, `payment-api` 96 Mi, `gateway` 128 Mi | the 3-pod project 1 app was scaled to 0 (`oc scale deployment/payment-api --replicas=0` in `my-project`) |

`oc describe node` shows the allocation; a pod stuck `Pending` is the symptom of too little memory.

### The project

The demo runs in **its own OpenShift project**, `bluegreen`, not in `my-project`: project 1 left Routes, a
Deployment and a BuildConfig named `payment-api` there, which would collide with this project's Routes. The
scripts refuse to run in any other project.

```bash
oc login ...                  # as the developer user
oc new-project bluegreen      # once; it also switches you to it
oc project -q                 # must print: bluegreen
```

### Check that pods can reach the Route host names (once)

The gateway calls `*.apps-crc.testing` from inside a pod, so a pod must resolve those names. An answer of any
HTTP status proves resolution and a path to the router (even the router's own `503 Application is not
available` page); `Could not resolve host` means it does not work.

```bash
oc run dns-check --rm -it --restart=Never --image=registry.access.redhat.com/ubi9/ubi-minimal -- \
  curl -sI http://payment-api-bluegreen.apps-crc.testing
```

### Shell notes (zsh)

- Quote any URL that contains `?` or `&`, or let HTTPie build the query string with `==`
  (`http localhost:8090/api/risk/score amount==250`).
- zsh does not word-split an unquoted variable, so keep multi-word values in arrays or write them out.

---

## 6. Quick start: deploy and open the pilot

All commands run from this directory, in project `bluegreen`.

### 6.1 Release A (the first deployment), callee first

```bash
scripts/release.sh risk-domain      # one build at a time (memory). Ends with:
                                    #   "verified: the running pod reports commit <hash>"
scripts/bind.sh init risk-domain <hash printed by the release>

scripts/release.sh payment-api
scripts/bind.sh init payment-api <hash>

scripts/release.sh gateway
scripts/bind.sh gateway

scripts/status.sh
```

Each `release.sh` ends by printing the exact `bind.sh` command to run next. The first builds take a few
minutes (Maven downloads). `bind.sh init` creates **both** Routes of a service pointing at the same release
(state S0).

### 6.2 Release B and open the pilot

Make a change in a service directory, **commit it**, then:

```bash
scripts/release.sh risk-domain                 # B's objects run, bound to nothing
scripts/bind.sh preview risk-domain <B>        # prints a warning, asks y/N, then points preview at B

scripts/release.sh payment-api
scripts/bind.sh preview payment-api <B>
scripts/status.sh
```

Bind the **domain first**, so that pilot users never see a chain with a new eAPI calling an old domain.

In this repository, release B differs from A like this:

| Service | Change in B | Visible effect |
|---|---|---|
| `risk-domain` | **config only**: rule set `strict`, review threshold 60 → 40, decline threshold 90 → 80 | `amount=1000` (score 50): `APPROVE` on A, `REVIEW` on B |
| `payment-api` | **code**: an additive response field `receipt` | present in B's answers, missing in A's |

### 6.3 What `status.sh` shows (a real run, A live, B on preview)

```
Project: bluegreen

SERVICE      ROLE       TARGET                     READY  IMAGE-TAG POD-COMMIT NOTE
payment-api  live       payment-api-c8cd594        1/1    c8cd594   c8cd594
payment-api  preview    payment-api-5467749        1/1    5467749   5467749    next release (pilot)
risk-domain  live       risk-domain-09c7931        1/1    09c7931   09c7931
risk-domain  preview    risk-domain-b5490fc        1/1    b5490fc   b5490fc    next release (pilot)
gateway      single     gateway                    1/1    2dc8b0a   2dc8b0a
```

`POD-COMMIT` is read from inside the running pod. If it differs from `IMAGE-TAG`, the row is flagged
`MISMATCH`. After a flip the preview row reads `previous release (rollback target)`.

---

## 7. Scripts reference

| Script | Usage | What it does |
|---|---|---|
| `release.sh` | `scripts/release.sh [--render-only] [--rebuild] [-y] <service>` | Refuses a dirty tree. Builds the image in the cluster tagged with the commit, creates the ConfigMap, Secret, Service and Deployment named `<service>-<commit>`, waits for the rollout, and then **checks that the running pod reports that commit**. Binds no Route. `--render-only` writes the YAML to `.rendered/` and validates it client-side without changing the cluster; `--rebuild` rebuilds an image whose tag already exists |
| `bind.sh` | `init <service> <commit>` / `preview <service> <commit>` / `swap <service>` / `gateway` (add `-y` to skip the question) | The **only** script that touches Routes. Every command first checks the target Service has ready pods. `preview` warns that the release currently on preview becomes unreachable |
| `flip.sh` | `scripts/flip.sh [-y] [--dry-run] [--gap SECONDS] <service> [<service> ...]` | Swaps services in the order given. **Checks every service before the first swap**, so a problem never leaves a half-done flip. Prints start and finish epochs. `--dry-run` only checks |
| `status.sh` | `scripts/status.sh` | The table in 6.3. Read-only |
| `retire.sh` | `scripts/retire.sh [-y] <service> <commit>` | Deletes a release's objects and image tag. **Refuses if a Route still points at it.** For the gateway it removes only the old config and image tag |
| `timeline.sh` | `scripts/timeline.sh <k6.csv> [epoch]` | Turns a k6 CSV into segments of consecutive seconds with the same set of `eapi/domain` pairs. A segment with two pairs is marked `<- MIX`. Pass the **start** epoch printed by `flip.sh` so that `t=0` is the first patch |
| `render-secrets.sh` | `scripts/render-secrets.sh <service> <commit>` | The simulated vault: prints `KEY=value`, derived from service and commit, so every release has a different secret. Nothing is stored |
| `lib.sh` | sourced | Helpers and the **project guard**: scripts stop unless the current project is `bluegreen` (override with `BLUEGREEN_NAMESPACE`) |

Environment: `APPS_DOMAIN` (default `apps-crc.testing`), `BLUEGREEN_NAMESPACE` (default `bluegreen`).

**Why the commit is set on the BuildConfig:** `oc start-build --from-dir --build-arg=...` silently drops the
argument for binary builds, so images built that way report `unknown`. `release.sh` sets
`dockerStrategy.buildArgs` on the BuildConfig before each build instead, and verifies the commit inside the
running pod so this cannot pass unnoticed again.

---

## 8. Configuration, ConfigMaps and Secrets

Every release has its own **immutable** ConfigMap and its own Secret, named after the commit, and the same
image and config run first as preview and later as live. No service knows its own role.

| Object | Name | Contents |
|---|---|---|
| ConfigMap | `risk-domain-<commit>-config` | `RISK_RULE_SET`, `RISK_REVIEW_THRESHOLD`, `RISK_DECLINE_THRESHOLD` |
| ConfigMap | `payment-api-<commit>-config` | `RISK_DOMAIN_URL` (`http://gateway:8080`), connect/read timeouts, `BANK_MIN_LATENCY_MS`, `BANK_MAX_LATENCY_MS` |
| ConfigMap | `gateway-<commit>-config` | the public host, the two MFE origins, and the live and preview Route URLs of both backends |
| Secret | `risk-domain-<commit>-secrets`, `payment-api-<commit>-secrets` | `RISK_API_KEY`, `PAYMENT_API_KEY` (from `render-secrets.sh`) |
| Image | `<service>:<commit>` in the internal registry | built by `release.sh`, never `:latest` |

- **Config is immutable and named by commit** because editing a plain ConfigMap does not restart pods. A
  config change is a commit, so it is a new release with new objects and new pods. The Phase 6 change to
  `risk-domain` is exactly that.
- **The gateway's ConfigMap is also named by commit** even though the gateway is a single release: a new
  commit renames the ConfigMap, which changes the pod template and rolls the gateway with the hardened rolling
  update.
- **Fingerprint check:** the `secretFingerprint` in a response is the first 8 hex characters of the SHA-256 of
  the secret value. The same formula applied to the value `abc` gives `ba7816bf`, which was checked locally.
- The secrets in this demo are derived values, not real secrets. Never commit real ones; `.rendered/` and
  `*.secret` are in `.gitignore`.

---

## 9. Test guide

### 9.0 Setup shared by all tests

```bash
# Read the four commits from scripts/status.sh. Example values from the real runs:
export A_EAPI=c8cd594 A_DOM=09c7931        # release A: live
export B_EAPI=5467749 B_DOM=b5490fc        # release B: preview

export GW=http://gateway-bluegreen.apps-crc.testing
export LIVE_ORIGIN=http://mfe-bluegreen.apps-crc.testing
export PREVIEW_ORIGIN=http://mfe-preview-bluegreen.apps-crc.testing

# pay <origin> <idempotency-key> <amount> [extra HTTPie items, e.g. X-User-Group:pilot]
pay() { local origin=$1 key=$2 amount=$3; shift 3
  http --ignore-stdin -b POST $GW/api/v1/payments/authorize Origin:$origin Idempotency-Key:$key "$@" \
    orderId=o-1 amount:=$amount currency=USD cardToken=t; }
```

`pay` was run on the cluster and works in zsh. Use a **new** `Idempotency-Key` each time (`t-$RANDOM`): a
repeated key is a replay and skips the domain.

The k6 command used throughout (the commits differ per service, so there are two lists):

```bash
k6 run -e DURATION=60s \
  -e EAPI=$A_EAPI,$B_EAPI -e DOMAIN=$A_DOM,$B_DOM \
  [-e EXPECT_STANDARD=$A_EAPI,$A_DOM -e EXPECT_PILOT=$B_EAPI,$B_DOM] \
  --out csv=results/NAME.csv  k6/pairs.js 2>&1 | tee results/NAME.txt
```

| k6 setting | Meaning |
|---|---|
| `EAPI`, `DOMAIN` | every commit you expect, per service. The summary prints a count for **every** combination, including the ones that should stay 0 |
| `EXPECT_STANDARD`, `EXPECT_PILOT` | optional `eapi,domain`: every answer must be exactly that pair. Use them for baselines, **not** while a flip is in progress |
| `STD_RPS` (30), `PILOT_RPS` (10), `DURATION` (60s) | the load. Standard users send `Origin` = the live MFE; pilot users send `Origin` = the preview MFE plus `X-User-Group: pilot` |
| `BASE_URL`, `MFE_LIVE`, `MFE_PREVIEW` | override the addresses |
| `unexpected_pair` | a counter that fails the run if a commit not in your lists answers |

How to read the result:

- The `pairs{group:...,eapi:...,domain:...}` lines count answers per pair. `standard` = live users.
- `failed_requests{status:N}` counts failures by status (`0` is a timeout or connection error).
- Failures also log `... FAIL <group> status=NNN`. To list them per second:
  `grep ' FAIL ' results/NAME.txt | awk '{print substr($1,18,8), $5, $6}' | sort | uniq -c`
- k6 exits with code 99 when a threshold fails. That is expected in the drills that provoke failures.

Test order: run **T1 to T11 first**, then the drills **D1 to D5**. D3 and D5 are destructive (they consume a
release), so they go **last**.

**The state moves.** The load tests start from the standard state **live = A, preview = B**. T7 promotes B
(live = B), T8 rolls back (live = A), and T9 promotes again (live = B), so run them in that order, or use
`scripts/status.sh` to see where you are and start each from the state it names.

Status legend: **Verified** = run, evidence named. **Not yet run** = procedure and prediction only.

---

### Part A: functional tests

#### T1. Safety rails: the scripts refuse the dangerous thing  (Verified)

None of these changes the cluster.

| # | Command | Expected |
|---|---|---|
| a | `oc project my-project && scripts/status.sh; oc project bluegreen` | `ERROR: current project is 'my-project' but this demo runs in 'bluegreen'...` |
| b | `touch services/risk-domain/x.txt && scripts/release.sh risk-domain; rm services/risk-domain/x.txt` | `ERROR: uncommitted changes in services/risk-domain. Commit them first...` before anything is built |
| c | `scripts/retire.sh payment-api <the live commit>` | `ERROR: Route 'payment-api' still points at payment-api-<commit>. Swap or re-bind first.` |
| d | `scripts/flip.sh --dry-run --gap 5 risk-domain payment-api` | lists each service's live and preview release, then `dry run: nothing was changed` |

Evidence: (a), (b) and (c) were run against the live cluster, and (c) was also hit for real during Phase 5
when a retire was attempted before its replacement was bound. The refusal of an **unready** target is covered
by drill D4.

#### T2. The edge decision matrix  (Verified, Phase 5 and 6)

State: both Routes of each service bound (any state works; the commits below are for live = A, preview = B).

```bash
# 1. live user
pay $LIVE_ORIGIN t-$RANDOM 1000 | jq -c '{status,eapi:.served.eapi.commit,domain:.served.domain.commit}'
# 2. pilot user
pay $PREVIEW_ORIGIN t-$RANDOM 1000 X-User-Group:pilot | jq -c '{status,eapi:.served.eapi.commit,domain:.served.domain.commit}'
# 3. preview origin without the group  -> 403
http --ignore-stdin --print=hb POST $GW/api/v1/payments/authorize Origin:$PREVIEW_ORIGIN Idempotency-Key:t-$RANDOM orderId=o-1 amount:=1000 currency=USD cardToken=t
# 4. a client claiming the pilot track by header on the live origin -> still live
pay $LIVE_ORIGIN t-$RANDOM 1000 X-Track:pilot | jq -c '{eapi:.served.eapi.commit,domain:.served.domain.commit}'
# 5. no Origin at all -> 403
http --ignore-stdin --print=hb POST $GW/api/v1/payments/authorize Idempotency-Key:t-$RANDOM orderId=o-1 amount:=1000 currency=USD cardToken=t
# 6. the domain API is not exposed at the edge -> 404
http --ignore-stdin --print=h GET "$GW/api/risk/score" amount==250 Origin:$LIVE_ORIGIN
```

| # | Expected |
|---|---|
| 1 | `APPROVE`, eAPI `$A_EAPI`, domain `$A_DOM`, no `receipt` |
| 2 | `PENDING_REVIEW` (rule set `strict`), eAPI `$B_EAPI`, domain `$B_DOM`, with `receipt` |
| 3 | `403 {"error":"preview is for the pilot group only"}` |
| 4 | still `$A_EAPI` / `$A_DOM` (the client's `X-Track` is overwritten) |
| 5 | `403 {"error":"missing or unknown Origin"}` |
| 6 | `404` |

Evidence: all six requests were run on the cluster and gave the expected results, and the same matrix passed
locally in Phase 4. In Phase 6, 20 live plus 20 pilot requests gave exactly 20 × (A,A) and 20 × (B,B), no mixes.

#### T3. CORS preflight  (Verified on the cluster)

A browser sends a preflight `OPTIONS` request before a cross-origin `POST`. It carries no `X-User-Group`, so
the CORS filter must answer it before the track rules run.

```bash
http --ignore-stdin --print=h OPTIONS $GW/api/v1/payments/authorize Origin:$PREVIEW_ORIGIN \
  Access-Control-Request-Method:POST Access-Control-Request-Headers:content-type,idempotency-key,x-user-group
http --ignore-stdin --print=h OPTIONS $GW/api/v1/payments/authorize Origin:http://evil.example \
  Access-Control-Request-Method:POST
```

Expected: the first returns `200` with `access-control-allow-origin: <the preview origin>`, allowed methods
`GET,POST,OPTIONS`, allowed headers `content-type, idempotency-key, x-user-group`, exposed header `X-Track`
and `max-age: 3600`. The second returns `403` with no CORS headers. This is the closest thing to a browser we
have until Phase 10.

#### T4. Release B in isolation, then open the pilot  (Verified, Phase 6: steps 2 and 3)

Steps are in [6.2](#62-release-b-and-open-the-pilot). Check that live users are unaffected while B runs:

1. After `release.sh` of both services and **before** any `bind.sh preview`: `scripts/status.sh` shows B as
   `unbound`, and T2 requests 1 and 2 both still answer from A. (This follows from how the scripts work and
   was not captured separately in the real run.)
2. After `bind.sh preview risk-domain <B>` and `bind.sh preview payment-api <B>`: T2 request 2 answers from B,
   request 1 still from A. (Observed.)
3. `amount=1000` gives `APPROVE`/`default` on A and `PENDING_REVIEW`/`strict` on B; `receipt` appears only on B.
   (Observed.)

#### T5. A replay is answered from the eAPI's memory and skips the domain  (Verified on the cluster)

```bash
K=replay-$RANDOM
pay $LIVE_ORIGIN $K 250 | jq -c '{replayed,eapi_pod:.served.eapi.pod,domain_pod:.served.domain.pod,authId}'
pay $LIVE_ORIGIN $K 250 | jq -c '{replayed,eapi_pod:.served.eapi.pod,domain_pod:.served.domain.pod,authId}'
```

Expected and observed: the first answer has `replayed:false`, the second `replayed:true` with the **same**
`authId` (derived from the key) and the same `domain` pod. The domain identity in a replay is the one from the
first call, which is why k6 counts only `replayed:false` answers as a pair.

---

### Part B: load tests with k6

All use the standard state: **live = A, preview = B**, both groups sending traffic.

#### T6. Baseline: no change, 60 s  (Verified, `results/phase7-baseline.txt`)

```bash
k6 run -e DURATION=60s -e EAPI=$A_EAPI,$B_EAPI -e DOMAIN=$A_DOM,$B_DOM \
  -e EXPECT_STANDARD=$A_EAPI,$A_DOM -e EXPECT_PILOT=$B_EAPI,$B_DOM \
  --out csv=results/baseline.csv k6/pairs.js 2>&1 | tee results/baseline.txt
```

Expected and observed: standard users all `(A,A)`, pilot users all `(B,B)`, every other pair 0,
`unexpected_pair` 0, 0 failed requests, 0 dropped iterations, all checks passed.

#### T7. The flip under load, callee first  (Verified, Runs 1 and 4)

```bash
# terminal 1: 120 s of traffic (Run 1 used 180 s)
k6 run -e DURATION=120s -e EAPI=$A_EAPI,$B_EAPI -e DOMAIN=$A_DOM,$B_DOM \
  --out csv=results/flip.csv k6/pairs.js 2>&1 | tee results/flip.txt

# terminal 2, about 30 s after k6 starts. Note the epoch it prints: "flip started at epoch ..."
scripts/flip.sh -y --gap 5 risk-domain payment-api

# afterwards
scripts/timeline.sh results/flip.csv <START epoch>
grep ' FAIL ' results/flip.txt | awk '{print substr($1,18,8), $5, $6}' | sort | uniq -c
```

Do not set `EXPECT_*` here: a mix is expected.

| Group | Before | Mix (about) | After | Must stay 0 |
|---|---|---|---|---|
| Standard (live) | `$A_EAPI/$A_DOM` | `$A_EAPI/$B_DOM`: old eAPI with new domain, about 10 s, about 300 answers | `$B_EAPI/$B_DOM` | `$B_EAPI/$A_DOM` |
| Pilot | `$B_EAPI/$B_DOM` | `$B_EAPI/$A_DOM`: new eAPI with old domain, about 5 s, about 50 answers | `$A_EAPI/$A_DOM` | `$A_EAPI/$B_DOM` |

The Route changes appear at about **+2 s, +7 s and +12 s** after the flip starts. Observed: see section 10.

#### T8. Rollback, caller first  (Verified, Runs 2 and 5)

Start from live = B, preview = A (the state after T7). Same k6 command (name the output `rollback`), and:

```bash
scripts/flip.sh -y --gap 5 payment-api risk-domain
```

| Group | Before | Mix (about) | After |
|---|---|---|---|
| Standard (live) | `$B_EAPI/$B_DOM` | `$A_EAPI/$B_DOM` (old eAPI, new domain: safe), about 300 answers | `$A_EAPI/$A_DOM` |
| Pilot | `$A_EAPI/$A_DOM` | `$B_EAPI/$A_DOM`, about 51 answers | `$B_EAPI/$B_DOM` |

Live users are back on A about 13 s after the command starts, and the unsafe pair never reaches them.

#### T9. The wrong-order promotion  (Verified, Run 3)

Start from live = A, preview = B. The **same command as T8**, now promoting, which is the wrong order:

```bash
scripts/flip.sh -y --gap 5 payment-api risk-domain
```

| Group | Before | Mix (about) | After |
|---|---|---|---|
| Standard (live) | `$A_EAPI/$A_DOM` | **`$B_EAPI/$A_DOM`: new eAPI with old domain, about 299 answers (the unsafe pair)** | `$B_EAPI/$B_DOM` |
| Pilot | `$B_EAPI/$B_DOM` | `$A_EAPI/$B_DOM`, about 50 answers | `$A_EAPI/$A_DOM` |

It is harmless in this demo because B's eAPI works with A's domain. It would break live users if B's eAPI
needed a feature that only B's domain has. The point of the test is that the unsafe pair **does** reach live
users when the order is wrong, and does not when it is right.

#### T10. The gateway retry filter  (Verified, `tests/gateway-retry/run.sh`)

Needs no cluster. It starts the gateway jar and a fake upstream that kills the first connection of a request
without answering, which is what the router does to a pooled connection when it reloads.

```bash
tests/gateway-retry/run.sh
```

Expected output: `ALL PASSED`, with these checks:

| Case | Status | Upstream hits |
|---|---|---|
| `POST`, connection closed before any answer | 200 | **2**, with the identical body both times |
| `GET`, connection closed before any answer | 200 | **2** |
| `POST` or `GET`, upstream answers 503 | 503 | **1** (a real outage is not multiplied) |
| `POST`, upstream slower than the 5 s response timeout | 504 | **1** (a slow service is not hammered) |

Only `java.io.IOException` is retried (2 retries, 50 ms backoff). A repeat of `authorize` is safe because it
carries an `Idempotency-Key`; the risk lookup is a read.

#### T11. Reload stress  (Verified as run; see the caveat, `results/phase8-retry-stress.txt`)

Many Route changes under load, to give the connection-closed race many chances to occur. Swapping only
`payment-api` back and forth is harmless here, and an even count leaves the state unchanged.

```bash
# terminal 1
k6 run -e DURATION=120s -e EAPI=$A_EAPI,$B_EAPI -e DOMAIN=$A_DOM,$B_DOM k6/pairs.js 2>&1 | tee results/stress.txt
# terminal 2, about 15 s after k6 starts
for i in 1 2 3 4 5 6 7 8; do scripts/flip.sh -y payment-api; sleep 6; done
# afterwards
grep ' FAIL ' results/stress.txt | awk '{print substr($1,18,8), $5, $6}' | sort | uniq -c
oc logs deploy/gateway | grep -c "observed an error"
scripts/status.sh                       # the same state as before the loop
```

How to read it: `FAIL` lines mean a request failed. A non-zero error count with **no** `FAIL` lines means the
race happened and the retry absorbed it. Zero of both means the race did not fire. The result was **zero of
both**, so the retry has not been shown to save a request in this cluster (see section 11).

---

### Part C: failure drills (Phase 9, **Not yet run**)

Every expectation below is a **prediction** until you run it. Run each drill with the load test going in a
second terminal (T7's k6 command with `DURATION=150s`, without `EXPECT_*`, writing `results/d1.txt`,
`results/d2.txt` and so on), so you can see whether live users notice.

**Reset to the standard state** (live = A, preview = B) before D1, D2 and D4:

```bash
scripts/status.sh
# If live is B (the state after T9), first go back to A with a quiet flip, caller first, with no load running:
scripts/flip.sh -y payment-api risk-domain
# Then make sure B is on preview for both services:
scripts/bind.sh -y preview risk-domain  $B_DOM
scripts/bind.sh -y preview payment-api  $B_EAPI
scripts/status.sh            # live = A, preview = B for both services, all rows READY 1/1
```

(This works only while both A and B still exist. D3 and D5 consume releases, so they come last.)

#### D1. The pilot finds a bug: do nothing to live

The requirement: "if the pilot has issues, we don't do anything". Simulate a broken release B by removing
its domain pods; live must not notice.

```bash
# terminal 2, about 30 s into the k6 run
oc scale deployment/risk-domain-$B_DOM --replicas=0
# watch for about 60 s, then recover
oc scale deployment/risk-domain-$B_DOM --replicas=1
oc rollout status deployment/risk-domain-$B_DOM
grep ' FAIL ' results/d1.txt | awk '{print $5, $6}' | sort | uniq -c       # failures per group and status
```

Prediction: pilot users get `503` (the preview Route has no ready pods, the router returns 503, the gateway
passes it on, and `payment-api` answers "risk service unavailable"). **Standard users: 0 failures and only
`(A,A)` pairs the whole time.** k6 exits with code 99, because its thresholds are meant to fail here. The
gateway does **not** retry a 503, by design. After scaling back, pilot users recover once the pod is ready
(a JVM start takes a few tens of seconds).

#### D2. Close the pilot (rebind preview to A)

Roll the preview track back to A, caller first:

```bash
scripts/bind.sh -y preview payment-api $A_EAPI
scripts/bind.sh -y preview risk-domain $A_DOM
scripts/status.sh
```

Prediction: pilot users go `(B,B)` → briefly `($A_EAPI/$B_DOM)` → `(A,A)`; standard users stay `(A,A)` throughout;
0 failures. `bind.sh` warns each time that the release leaving preview becomes unreachable. B's objects keep
running, unbound, and can be reopened with the reset above.

#### D3. Fix forward: release C replaces B on preview  (destructive)

```bash
# 1. change risk-domain (for example RISK_DECLINE_THRESHOLD in services/risk-domain/k8s/configmap.tmpl.yaml), then:
git add services/risk-domain && git commit -m "risk-domain release C"
scripts/release.sh risk-domain                  # note the new commit <C>
scripts/bind.sh preview risk-domain <C>         # warns that B is replaced on preview; answer y
scripts/status.sh
# 2. optional: B is now unbound; remove it
scripts/retire.sh risk-domain $B_DOM
```

Prediction: standard users stay `(A,A)` with 0 failures; pilot users now get the new domain `<C>` (with
`payment-api` B or A, depending on what is on preview). This consumes B.

#### D4. A broken release never receives traffic

A release whose service cannot start. Use a throwaway branch so `main` keeps a clean history. A non-numeric
threshold crashes `risk-domain` at startup; this was checked locally (exit code 1, `TypeMismatchException:
Failed to convert ... "abc"`).

```bash
git checkout -b drill-broken-release
# set RISK_REVIEW_THRESHOLD: "abc" in services/risk-domain/k8s/configmap.tmpl.yaml, then
git commit -am "DRILL: broken release (non-numeric threshold)"
scripts/release.sh risk-domain         # builds and applies; the rollout never completes.
                                       # Wait for "timed out" (5 min) or press Ctrl+C once you see the crash loop
BAD=$(git log -1 --format=%h -- services/risk-domain)
oc get pods -l app=risk-domain,commit=$BAD                      # Error / CrashLoopBackOff, never Ready
oc logs deploy/risk-domain-$BAD | grep -E "TypeMismatch|NumberFormat"     # add --previous if the container is between restarts
scripts/bind.sh preview risk-domain $BAD                        # must refuse
scripts/status.sh                                               # live and preview untouched; the bad release is "unbound", not ready
# cleanup
scripts/retire.sh -y risk-domain $BAD
git checkout main && git branch -D drill-broken-release
```

Prediction: `release.sh` exits non-zero after the rollout timeout and **does not** reach its commit
verification; `bind.sh preview` fails with `ERROR: Service 'risk-domain-<bad>' has no ready pods. Binding a
Route to it would make the router return 503.`; live and pilot traffic show 0 failures and unchanged pairs the
whole time.

#### D5. Retire the old release after a flip, under load  (destructive, run last)

```bash
# precondition: live = A, preview = B, k6 running
scripts/flip.sh -y --gap 5 risk-domain payment-api      # live = B, preview = A
sleep 30
scripts/bind.sh -y preview risk-domain $B_DOM           # preview = B too, so A is unbound
scripts/bind.sh -y preview payment-api $B_EAPI
scripts/status.sh                                       # A's rows read "unbound"
scripts/retire.sh -y payment-api $A_EAPI
scripts/retire.sh -y risk-domain $A_DOM
scripts/status.sh                                       # one release per service
```

Prediction: 0 failures through the whole sequence, live users `(B,B)` after the flip, and A's pods terminating
without an error (they use the hardened shutdown from project 1: probes, graceful shutdown, `preStop`).
`retire.sh` deletes A's image tags, so **A cannot be recreated** afterwards.

---

### Part D: the MFE (Phase 10, **Not built yet**)

The React app has not been written, so none of these has run. This is the plan, and the commands use the
release scripts that already exist.

| # | Test | Steps | Prediction |
|---|---|---|---|
| M1 | Release and bind the MFE | `scripts/release.sh mfe`, then `scripts/bind.sh init mfe <commit>` | `status.sh` shows an `mfe` row; `http://mfe-bluegreen.apps-crc.testing` and `http://mfe-preview-bluegreen.apps-crc.testing` both serve the page |
| M2 | Commit banner | open both hosts in a browser | each page shows the commit it was built from |
| M3 | Real browser CORS | DevTools, Network tab, press "authorize" | a preflight `OPTIONS` (200) followed by the `POST`, with `Origin` = the MFE host. No CORS error in the console |
| M4 | Pilot selector | on the preview host choose "pilot", then a non-pilot group | pilot: a normal answer from B; non-pilot: the page shows the gateway's 403 (readable, because the 403 carries the CORS header) |
| M5 | MFE flip under load | k6 running, then `scripts/flip.sh -y --gap 5 risk-domain payment-api mfe` | the live host serves the new page after the swap; k6 still 0 failures |
| M6 | A tab open across a flip | keep a live tab open during M5, reload it afterwards | the old tab keeps working (its `Origin` is still the live host, so it moves to the new live API), a reload shows the new page |

### Optional extras

- Repeat T7 to T9 three times each and compare, because every figure in section 10 is a single run.
- Run T6 at a higher rate (`-e STD_RPS=80 -e PILOT_RPS=20`) to find where the single gateway pod saturates.
- A first look at a shorter `--gap` (for example `--gap 0`): the router ticks about 5 s apart, so a shorter
  gap may shrink the mix window to one tick. Unmeasured.

---

## 10. Measured results

Every figure comes from the saved summaries in `results/` (`*.txt` are committed). Pairs are `eapi/domain`.
A = `c8cd594/09c7931`, B = `5467749/b5490fc`. Load: 30 rps standard plus 10 rps pilot, generated on a Mac.

### Overview

| Run | File | Requests | Failed | Max latency | Notes |
|---|---|---|---|---|---|
| Baseline, 60 s | `phase7-baseline.txt` | 2,403 | **0** | 905 ms | 1,801 standard `(A,A)`, 600 pilot `(B,B)`, all else 0 |
| **Run 1**: flip, 180 s | `phase8-flip.txt` | 7,204 | **2** | 832 ms | a 500 and a 503, same second, standard path |
| **Run 2**: rollback, 120 s | `phase8-rollback.txt` | 4,804 | **0** | 865 ms | |
| **Run 3**: wrong-order flip, 120 s | `phase8-wrong-order.txt` | 4,804 | **1** | 1.17 s | one 503, standard path |
| **Run 4**: flip on the retrying gateway | `phase8-retry-flip.txt` | 4,803 | **0** | 899 ms | no gateway connection errors logged |
| **Run 5**: rollback on the retrying gateway | `phase8-retry-rollback.txt` | 4,803 | **0** | 839 ms | no gateway connection errors logged |
| **Run 6**: 8-swap reload stress | `phase8-retry-stress.txt` | 4,804 | **0** | 846 ms | no gateway connection errors logged |

All runs had 0 dropped iterations and 0 `unexpected_pair`. Baseline p95 was 780 ms (the bank call is simulated
at 200 to 800 ms). The first three flips on the original gateway had 3 failed requests in 16,812; the three
runs on the retrying gateway had 0 in 14,410.

### Which pair answered (answer counts)

| Run | Group | Before | Mix | After |
|---|---|---|---|---|
| 1 flip | standard | A,A 1,025 | `c8cd594/b5490fc` **298** | B,B 4,076 |
| | pilot | B,B 392 | `5467749/09c7931` **50** | A,A 1,359 |
| 2 rollback | standard | B,B 997 | `c8cd594/b5490fc` **300** | A,A 2,304 |
| | pilot | A,A 382 | `5467749/09c7931` **51** | B,B 768 |
| 3 wrong order | standard | A,A 1,022 | `5467749/09c7931` **299** (new eAPI, old domain) | B,B 2,279 |
| | pilot | B,B 391 | `c8cd594/b5490fc` **50** | A,A 760 |
| 4 flip, retry | standard | A,A 1,007 | `c8cd594/b5490fc` **301** | B,B 2,292 |
| | pilot | B,B 386 | `5467749/09c7931` **50** | A,A 765 |
| 5 rollback, retry | standard | B,B 1,975 | `c8cd594/b5490fc` **300** | A,A 1,326 |
| | pilot | A,A 708 | `5467749/09c7931` **51** | B,B 441 |

(In every run the pair that should never occur was 0: for example `5467749/09c7931` for standard users in
Runs 1, 2, 4 and 5.) Run 6 alternated live between `(A,A)` (2,464 answers) and `5467749/09c7931` (1,137), and
the pilot between `(B,B)` (674) and `c8cd594/b5490fc` (527).

### Timeline (from `timeline.sh`, Run 4)

`t` is seconds after `flip.sh` started:

```
standard users
  t= -32..1    (34s)  c8cd594/09c7931=989
  t=   2..2    ( 1s)  c8cd594/09c7931=18  c8cd594/b5490fc=14   <- MIX
  t=   3..11   ( 9s)  c8cd594/b5490fc=270
  t=  12..12   ( 1s)  c8cd594/b5490fc=17  5467749/b5490fc=13   <- MIX
  t=  13..89   (77s)  5467749/b5490fc=2279
pilot users
  t= -32..6    (39s)  5467749/b5490fc=382
  t=   7..7    ( 1s)  5467749/b5490fc=4   5467749/09c7931=4    <- MIX
  t=   8..11   ( 4s)  5467749/09c7931=40
  t=  12..12   ( 1s)  5467749/09c7931=6   c8cd594/09c7931=5    <- MIX
  t=  13..88   (76s)  c8cd594/09c7931=760
```

Cut-overs are sharp: within one second of a Route change taking effect, the pair is 100% the new one. No
long tail of old-pod answers was seen, even though the gateway pools connections.

### Caveats

- **Every figure is a single run.** Runs 1 to 3 and 4 to 6 are the only repeats, and they differ by design.
- Load comes from one Mac and goes through the CRC VM and the router, so very high rates would measure the
  generator and the single gateway pod, not the design.
- The failures in Runs 1 and 3 are explained (see section 11) but the **cause of their appearing only
  sometimes is not known**, so "0 failures" on the retrying gateway is not proof that the retry fixed them.
- The router's reload behaviour is inferred from the timing of four runs. The configuration is not readable
  as the `developer` user.

---

## 11. Findings

1. **The commit must be set on the BuildConfig, not on `oc start-build`.** `--build-arg` is silently ignored
   for binary builds (`--from-dir`): the first three releases reported `unknown`. `release.sh` now patches
   `dockerStrategy.buildArgs` and checks `printenv GIT_COMMIT` inside the running pod.
2. **A separate project is needed.** Project 1 left `payment-api` Routes, a Deployment and a BuildConfig in
   `my-project`; a shared project would have rewritten them. The scripts guard the project.
3. **A stale image can be served under a rebuilt tag.** A node that cached `<service>:<commit>` would keep
   using it, so the Deployments use `imagePullPolicy: Always`.
4. **The router applies Route changes in ticks about 5 s apart** (+2 s, +7 s, +12 s after the flip starts in
   four runs). A service's two Routes therefore move up to 5 s apart, the live mix window is about 10 s, the
   pilot one about 5 s, and adjacent releases must be compatible for 10 to 15 s.
5. **With the swap model the safe order for live users is the unsafe order for pilot users**, and rollback
   must go caller first (see section 3).
6. **A rare race at router reloads.** Three failed requests in 16,812 on the original gateway, each in the
   first reload of a flip: the gateway reused a pooled keep-alive connection that the router closed at the
   reload (`PrematureCloseException: Connection prematurely closed BEFORE response` in the gateway log; the
   internal `GET /api/risk/score` returned 500 and `payment-api` turned that into a 503). It affected
   connections to Routes that were not even being changed.
7. **A gateway `Retry` was added** for connection errors only (`java.io.IOException`; GET and POST; 2 retries;
   not 5xx, not timeouts). It is verified locally (T10). On the new gateway about 20 reloads in Runs 4 to 6
   produced 0 failures **and 0 logged connection errors**, so the race did not fire again and the retry was
   never exercised in production traffic. The earlier failures' trigger is undetermined. The retry stays as
   defence in depth, with the claim limited to what T10 shows.
8. **One pod per release means any pod loss is an outage for that track.** That is a CRC capacity choice, not
   a recommendation.

---

## 12. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `ERROR: current project is 'X' but this demo runs in 'bluegreen'` | `oc project bluegreen` (create it once with `oc new-project bluegreen`) |
| `ERROR: uncommitted changes in services/<name>` | commit the change; the commit hash is the release id |
| `status.sh` shows `MISMATCH: pod reports unknown` | the image was built without the commit (an old build, or `oc start-build --build-arg` was used). Release again with `release.sh`; if the tag exists, `--rebuild` |
| HTML page `503 Application is not available` from `*.apps-crc.testing` | the Route points at a Service with no ready pods, or the host matches no Route. `oc get endpoints <service>`, `scripts/status.sh` |
| `ERROR: Service '...' has no ready pods` from `bind.sh` or `flip.sh` | by design. Fix the release (`oc get pods`, `oc logs`) before binding |
| `403 {"error":"missing or unknown Origin"}` | the client sent no `Origin`, or one that is not an MFE origin. Add `Origin:$LIVE_ORIGIN` |
| `403 {"error":"preview is for the pilot group only"}` | the preview origin needs `X-User-Group: pilot` |
| `404` on `/api/risk/score` through the public URL | by design: the domain API is internal. It is only reachable through the internal hop |
| A flip "did nothing" for a few seconds | normal: the router applies a change within about 2 s, and up to 5 s more for a second change |
| A pod stays `Pending` | not enough schedulable memory: `oc describe node`; retire old releases; keep the 3-pod project 1 app at 0 replicas |
| Build `Evicted` / node `DiskPressure` | the VM disk is nearly full: `crc stop; crc config set disk-size 50; crc start`; `crc status` shows disk usage |
| k6 exits with code 99 | a threshold failed. Expected in drill D1, otherwise look at the `FAIL` lines |
| zsh: `no matches found: ...?amount=...` | the `?` is a glob. Quote the URL or use HTTPie's `amount==250` |
| `curl`/`http` to the gateway returns 403 | the request has no `Origin`; every example in this guide adds one |

---

## 13. Cleanup

Remove one release: `scripts/retire.sh <service> <commit>` (it refuses while a Route points at it).

Remove **everything** this project created, in one command (Routes, Deployments, Services, ConfigMaps,
Secrets, BuildConfigs and the image streams all live in the project):

```bash
oc delete project bluegreen
```

Project 1 in `my-project` is untouched. To bring its 3-pod app back: `oc scale deployment/payment-api
--replicas=3` there (and expect it to compete for memory with this project).

---

## 14. Limits and what is next

- **Phase 9 and Phase 10 have not been run or built** (see section 1). This README should be updated with
  their results.
- A header is not security: `X-User-Group` and `Origin` are spoofable by any non-browser client. They stand
  in for a verified JWT claim and for the real browser's `Origin`.
- The eAPI and domain Routes are public in this demo; in a real cluster they would be internal only.
- The idempotency store is per pod memory. That is fine with one pod per release and would need Redis or a
  database with several replicas.
- The gateway is a **single** release: gateway changes use the hardened rolling update and are not piloted.
  Making it a release pair later would need a second public Route pair for the gateway (swapped like the
  others) plus two internal addresses, so that the eAPI's internal hop reaches the gateway release that matches
  the track.
- The internal hop is told apart from outside traffic by the `Host` header. That relies on the gateway
  Service having only the one public Route; a second Route to it would be treated as internal. A separate
  internal port and Service would remove that assumption.
- The demo is stateless; a shared database would need backward-compatible schema changes between adjacent
  releases.
