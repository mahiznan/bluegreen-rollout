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

## At a glance

### The architecture

```
 USER                       EDGE                         ROUTES (OpenShift router)            RELEASES (one set of objects per git commit)
 ----                       ----                         -------------------------            --------------------------------------------

 browser on the LIVE MFE    +-------------------+
   Origin: mfe-...          |     gateway       |   live    payment-api  --+--> Service payment-api-<A> --> Deployment/Pod  (eAPI, release A)
   (standard users) ------->|                   |-------->  (Route)        |
                            |  ONE public URL   |
 browser on the PREVIEW MFE |                   |   preview payment-api-  --+--> Service payment-api-<B> --> Deployment/Pod  (eAPI, release B)
   Origin: mfe-preview-...  |  decides TRACK    |-------->  preview (Route)
   X-User-Group: pilot ---->|  from Origin      |
   (pilot users)            |  stamps X-Track   |   403 for a non-pilot user on the preview origin
                            |  CORS, retry      |   404 for any non-public path (the domain API is internal)
                            +---------+---------+
                                      ^
                                      |  internal hop (cluster Service "gateway:8080"), X-Track forwarded
                            payment-api (eAPI) calls the gateway for a risk score
                                      |
                                      v
                            +-------------------+   live    risk-domain   --+--> Service risk-domain-<A> --> Pod  (domain API, release A)
                            |     gateway       |-------->  (Route)
                            |  (same pod)       |   preview risk-domain-  --+--> Service risk-domain-<B> --> Pod  (domain API, release B)
                            +-------------------+-------->  preview (Route)

 Every response carries   served.eapi {service, commit, pod, secretFingerprint}
                          served.domain {service, commit, pod, secretFingerprint}     <- k6 counts the (eapi, domain) PAIR
```

Four things to hold on to:

1. **Release = git commit.** `payment-api-c8cd594` is one set of objects; the commit is baked into the image
   and each pod reports it, so the running pod, not the name, is the truth.
2. **Blue and green are not objects.** Only the two Routes per service carry a role: **live** and **preview**.
3. **The pilot is decided at the edge**, once, from the `Origin` header (the MFE host) plus a simulated group,
   and carried through the call chain in `X-Track`, so one user stays on one release at both hops.
4. **The flip is a Route change only.** No running Deployment, Pod, ConfigMap or Secret is touched.

### The release lifecycle

```
 S1  deploy B (objects only)         live -> A      preview -> (A or nothing)     nobody can reach B yet
 S2  bind preview -> B               live -> A      preview -> B                  PILOT OPENS
        |
        +--- pilot happy ---> S3  SWAP            live -> B      preview -> A      B is live, A kept for rollback
        |                         |
        |                         +--- problem ---> S4  SWAP back  live -> A  preview -> B     instant rollback
        |
        +--- pilot unhappy --> do nothing to live; then either
                                 - close the pilot    (preview -> A)               drill D2
                                 - fix forward        (deploy C, preview -> C)     drill D3
        |
 S5  retire the release nobody points at   (image tags deleted: it cannot be rebuilt)         drill D5
```

### The swap, and the order that keeps users safe

```
 PROMOTE (callee first)                            ROLL BACK (caller first)
   1. risk-domain   live <-> preview                 1. payment-api   live <-> preview
   2. payment-api   live <-> preview                 2. risk-domain   live <-> preview
   live users see  (old eAPI, new domain)  safe      live users see  (old eAPI, new domain)  safe
   pilot users see (new eAPI, old domain)  UNSAFE    pilot users see (new eAPI, old domain)  UNSAFE
        for ~4 to 5 s, testers only                       for ~4 to 5 s, testers only
```

The router applies Route changes in ticks about 5 s apart (+2 s, +7 s, +12 s after the start), so adjacent
releases must be backward compatible for 10 to 15 s.

### What has been proven

| Claim | Evidence | Section |
|---|---|---|
| Live users see 0 failed requests while a release is flipped, rolled back, or retired | k6 runs: 0 failures in 4 of the 6 phase-8 runs (the other two had 2 and 1) and in drills D2 to D5. D1 had 447 pilot-only 503s, provoked on purpose | [10](#10-measured-results) |
| The pair that answers matches the order of the flip, to the request | `(A,A)` → `(A,B)` mix → `(B,B)` counted per second | [9, Part B](#part-b-load-tests-with-k6) |
| A broken pilot release cannot hurt live users | D1 (pods removed: pilot 503, live untouched) and D4 (crashing release: never receives traffic, `bind.sh` refuses it) | [9, Part C](#part-c-failure-drills-phase-9-all-five-verified) |
| Closing the pilot, fixing forward and retiring an old release are Route changes too | D2, D3, D5 | [9, Part C](#part-c-failure-drills-phase-9-all-five-verified) |
| A real browser works against the gateway (CORS, pilot selector), and the page itself can be flipped, with an open tab surviving | M1 to M6 | [9, Part D](#part-d-the-mfe-phase-10-all-six-verified) |
| The wrong flip order is unsafe for live users | Run 3: 299 live answers in the unsafe pair | [10](#10-measured-results) |

### Where the cluster is now

One release per service, the same on live and preview: `payment-api` `5467749`, `risk-domain` `b5490fc`, `mfe`
`fd9934e`, and the single `gateway` `2dc8b0a`. Release A of the APIs was **retired in drill D5 and cannot be
rebuilt**, and the second MFE release was retired at the end of M6. The test commands in section 9 use A and B
as example names; to run them again from this state, create new releases first (see
[Starting a new cycle](#starting-a-new-cycle)).

---

## Contents

0. [At a glance](#at-a-glance): architecture, lifecycle, what is proven
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
| 9 | Failure drills D1 to D5 (pilot bug, close the pilot, fix forward, broken release, retire) | Done, run on the cluster, results in `results/d1` to `d5` |
| 10 | React MFE (Vite build, nginx image), released, bound and flipped | Done, run on the cluster and in a browser (`results/m1-status.txt`, `results/m5.txt`) |
| 11 | This README with the results of all phases | Done |

Every test in section 9 is marked **Verified** (it was run and the evidence is named, or the operator confirmed what a browser showed).
All of T1 to T11, D1 to D5 and M1 to M6 have been run. The browser observations of M2 to M6 were made and confirmed by the operator and are not saved as files; the files that exist are named in each test.

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
| `mfe` (what users browse) | `mfe-bluegreen.apps-crc.testing` | `mfe-preview-bluegreen.apps-crc.testing` |
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
| `mfe` | React 19 + Vite 6, served by nginx-unprivileged | the page users browse; the commit and the gateway URL are baked in at build time | 1 per release |

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
  mfe/                          the page: React + Vite, Dockerfile (node build, nginx), nginx.conf, k8s templates (no ConfigMap, no Secret)
    src/api.js, api.test.js              the pure API module and its 9+1 node:test tests (`npm test`)
    src/release-note.js                  one line to edit to make a release look different
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
| `release.sh` | `scripts/release.sh [--render-only] [--rebuild] [-y] <service>` | Refuses a dirty tree. Builds the image in the cluster tagged with the commit, creates the ConfigMap (if the service has one), Secret (if any), Service and Deployment named `<service>-<commit>`, waits for the rollout, and then **checks that the running pod reports that commit**. Binds no Route. `--render-only` writes the YAML to `.rendered/` and validates it client-side without changing the cluster; `--rebuild` rebuilds an image whose tag already exists. For `mfe` the BuildConfig also gets `VITE_GATEWAY_URL` (from the gateway Route), so the gateway Route must exist; if the gateway host ever changes, use `--rebuild` or the old URL stays baked in |
| `bind.sh` | `init <service> <commit>` / `preview <service> <commit>` / `swap <service>` / `gateway` (add `-y` to skip the question) | The **only** script that touches Routes. Every command first checks the target Service has ready pods. `preview` warns that the release currently on preview becomes unreachable |
| `flip.sh` | `scripts/flip.sh [-y] [--dry-run] [--gap SECONDS] <service> [<service> ...]` | Swaps services in the order given. **Checks every service before the first swap**, so a problem never leaves a half-done flip. Prints start and finish epochs. `--dry-run` only checks |
| `status.sh` | `scripts/status.sh` | The table in 6.3, with rows for `mfe`, `payment-api`, `risk-domain` and `gateway`. Read-only |
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
export A_EAPI=c8cd594 A_DOM=09c7931        # release A: live (retired by drill D5, see "Starting a new cycle")
export B_EAPI=5467749 B_DOM=b5490fc        # release B: preview (live and preview after D5)

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

Test order used for the real runs: **T1 to T11 first**, then the drills **D1, D2, D4, D3, D5**. D5 is
destructive (it retires release A for good), so it goes **last**. After D5 the commands below need a new
release first: see [Starting a new cycle](#starting-a-new-cycle).

**The state moves.** The load tests start from the standard state **live = A, preview = B**. T7 promotes B
(live = B), T8 rolls back (live = A), and T9 promotes again (live = B), so run them in that order, or use
`scripts/status.sh` to see where you are and start each from the state it names.

Status legend: **Verified** = run, evidence named. Where a result was observed in a browser and not saved, the test says so.

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
and `max-age: 3600`. The second returns `403` with no CORS headers. This is the closest thing to a browser without
one; the real browser is tested in Part D (M3).

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

### Part C: failure drills (Phase 9, all five verified)

The drills ask one question each: **when something goes wrong, or when a release is closed, replaced or
retired, do live users notice?** Each ran under k6 load (30 rps standard + 10 rps pilot) with the output in
`results/dN.txt` (the CSVs are ignored by git). They were run **in the order D1, D2, D4, D3, D5**, because D5
consumes release A and D3 and D5 change what is on preview.

| Drill | What goes wrong or changes | Live users | Pilot users | Evidence |
|---|---|---|---|---|
| **D1** | the pilot release's domain loses all pods | 0 failures, only `(A,A)` | 447 `503` for about 45 s, then recovery | `results/d1.txt` |
| **D2** | the pilot is closed (preview back to A, caller first) | 0 failures, only `(A,A)` | 0 failures, safe mixed pair for ~10 s, then `(A,A)` | `results/d2.txt` |
| **D3** | release C replaces B on preview (fix forward), then B comes back | 0 failures, only `(A,A)` | 0 failures, domain `C` for 79 s then `B` again | `results/d3.txt` |
| **D4** | a release that crashes at startup | 0 failures, only `(A,A)` | 0 failures, only `(B,B)` | `results/d4.txt` |
| **D5** | B promoted, preview rebound, A retired | 0 failures, safe mixed pair ~8 s, then `(B,B)` | 0 failures, unsafe pair ~4 s during the flip | `results/d5.txt` |

#### How every drill was run (the two terminals)

Both terminals start with the same variables. The commits below are the ones of the real runs; replace them
with yours from `scripts/status.sh`.

```bash
cd /Users/rajeshkumarm/workspace/openshift/bluegreen-rollout
export A_EAPI=c8cd594 A_DOM=09c7931 B_EAPI=5467749 B_DOM=b5490fc
export GW=http://gateway-bluegreen.apps-crc.testing
export LIVE_ORIGIN=http://mfe-bluegreen.apps-crc.testing
export PREVIEW_ORIGIN=http://mfe-preview-bluegreen.apps-crc.testing
oc project bluegreen
git branch --show-current          # main (the drills that need a branch create and delete their own)
scripts/status.sh                  # starting state for D1, D2, D4: live = A, preview = B, every row READY 1/1
```

* **Terminal 1** runs k6 (the exact command is in each drill) and prints its summary at the end.
* **Terminal 2** does the thing the drill is about, about 30 s after k6 starts.
* After k6: `scripts/timeline.sh results/dN.csv <epoch>` and
  `grep ' FAIL ' results/dN.txt | awk '{print substr($1,18,8), $5, $6}' | sort | uniq -c`.

k6 exits with code 99 in D1 (a threshold fails on purpose). Never add `EXPECT_*` to k6 in these drills, because
mixes are expected.

#### D1. The pilot finds a bug: do nothing to live  (Verified, `results/d1.txt`)

The requirement: "if the pilot has issues, we don't do anything". Simulate a broken release B by removing the
pods of its domain; live must not notice.

```bash
# terminal 1 (150 s)
k6 run -e DURATION=150s -e EAPI=$A_EAPI,$B_EAPI -e DOMAIN=$A_DOM,$B_DOM \
  --out csv=results/d1.csv k6/pairs.js 2>&1 | tee results/d1.txt

# terminal 2, about 30 s after k6 starts
date +%s                                                   # t=0 for the timeline
oc scale deployment/risk-domain-$B_DOM --replicas=0
oc get pods -l app=risk-domain                             # no b5490fc pod
# wait about 60 s, then recover
oc scale deployment/risk-domain-$B_DOM --replicas=1
oc rollout status deployment/risk-domain-$B_DOM

# after k6
grep ' FAIL ' results/d1.txt | awk '{print substr($1,18,8), $5, $6}' | sort | uniq -c
scripts/timeline.sh results/d1.csv <epoch>
scripts/status.sh
```

Prediction: pilot users get `503` (the preview Route has no ready pods, the router returns 503, the gateway
passes it on). Standard users: 0 failures and only `(A,A)`. The gateway does **not** retry a 503, by design.

**Result (150 s):**

| Group | Iterations | Failures | Pairs |
|---|---|---|---|
| standard | 4,500 | **0** | `c8cd594/09c7931` = 4,500 |
| pilot | 1,501 | **447, all `503`** | `5467749/b5490fc` = 1,054 answered |

The pilot's 503s ran without a gap from `20:05:37` to `20:06:21` (about 45 s, 10 per second, 7 in the last
second), starting 1 s after the scale-down and ending when the new pod became ready (a JVM start). Standard
users never noticed. `timeline.sh` lists only answered requests, so the outage is not visible there; the
`FAIL` lines are the evidence. After recovery `status.sh` showed every row 1/1 again.

**What it shows:** the track isolation holds under failure: a dead preview release is a pilot problem only.

#### D2. Close the pilot (rebind preview to A)  (Verified, `results/d2.txt`)

Roll the preview track back to A, **caller first**. The 8 s pause only makes the middle step visible.

```bash
# terminal 1 (120 s)
k6 run -e DURATION=120s -e EAPI=$A_EAPI,$B_EAPI -e DOMAIN=$A_DOM,$B_DOM \
  --out csv=results/d2.csv k6/pairs.js 2>&1 | tee results/d2.txt

# terminal 2, about 30 s after k6 starts
START=$(date +%s); echo "START=$START"
scripts/bind.sh -y preview payment-api $A_EAPI
sleep 8
scripts/bind.sh -y preview risk-domain $A_DOM
scripts/status.sh

# after k6
scripts/timeline.sh results/d2.csv $START
grep ' FAIL ' results/d2.txt | awk '{print substr($1,18,8), $5, $6}' | sort | uniq -c
```

`bind.sh` warns each time that the release leaving preview becomes unreachable. That is expected.

**Result (120 s):**

| Group | Iterations | Failures | Pairs over time |
|---|---|---|---|
| standard | 3,601 | **0** | `c8cd594/09c7931` throughout |
| pilot | 1,201 | **0** | `(B,B)` to t=1; MIX t=2; `c8cd594/b5490fc` t=3..11 (89); MIX t=12; `(A,A)` from t=13 (787) |

The caller moved at t=0 and showed up at t=2 (a router tick); the domain moved at about t=9 and showed up at
t=12, so the safe mixed window (old eAPI, new domain) lasted about 10 s. The unsafe pair (new eAPI, old
domain) never appeared and `unexpected_pair` was 0. B keeps running, unbound, and can be reopened with one
`bind.sh preview` per service (domain first, then caller).

**What it shows:** closing a pilot is a preview-only Route change, and caller-first avoids the unsafe pair.

#### D3. Fix forward: release C replaces B on preview  (Verified, `results/d3.txt`)

The pilot finds a problem in B, so the fix ships as release C. C takes the preview slot and live is never
touched. This run puts B back afterwards and retires C, so the later drills still had their A/B pair.

```bash
# 1. build release C on a throwaway branch (no load running)
git checkout -b drill-release-c
sed -i '' 's/RISK_DECLINE_THRESHOLD: "80"/RISK_DECLINE_THRESHOLD: "70"/' services/risk-domain/k8s/configmap.tmpl.yaml
git diff services/risk-domain/k8s/configmap.tmpl.yaml          # 70 replaced 80
git commit services/risk-domain -m "DRILL: risk-domain release C"   # NOT "-am", see the note below
export C_DOM=$(git log -1 --format=%h -- services/risk-domain); echo "C_DOM=$C_DOM"
scripts/release.sh -y risk-domain
scripts/status.sh                    # C is ready but unbound

# 2. terminal 1 (150 s). C MUST be in the DOMAIN list; check: echo $C_DOM
k6 run -e DURATION=150s -e EAPI=$A_EAPI,$B_EAPI -e DOMAIN=$A_DOM,$B_DOM,$C_DOM \
  --out csv=results/d3.csv k6/pairs.js 2>&1 | tee results/d3.txt

# 3. terminal 2, about 30 s after k6 starts: C on preview; about 60 s later: B back
START=$(date +%s); echo "START=$START"
scripts/bind.sh -y preview risk-domain $C_DOM
scripts/bind.sh -y preview risk-domain $B_DOM

# 4. after k6: retire C, return to main
scripts/retire.sh -y risk-domain $C_DOM
git checkout main
git branch -D drill-release-c
scripts/timeline.sh results/d3.csv $START
```

**Result (150 s):** standard users 4,501 answers, all `c8cd594/09c7931`, **0 failures**. Pilot users: `(B,B)` to
t=1; MIX t=2..3; `5467749/<C>` for t=4..82 (785 answers); MIX t=83; `(B,B)` again. 0 failed requests in
6,003. The caller stayed on B throughout, so only the domain changed, as predicted.

**Two mistakes made while running it (both are now written out of the commands above):**

* `unexpected_pair` was 798: all 798 were `eapi=5467749 domain=<C>`, exactly the number of C answers
  (785 + 12 + 1), because C was missing from the `DOMAIN` list k6 was started with (probably `C_DOM` was unset
  in that terminal). It is a harness input error, not a system fault; the CSV and `timeline.sh` still show C.
* `git commit -am` also committed the edited `README.md` into the throwaway branch, which later blocked
  `git checkout main`. The command now commits only the service directory.

**What it shows:** a fix-forward release replaces the preview without any effect on live.

#### D4. A broken release never receives traffic  (Verified, `results/d4.txt`)

A release whose service cannot start. A non-numeric threshold crashes `risk-domain` at startup (checked
locally first: exit code 1, `TypeMismatchException: Failed to convert ... "abc"`). A throwaway branch keeps
`main` clean.

```bash
# terminal 1 (240 s: the image build takes minutes)
k6 run -e DURATION=240s -e EAPI=$A_EAPI,$B_EAPI -e DOMAIN=$A_DOM,$B_DOM \
  --out csv=results/d4.csv k6/pairs.js 2>&1 | tee results/d4.txt

# terminal 2
git checkout -b drill-broken-release
sed -i '' 's/RISK_REVIEW_THRESHOLD: "40"/RISK_REVIEW_THRESHOLD: "abc"/' services/risk-domain/k8s/configmap.tmpl.yaml
git diff services/risk-domain/k8s/configmap.tmpl.yaml
git commit services/risk-domain -m "DRILL: broken release (non-numeric threshold)"
BAD=$(git log -1 --format=%h -- services/risk-domain); echo "BAD=$BAD"
scripts/release.sh -y risk-domain      # builds and applies; the rollout never completes.
                                       # press Ctrl+C once the pod is crash-looping
oc get pods -l app=risk-domain,commit=$BAD                                  # Error / CrashLoopBackOff, 0/1
oc logs deploy/risk-domain-$BAD --previous | grep -E "TypeMismatch|NumberFormat|abc" | head -3
scripts/bind.sh preview risk-domain $BAD; echo "exit code: $?"             # must refuse
scripts/status.sh                                                           # live and preview untouched

# cleanup, after k6 has finished
scripts/retire.sh -y risk-domain $BAD
git checkout main && git branch -D drill-broken-release
```

Prediction: `release.sh` never completes its rollout step and so never reaches its commit verification;
`bind.sh preview` fails with `ERROR: Service 'risk-domain-<bad>' has no ready pods. Binding a Route to it
would make the router return 503.`; live and pilot traffic show 0 failures and unchanged pairs.

**Result:** k6 measured **0 failures in 9,604 requests** over 240 s, `unexpected_pair` 0, no `FAIL` lines: live and
pilot never noticed the broken release. The crash loop, the refusal by `bind.sh` and the cleanup were run and
**confirmed by the operator as behaving as predicted**; their terminal output was not saved, so those parts are
not backed by a file in `results/`.

**What it shows:** two independent guards. A crashing release has no ready pods, and `bind.sh` refuses to
point a Route at a Service without ready pods, so a broken release can be built but never exposed.

#### D5. Retire the old release after a flip, under load  (Verified, destructive, run last; `results/d5.txt`)

Promote B, put B on preview as well so that A is unbound, then retire A, all under load. **A's image tags are
deleted, so A cannot be recreated afterwards.** The cluster ends with one release per service.

```bash
# terminal 1 (240 s)
k6 run -e DURATION=240s -e EAPI=$A_EAPI,$B_EAPI -e DOMAIN=$A_DOM,$B_DOM \
  --out csv=results/d5.csv k6/pairs.js 2>&1 | tee results/d5.txt

# terminal 2, about 30 s after k6 starts, one step at a time
scripts/flip.sh -y --gap 5 risk-domain payment-api       # 1. live = B, preview = A. Note the START epoch it prints
sleep 30
scripts/status.sh                                        # 2. live = B, preview = A
scripts/bind.sh -y preview risk-domain $B_DOM            # 3. preview = B as well, domain first
scripts/bind.sh -y preview payment-api $B_EAPI
scripts/status.sh                                        #    A's rows read "unbound"
scripts/retire.sh -y payment-api $B_EAPI; echo "exit code: $?"   # 4. must REFUSE: B is bound
scripts/retire.sh -y payment-api $A_EAPI                 # 5. retire A
scripts/retire.sh -y risk-domain $A_DOM
oc get pods -l 'app in (payment-api,risk-domain)'
scripts/status.sh                                        #    one release per service

# after k6
scripts/timeline.sh results/d5.csv <START>
oc get is payment-api -o jsonpath='{.status.tags[*].tag}'; echo
oc get is risk-domain -o jsonpath='{.status.tags[*].tag}'; echo
```

Prediction: 0 failures through the whole sequence, live users `(B,B)` after the flip, step 4 refused with a
non-zero exit code, and A's pods terminating without errors (the hardened shutdown from project 1: probes,
graceful shutdown, `preStop`).

**Result (240 s, flip at t=0, preview rebound to B at about t=46):** 9,602 requests, **0 failures**,
`unexpected_pair` 0. After the retire the image streams hold only `5467749 latest` (`payment-api`) and
`b5490fc latest` (`risk-domain`), so A's images are gone.

| Group | Timeline |
|---|---|
| standard | `(A,A)` to t=0; MIX t=1..2; `c8cd594/b5490fc` t=3..10 (old caller, new domain: safe); MIX t=11..12; `(B,B)` from t=13 (5,873) |
| pilot | `(B,B)` to t=5; MIX t=6..7; **`5467749/09c7931` t=8..11 (new caller, old domain: the unsafe pair)**; MIX t=12; `(A,A)` t=13..45; step 3: MIX t=46; `c8cd594/b5490fc` t=47..50 (safe); MIX t=51; `(B,B)` from t=52 |

Standard users got the safe order and pilot users the unsafe one during the flip, exactly the swap behaviour in
section 11. The unsafe pair was answered with 200s only because the two releases are compatible. Step 3
(preview back to B, domain first) went through the safe pair only. Not in the saved output: the refusal
printed by step 4 and the pod-termination listing of step 5; the tag lists confirm the retire completed.

**What it shows:** retiring is the last, separate step. It is allowed only once nothing points at the
release, and it does not disturb traffic.

#### What the drills showed

1. **A failing pilot release is a pilot-only problem** (D1, D4): the track is chosen at the edge and each track
   has its own Routes, Services and pods, so nothing live depends on preview.
2. **Every release-state change is a Route change or an object delete, never a change to a running release**
   (D2, D3, D5), and none of them cost a live request.
3. **Order matters only for the pair of services** (D2, D5), and caller-first for the preview rollback kept the
   unsafe pair away. The pilot saw the unsafe pair once, during the swap in D5.
4. **The guards held**: `bind.sh` refuses a Service without ready pods (D4), `retire.sh` refuses a release a
   Route still points at (D5 step 4, and the earlier T1), and `release.sh` refuses a dirty service directory.
5. **Operator mistakes are the likely failures**, not the design: a release missing from the k6 list (D3), or
   `git commit -am` sweeping up unrelated files (D3). Both are noted in [Troubleshooting](#12-troubleshooting).

#### Starting a new cycle

After D5 there is one release per service and no A. To run T7 to T9 or the drills again, create a **new**
release of each service and use the current one as "A":

```bash
# 1. a change to each service, committed on main (commit ONLY the service directory)
git commit services/risk-domain -m "risk-domain: next release"      # after changing a file under it
git commit services/payment-api -m "payment-api: next release"      # same
# 2. build and deploy the new releases (nothing is routed to them yet)
scripts/release.sh risk-domain
scripts/release.sh payment-api
# 3. open the pilot on them: domain first, then the caller
scripts/bind.sh preview risk-domain  <new domain commit>
scripts/bind.sh preview payment-api  <new eapi commit>
scripts/status.sh              # live = the old B, preview = the new release
# 4. in each terminal, name them the way the tests do
export A_EAPI=5467749 A_DOM=b5490fc          # what is live now
export B_EAPI=<new eapi commit> B_DOM=<new domain commit>
```

The drills then work as written. D5 would retire the old live release again.

---

### Part D: the MFE (Phase 10, all six verified)

The MFE is a third service in the same release model: `mfe-<commit>` objects, a live Route `mfe` and a preview
Route `mfe-preview`, the same `release.sh`, `bind.sh`, `flip.sh` and `retire.sh`. The page calls the single
gateway; the **browser** sets the `Origin` header (the MFE host), which is how the gateway tells live from pilot.
It has no ConfigMap and no Secret: the commit and the gateway URL are baked into the bundle at build time.

**The page** shows a banner (`mfe <commit>`, `page origin`, `gateway`, `note`), a form (order id, amount,
currency, fake card token), a **user group** selector (`pilot` / `standard`, which sets `X-User-Group`), and a
result panel with the status, the risk decision, the eAPI and domain commits and pods, or a readable error (a
403 body, a 503, or a network/CORS message). Offline tests: `cd services/mfe && npm test` (10 tests, no framework
beyond `node:test`).

#### Release and bind the first MFE (M1, M2)

```bash
oc project bluegreen
scripts/release.sh --render-only mfe       # YAML valid, "no Secret for mfe", cluster unchanged
tests/scripts/mfe-release-render.sh        # offline render test: PASS (needs services/mfe committed)
scripts/release.sh -y mfe                  # build in OpenShift (npm ci + vite build), then the in-pod commit check
export M1=$(git log -1 --format=%h -- services/mfe)
scripts/bind.sh -y init mfe $M1            # both Routes -> mfe-<M1>
scripts/status.sh > results/m1-status.txt
```

#### Tests

| # | Test | How | Result |
|---|---|---|---|
| M1 | Release and bind the MFE | commands above | **Verified** (`results/m1-status.txt`): `mfe` row `live+prev` on `mfe-fd9934e`, READY 1/1, image tag and pod-reported commit both `fd9934e` |
| M2 | Commit banner | open `http://mfe-bluegreen.apps-crc.testing` and `http://mfe-preview-bluegreen.apps-crc.testing` | **Verified.** Both hosts return 200 and serve the same bundle, which contains `fd9934e` and `gateway-bluegreen.apps-crc.testing` (checked with `http`); the banner in a browser was confirmed by the operator |
| M3 | Real browser CORS | live host, group `standard`, Authorize, DevTools Network | **Verified by the operator**: a preflight `OPTIONS` 200 then the `POST` 200 with `Origin` = the MFE host, no CORS error. The browser caches the preflight for an hour (`max-age: 3600`), so only the first Authorize per origin shows the `OPTIONS` row |
| M4 | Pilot selector | preview host: group `pilot`, then `standard` | **Verified by the operator**: pilot gets a normal answer; `standard` shows the red panel `HTTP 403` with `preview is for the pilot group only`, readable because the gateway's 403 carries the CORS header |
| M5 | MFE flip under load | second MFE release (below), k6 running, `scripts/flip.sh -y mfe` | **Verified** (`results/m5.txt`): 3,602 iterations, **0 failures**, only `5467749/b5490fc` (2,701 standard, 901 pilot), `unexpected_pair` 0. The live host showed the second release after the flip (operator) |
| M6 | A tab open across the flip | a live tab left open and not reloaded | **Verified by the operator**: after the flip the old tab still authorized successfully (its `Origin` is still the live host), and after a reload it showed the new release |

**M5 and M6 in full.** A second release is made by changing one line, `src/release-note.js`, and committing
only the MFE directory (never `git commit -am`):

```bash
git commit services/mfe -m "mfe: second release (release note changed)"
export M1=fd9934e M2=$(git log -1 --format=%h -- services/mfe)       # two different ids
scripts/release.sh -y mfe                                           # second release, not routed yet
scripts/bind.sh -y preview mfe $M2                                  # the preview host now shows $M2
# M6: keep a tab on the live host open (it shows $M1); press Authorize once; do not reload
# terminal 1
k6 run -e DURATION=90s -e EAPI=$B_EAPI -e DOMAIN=$B_DOM --out csv=results/m5.csv k6/pairs.js 2>&1 | tee results/m5.txt
# terminal 2, about 30 s later
scripts/flip.sh -y mfe                                              # live = $M2, preview = $M1 (rollback target)
# new window on the live host: shows $M2. Old tab: Authorize still works; reload shows $M2
scripts/flip.sh -y mfe                                              # rollback: live = $M1 again
scripts/bind.sh -y preview mfe $M1                                  # preview = $M1 too, so $M2 is unbound
scripts/retire.sh -y mfe $M2
```

The real values were `M1=fd9934e` and `M2=e3a462a`. k6 does not use the MFE, so M5's k6 result shows only that
flipping the page does not disturb the API traffic. After the cleanup the MFE was back to one release,
`fd9934e`, on both Routes. When the whole stack is flipped, the MFE goes **last** on a promotion
(`flip.sh risk-domain payment-api mfe`) and **first** on a rollback (`flip.sh mfe payment-api risk-domain`),
because the page is the outermost caller.

**Not saved as files:** the browser observations of M2, M3, M4 and M6, and the status output after the flip.

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

### The MFE run (Phase 10)

| Run | File | Duration | Requests | Failed | Max latency | Notes |
|---|---|---|---|---|---|---|
| **M5** MFE flip under load | `m5.txt` | 90 s | 3,604 | **0** | 846 ms | 2,701 standard + 901 pilot, all `5467749/b5490fc`; `unexpected_pair` 0 |

### The drill runs (Phase 9)

Same load (30 rps standard + 10 rps pilot). `http_reqs` includes the two setup requests of k6.

| Drill | File | Duration | Requests | Failed | Max latency | Notes |
|---|---|---|---|---|---|---|
| **D1** pilot domain pods removed | `d1.txt` | 150 s | 6,003 | **447** | 854 ms | all 447 are pilot `503`, 0 on the standard path; 4,500 standard `(A,A)` |
| **D2** close the pilot | `d2.txt` | 120 s | 4,804 | **0** | 817 ms | safe mixed pair for ~10 s on the pilot |
| **D3** release C on preview | `d3.txt` | 150 s | 6,003 | **0** | 894 ms | `unexpected_pair` 798 = C was missing from the k6 list (harness error) |
| **D4** broken release | `d4.txt` | 240 s | 9,604 | **0** | 846 ms | the crashing release never received traffic |
| **D5** flip, rebind, retire A | `d5.txt` | 240 s | 9,602 | **0** | 846 ms | pilot saw the unsafe pair for ~4 s during the flip |

Across the five drills, **live users had 0 failed requests in about 27,000 requests**, even in D1, where the pilot
lost 447.

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
9. **The track isolation holds under failure (D1, D4).** A preview release with no pods, or one that cannot
   start, costs pilot users 503s at most; live users saw 0 failures. The gateway does not retry a 503, so the
   pilot outage lasted exactly as long as the pod was missing (about 45 s, a JVM start).
10. **Closing, replacing and retiring a release are all invisible to live users (D2, D3, D5).** The preview can
    be rebound to any release that has ready pods, at any time, and a retire is possible only for a release
    that no Route points at.
11. **The unsafe pair shows up for pilot users in every correct promotion** (D5: about 4 s of new eAPI + old
    domain), a direct consequence of the swap. It was harmless here because releases A and B are compatible;
    it would not be harmless for a breaking change, which is why adjacent releases must stay compatible.
12. **Retiring is irreversible.** `retire.sh` deletes the image tags, so a retired release cannot be rebuilt from
    the cluster. Rebuilding it from git (check out that commit, then run `release.sh`) is plausible but was
    not tried.
13. **The MFE needed no change to the release model.** `bind.sh`, `flip.sh`, `retire.sh` and `status.sh` worked for it
    unchanged; only `release.sh` learned a per-service build argument (the gateway URL) and a service without a
    ConfigMap. A tab left open across a flip keeps working because its `Origin` still names the live host, and the
    browser caches the CORS preflight for an hour.
14. **The operator is the weak point.** In D3 a release missing from the k6 list produced 798 false
    `unexpected_pair` counts, and `git commit -am` swept an unrelated README edit into the throwaway commit.
    Both are procedural: the commands in section 9 now name the list and commit only the service directory.

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
| k6 prints a large `unexpected_pair` count with a single `eapi=...` or `domain=...` | that release is not in your `-e EAPI=` / `-e DOMAIN=` lists (drill D3: `C_DOM` was unset). Check `echo $C_DOM`, restart k6 with the full list |
| `git checkout main` refuses: "local changes would be overwritten" | an earlier `git commit -am` committed unrelated files (for example `README.md`) on the throwaway branch. Copy the file aside, `git checkout -- <file>`, switch, copy it back. Use `git commit <service dir> -m ...` instead of `-am` |
| `retire.sh` refuses | a Route still points at that release. Bind preview (or flip) to another release first, then retire |
| `retire.sh` succeeded, now `release.sh` for that commit fails | the image tags were deleted. The release id is the last commit touching the directory, so rebuilding means checking out that commit first (not tried in this project) |
| During a promotion pilot users briefly get the new eAPI with the old domain | expected with the swap (see section 3): the pilot gets the opposite order from live users. Harmless for compatible releases |
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

- The drill figures are single runs. D4's crash-loop and `bind.sh` refusal output and D5's step 4 and pod
  termination output were observed by the operator but not saved.
- The cluster is now in a one-release state for every service (see [Starting a new cycle](#starting-a-new-cycle)); the `mfe` is on `fd9934e`. To repeat the drills, create new releases of the services as described there.
- The MFE tests M2 to M4 and M6 were observed in a browser by the operator and not recorded as files.
- The MFE bakes the gateway URL in at build time; if the gateway host changes, rebuild it (`release.sh --rebuild mfe`).
- A first `npm ci` in the cluster needs the npm registry and Docker Hub (`node:22-alpine`, `nginx-unprivileged`); this worked in CRC here, but rate limits would break a build.
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
