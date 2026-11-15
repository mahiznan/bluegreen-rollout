# Blue/Green releases with pilot routing on OpenShift (CRC): proposal v3.2

Status: **v3.2. Phases 0 to 4 are done locally; the cluster is untouched.** v3.1/v3.2 changes: the gateway
stays a **single release with one public URL**, and the track is decided from the **MFE host the browser
page came from** (the `Origin` header). Decisions are in section 15.

Builds on `payments-rollout` (zero-downtime rolling updates). That project made one deployment replace
itself without dropping requests. This one runs **two releases side by side** and moves users between
them by **rebinding Routes**, so no running service is touched.

v3 changes (from your feedback): objects are named **`{name}-{commit}`**, like Kubernetes' own default
naming, with **no v1/v2 anywhere**. Every response carries the **commit and pod** of each service that
handled it, and the identity is **piped domain -> eAPI -> response**, so k6 can count exactly how many
requests were served by old and new code at each hop.

## 1. Goal

1. A new release is deployed **alongside** the running one and bound only to the **preview address**, so only pilot users reach it.
2. Everyone else keeps using the **live address**, untouched.
3. When pilot testing passes, **flip**: rebind the live address to the new release. No Deployment, Pod, ConfigMap or Secret of a running service is modified.
4. If the pilot finds problems, do nothing to live traffic. Fix or discard the new release.
5. Prove it with k6: **zero failed requests through the flip**, and a count of requests per **(eAPI commit, domain commit)** pair, including mixed pairs such as old eAPI with new domain.

## 2. Concepts vs OpenShift objects

"Blue" and "green" exist only as concepts here. Nothing in OpenShift is named blue, green, v1 or v2.

| Concept | What it is in OpenShift |
|---|---|
| A **release** of a service | A set of objects named after the service **and the commit**: `Deployment`, `Service`, `ConfigMap`, `Secret` (for example `payment-api-3f9a2c1`) |
| Pod name | Kubernetes default: `{deployment}-{replicaset-hash}-{suffix}`, so `payment-api-3f9a2c1-7d9c8b6f5-x2x4q` |
| "live" | Whichever release Service the **live Route** points to |
| "preview" | Whichever release Service the **preview Route** points to |
| **The flip** | `oc patch route` changing which Service a Route points to |
| "What is in prod?" | `scripts/status.sh`: Route, Service, image, commit, in one table |

### 2.1 What "commit" means
- The release id of a service is **the last git commit that touched that service's directory**: `git log -1 --format=%h -- services/<name>`. Code, Dockerfile and config all live in that directory, so a config change is also a new commit and a new release.
- The build **refuses to run if that directory has uncommitted changes**. Otherwise one commit hash could stand for different content and the label would lie.
- The commit is baked into the image (`ARG GIT_COMMIT` -> `ENV GIT_COMMIT`), tagged as the image tag (`payment-api:3f9a2c1`, never `:latest`), and used in every object name. All of these come from the same script run, so they cannot disagree. `status.sh` also compares the commit a running pod reports against its Deployment name.
- Because you commit after each phase, **the hashes you see in k6 output are your own commits**.

## 3. Addresses (fixed for ever)

Per service there are two Routes, one live and one preview. **These are the pairs that get swapped.**

| Service | Live address | Preview address |
|---|---|---|
| `mfe` (what users browse) | `mfe.apps-crc.testing` | `mfe-preview.apps-crc.testing` |
| `payment-api` (eAPI) | `payment-api.apps-crc.testing` | `payment-api-preview.apps-crc.testing` |
| `risk-domain` (domain API) | `risk-domain.apps-crc.testing` | `risk-domain-preview.apps-crc.testing` |

Plus **one** public gateway address, `gateway.apps-crc.testing`, with no pair: the gateway is a single
release (decision 12). Both MFEs call this same URL. A gateway change is a normal hardened rolling update,
not piloted. If it ever needs piloting, the gateway can become a release pair with a Route swap plus two
internal addresses.

Users browse `mfe` (live) or `mfe-preview` (pilot). Those Routes point straight at the MFE releases and do
not go through the gateway.

**Invariant (swap model):** both Routes of a pair always exist and always point to two *different* releases
once a second release exists. Live serves the current release; preview serves either the **next** release
(before a flip) or the **previous** release (after a flip, kept as the rollback target). The flip is a
**swap** of the two Routes' targets, and rollback is the same swap again. Only on the very first deploy,
before any second release exists, do both Routes point to the same release. The gateway therefore never
needs "if there is no preview" logic. `status.sh` labels each Route's role: `live`, `preview (next)` or
`preview (previous, rollback)`.

## 4. Target flow (simplified)

```
 Browser, page loaded from mfe.crc... (live) or mfe-preview.crc... (pilot)
   |  the page's JavaScript calls the ONE gateway URL; the browser adds  Origin: <that MFE host>
   |  and the page sends X-User-Group (simulating the JWT claim)
   v
 gateway.crc...     Spring Cloud Gateway (one deployment, static config)
   edge rule: Origin (+ X-User-Group for the preview origin) -> TRACK (live|pilot)
   sets X-Track, strips any client-supplied X-Track
        |  /api/v1/payments/**   track=live  -> http://payment-api.crc...
        v                        track=pilot -> http://payment-api-preview.crc...
 payment-api-<commit>   (the eAPI; calls the gateway, forwards X-Track)
        |
        v  internal hop through the same gateway
 gateway:  track=live  -> risk-domain.crc...
           track=pilot -> risk-domain-preview.crc...
        v
 risk-domain-<commit>   (returns its own identity)
```

- JWT is replaced by the header `X-User-Group: pilot`. The service-to-service hop keeps its shape (eAPI -> gateway -> domain) without token signing.
- **The gateway config is static.** It knows only the two host patterns per service and the two MFE origins. It never learns commits, and it never needs reloading.
- **Why `Origin`:** both MFEs call the same gateway URL, so the `Host` header cannot tell live from pilot. What differs is where the page came from, and the browser reports that itself in `Origin` on every cross-origin call. Page JavaScript cannot change it. (A non-browser client such as k6 sets it itself, which is as spoofable as `X-User-Group`.)
- **CORS** is allowed at the gateway for exactly the two MFE origins. The preflight `OPTIONS` request carries no `X-User-Group`, so it is answered by the CORS filter before the track filter runs.

## 5. The rules that make it work

### 5.1 Decide once at the edge, then propagate
The edge computes a **track** from the request's `Origin` (+ group for the preview origin) and sets `X-Track`. The eAPI copies it onto its
call to the gateway, and the internal hop routes by `X-Track` only. The edge **strips any client-supplied
`X-Track`**, so a client cannot choose preview by sending it.

### 5.2 Edge decision table

| `Origin` (the MFE host) | Path | `X-User-Group` | Track | Result |
|---|---|---|---|---|
| `mfe` (live) | `/api/v1/payments/**` | any | `live` | live addresses |
| `mfe-preview` | `/api/v1/payments/**` | `pilot` | `pilot` | preview addresses |
| `mfe-preview` | `/api/v1/payments/**` | not `pilot` | | **403** |
| missing, or any other origin | any | | | **403** |
| any | any other path, for example `/api/risk` | | | **404**: the domain API is internal only |
| any other host (the internal hop) | `/api/risk/**` | | from the incoming `X-Track` | missing or invalid `X-Track` = **403** |
| preflight `OPTIONS` from an allowed origin | | | | answered by CORS, no track needed |

### 5.3 Services must not know their role
Promotion rebinds addresses, so **the same image and config run first as preview and later as live**.
Therefore no service, ConfigMap or the React app may embed "live" or "preview". The MFE calls the one
gateway URL (from its config) and never knows whether it is live or preview. The browser's `Origin` header
tells the gateway. In the browser demo the MFE sends `X-User-Group` taken from a "user group" selector,
standing in for the JWT claim.

## 6. Release lifecycle (route bindings only)

Releases are called **A (old)** and **B (new)**, which are just two commits.

```
S0  live -> A      preview -> A              first deploy only (no second release yet)
S1  deploy B objects (not routed yet), smoke test directly
S2  bind preview -> B                         pilot opens (live -> A, preview -> B)
S3a pilot OK     -> SWAP                      live -> B, preview -> A (A is the rollback target)
S3b pilot NOT OK -> leave live alone; deploy fixed C and bind preview -> C
                    (B's objects are deleted), or bind preview -> A (close pilot)
S4  rollback if needed: SWAP again            live -> A, preview -> B. Instant, A is still running.
S5  next release C goes to preview, so it REPLACES the release now on preview.
    From this point the old rollback target is gone (CRC cannot hold three releases per service).
S6  repeat from S1
```

**Swap order for one service:** patch live first, then preview. Between the two patches both hostnames point
to the new release, which is harmless. `bind.sh swap <service>` reads both Routes, checks both Services have
ready endpoints, patches live, then preview, and prints the result. `bind.sh` warns before step S5 destroys
the rollback target.

**After a swap, pilot users see the previous release**, because they use the preview address. The k6 pilot
scenario will therefore show the old commit after the flip. That is expected.

**Flip order across services:** flip the **callee first** (domain, then eAPI, then MFE). During the few
seconds between route changes a live request may meet old eAPI with new domain, so adjacent releases must
be backward compatible. This is a real-world rule and we will test it, including the **wrong order**
(eAPI first), where you should see the reverse mix: **new eAPI with old domain**.

### 6.1 Making the flip zero-downtime

A route flip changes **where new requests go**, not whether anything is running, so it should not cause
downtime *if these conditions hold*:

| # | Condition | Why |
|---|---|---|
| 1 | The new release is **fully ready** (all pods `1/1`) before the flip | Rebinding to a Service with no ready endpoints returns 503 immediately |
| 2 | It has **already served traffic** (the pilot phase) | A freshly started JVM is slow at first (cold JIT, empty connection pools). Pilot traffic warms it. |
| 3 | The old release **keeps running** after the flip | In-flight requests finish, pooled connections drain, and rollback is instant |
| 4 | Flip **callee first** with backward-compatible APIs | Routes do not change atomically across services |
| 5 | The gateway limits **keep-alive pool life** to the router | Otherwise some pooled connections keep serving the old release longer than expected |
| 6 | Retire the old release with the **hardened shutdown** from the previous project | Probes, graceful shutdown and `preStop` mean deleting it later drops nothing |

An optional smoother variant is a **weighted split** on the Route (`alternateBackends`, for example 90/10,
then 50/50, then 0/100). It is not needed for the demo.

## 7. Components

| Component | Tech | Release objects | Pods (CRC) |
|---|---|---|---|
| `gateway` | Spring Cloud Gateway Server (WebFlux), static routes. One public URL. **On Boot 4.0.9 with Spring Cloud 2025.1.4**, the latest GA release (Spring Cloud 2026.0 targets Boot 4.2 and is still a release candidate). | none, **single** | 1 |
| `payment-api` (the **eAPI**) | The existing payment app from `payments-rollout`, copied in. Calls the domain service through the gateway, forwards `X-Track`, adds identity to the response. | `payment-api-<commit>` | 1 per release |
| `risk-domain` (the **domain API**) | New, small Spring Boot 4 / Java 25 service. `GET /api/risk/score?amount=` returns the score and its own identity. Thresholds come from its ConfigMap. | `risk-domain-<commit>` | 1 per release |
| `mfe` | **React app, real Vite build**, built in the cluster (multi-stage: Node build, then nginx). Served by its own `mfe` / `mfe-preview` Routes, not through the gateway. | `mfe-<commit>` | 1 per release |

`payment-api` authorizing a payment calls `risk-domain` first (through the gateway), so there is a real
service-to-service hop that the pilot decision must survive.

"2 pods each" is read as **one pod per release, so two pods per service while a release is in flight**
(live release + preview release). It can be raised per service later (see section 12).

## 8. ConfigMaps and Secrets (per release, role-agnostic)

| Object | Name | Notes |
|---|---|---|
| ConfigMap | `<name>-<commit>-config`, `immutable: true` | Source lives in the service directory, so a config change is a new commit and a new release. Editing a plain ConfigMap does **not** restart pods, which is why releases never edit one. |
| Secret | `<name>-<commit>-secrets` | `scripts/render-secrets.sh` simulates the pipeline pulling from a vault. Never committed. |
| Fingerprint | in the identity block | First 8 hex of SHA-256 of the secret, proving which secret a release runs without revealing it |

**Rendering:** plain YAML templates (`*.tmpl.yaml`) filled by `envsubst` with `NAME`, `COMMIT` and `IMAGE`.
No Kustomize, so there is less to learn and the names are fully under our control.

**Release objects vs binding objects** are kept apart:
- `services/<name>/k8s/*.tmpl.yaml`: Deployment, Service, ConfigMap (owned by the release, applied by `scripts/release.sh`).
- `routes/`: the Routes. They are the binding layer and are changed only by `scripts/bind.sh`.
- Every release object carries labels `app=<name>` and `commit=<commit>`. A release Service selects **both**, so it only ever selects its own pods.

## 9. Identity in every response (what k6 counts)

Every service reports who it is: `{service, commit, pod}`. The domain's identity is **piped through**
the eAPI into the final response:

```json
POST /api/v1/payments/authorize  ->  200
{
  "authId": "auth_7c35c5a1785d20704e44",
  "status": "APPROVED",
  "orderId": "o-1",
  "replayed": false,
  "risk": { "score": 12, "decision": "APPROVE", "ruleSet": "default" },
  "served": {
    "eapi":   { "service": "payment-api", "commit": "3f9a2c1", "pod": "payment-api-3f9a2c1-7d9c8b6f5-x2x4q" },
    "domain": { "service": "risk-domain", "commit": "9b1d4e0", "pod": "risk-domain-9b1d4e0-5c4f7d8b9-k8m2p" }
  }
}
```

- `risk-domain` returns its own `served` block in its response, and `payment-api` copies it into its answer. So **one k6 response shows the eAPI commit and the domain commit side by side**.
- The MFE serves `/version.json` with its commit for the browser banner. It is not part of the API chain.
- **Idempotent replays** (`replayed: true`) are served from the eAPI's memory and do **not** call the domain again, so their `served.domain` is stale. k6 **counts only `replayed:false` responses** for the pair statistics. (`served.eapi` is always the pod that answered the current request.)
- **Where the commit comes from:** an image build argument, never from the running Deployment name, so a mislabeled object cannot fake it.

## 10. Phases (one at a time; you commit after each, and you run every cluster command)

| Phase | What is added | Verification |
|---|---|---|
| 0 | New repo, `.gitignore`, this plan | |
| 1 | **Capacity prep**: scale the old `payment-api` to 0, grow or prune the VM disk (target more than 12 GB free) | `crc status`, `oc describe node` shows room for 7 pods |
| 2 | `risk-domain`: new small service, `/api/risk/score`, identity block, settings from env (ConfigMap), secret fingerprint | local run on a spare port |
| 3 | `payment-api` (copied in): calls the gateway for a risk score, forwards `X-Track`, response gains `served.{eapi,domain}` | local run against a local `risk-domain`, both commits visible |
| 4 | `gateway`: edge rule from `Origin`, CORS, static routes, internal hop, keep-alive limits | local run with two releases of each service behind it (including a CORS preflight), plus an in-cluster DNS check |
| 5 | `release.sh` (clean-tree check, build, tag by commit, render, apply), `bind.sh` (including `swap`), `status.sh`, Routes (`gateway` -> gateway Service; `mfe`, `payment-api`, `risk-domain` pairs -> release A) | `status.sh` shows the binding table, `http` shows commit A at both hops |
| 6 | **Release B to pilot**: a real commit in each service, deploy B, bind preview -> B | The matrix in 5.2 behaves as specified, live users still see A |
| 7 | k6 with both groups and the pair counter, baseline | 0 failures, standard users (A,A), pilot users (B,B) |
| 8 | **The flip under load** (domain, eAPI, MFE), then **rollback**, then the **wrong-order flip** | 0 failures, pairs (A,A) -> (A,B) -> (B,B), and in the wrong order (B,A) appears. Flip time measured. |
| 9 | Failure drills: pilot bug (do nothing / redeploy), broken release (readiness fails), retire the old release | Live traffic unaffected in every drill |
| 10 | React MFE, real Vite build in the cluster (calls the one gateway URL, user-group selector, commit banner) | Browser shows the commit under each host, and the MFE flips with the rest |
| 11 | README with the real observed results | |

## 11. k6 plan

- Two scenarios in parallel, both to `gateway.apps-crc.testing`: **standard users** (`Origin: http://mfe.apps-crc.testing`) at about 30 rps and **pilot users** (`Origin: http://mfe-preview.apps-crc.testing`, `X-User-Group: pilot`) at about 10 rps. The `Host` header selects the entry address on the CRC router.
- For every non-replayed response k6 reads `served.eapi.commit` and `served.domain.commit` and increments a counter tagged **`{group, eapi, domain}`**.
- You pass the commits you expect: `-e COMMITS=3f9a2c1,9b1d4e0`. The script builds a threshold for every `{group, eapi, domain}` combination from that list, so the **end-of-test summary prints a count for every pair**, for example:
  ```
  pairs{group:standard,eapi:A,domain:A}  ....  4,812
  pairs{group:standard,eapi:A,domain:B}  ....     37     <- old eAPI, new domain (callee flipped first)
  pairs{group:standard,eapi:B,domain:B}  ....  3,090
  pairs{group:standard,eapi:B,domain:A}  ....      0     <- must be 0 when flipping callee first
  ```
- **Timeline:** `scripts/timeline.sh` turns k6's CSV output (`--out csv=...`) into counts **per second per pair**, so you can see the exact second the flip took effect, and how long mixed pairs lasted.
- **Checks:**
  - 0 failed requests, and `checks == 1`.
  - A **pilot** chain must be commit-consistent, meaning eAPI and domain are the same release (B,B).
  - During the **live** flip a brief (A,B) mix is expected, so the live scenario is checked for zero failures and known commits, not identical commits at both hops.
- Same thresholds as before: `http_req_failed == 0`, `dropped_iterations == 0`. The flip is triggered 30 s into a 180 s run.

## 12. Capacity (assessed 2026-11-15)

| Resource | Measured | Meaning |
|---|---|---|
| Mac RAM | **16 GB**, 10 CPUs | CRC VM already has 10.9 GB, two thirds of it |
| Node memory *requests* | 9,470Mi of about 9,975Mi allocated (**94%**) | Only about **500Mi** can still be scheduled (about 790Mi after removing the old 3-pod `payment-api`) |
| VM memory actually free | about **2.8 GB available** | Real usage, not requests |
| VM disk | **7.0 GB free** (78% used), builds evict below **4.9 GB** | About 2 GB of headroom. This is the biggest risk. |

What this design needs at peak (release in flight), at 1 pod per release:

| | Pods | Memory requests | Real memory |
|---|---|---|---|
| gateway | 1 | about 96Mi | about 250 MB |
| payment-api (A + B) | 2 | about 192Mi | about 500 MB |
| risk-domain (A + B) | 2 | about 192Mi | about 450 MB |
| mfe (A + B, nginx) | 2 | about 32Mi | about 20 MB |
| **Total** | **7** | **about 510Mi** | **about 1.2 GB** |

- **Fits** once the old 3-pod `payment-api` is scaled to 0.
- **Two pods per release would not fit:** 14 pods is about 1,000Mi of requests and about 2.4 GB real, against about 790Mi and 2.8 GB. Builds (Maven, and a Node/Vite build) also need memory while the apps run.
- **Do not raise CRC memory much.** On a 16 GB Mac, going past about 12 GB leaves macOS, the IDE, a browser and k6 too little.
- **Old releases accumulate** (objects and image tags per commit). `scripts/retire.sh <name> <commit>` deletes a release's objects and image tag, and we keep only the live and the previous release, so the disk does not fill.
- **Disk first:** three new images, a Node build and every build's scratch space will push it to the 4.9 GB eviction line. Phase 1 grows it (`crc config set disk-size`), or prunes old payment-api builds and images if growing is not possible.

## 13. Risks and caveats
- **A header is not security.** `X-User-Group` is spoofable. It stands in for a verified JWT claim.
- **Route flips across services are not atomic.** Flip order (callee first) and backward-compatible APIs between adjacent releases are required.
- **The flip is applied by the router,** which reloads within a few seconds (the router limits how often it reloads, 5 s by default). New connections use the new binding. Requests already in flight finish on the old backend. **Pooled keep-alive connections** (the gateway keeps connections open to the router) may keep serving the old release for a while after the flip, so we limit their idle time and life in the gateway and **measure the real switch-over time under load**, and do not assume it.
- **eAPI and domain Routes are public in this demo.** In a real cluster they would be internal-only.
- **Preview health:** if B has no ready pods, pilot users see errors while live users are unaffected.
- **Commit identity needs a clean tree.** `release.sh` refuses a dirty directory, so each phase's change must be committed before it can be released.
- **Data:** this demo is stateless. A shared database needs backward-compatible schema changes, which is out of scope.
- **Both releases run during a rollout,** so memory use is higher than a rolling update.

## 14. Tooling checked on this machine
`envsubst` (Homebrew), `oc kustomize` (not used), Node 26, `k6` 2.3, `oc` 4.17, JDK 25 via sdkman, and `git log -1 --format=%h -- <dir>` all work.

## 15. Decisions (resolved)

| # | Decision |
|---|---|
| 1 | eAPI = the **existing payment app** (copied in). Domain = new small **`risk-domain`**. Chain: MFE -> gateway -> payment-api -> gateway -> risk-domain. |
| 2 | MFE = **real Vite build**, blue/green like the others. |
| 3 | Non-pilot on the preview address: **403**. |
| 4 | Capacity: **1 pod per release**, memory not raised, disk grown or pruned in Phase 1. |
| 5 | Naming: **`{name}-{commit}`**, pods `{name}-{commit}-{hash}-{suffix}`, no v1/v2. |
| 6 | Identity (`commit` and `pod`) in every response, **piped domain -> eAPI -> response**, counted per pair by k6. |
| 7 | Routes are the only blue/green mechanism. The gateway config is static. |
| 8 | Spring Cloud Gateway Server (WebFlux). The Spring Cloud release that supports Boot 4 and the exact starter names are **confirmed at build time**. |
| 9 | `X-User-Group: pilot` is the pilot signal. No JWT. |
| 10 | Secrets are simulated by a script, never committed. Plain `envsubst` templates, immutable ConfigMaps named by commit. |
| 11 | New dedicated repo `bluegreen-rollout`, phase by phase, you commit. I write files and give commands, you run everything that changes the cluster. |
| 12 | **Single gateway**: one release serves both tracks. Gateway changes use the hardened rolling update and are not piloted. |
| 13 | **One public gateway URL.** The track is decided from the browser's `Origin` header (the MFE host that served the page), with CORS allowed at the gateway for the two MFE origins. Users browse `mfe` / `mfe-preview`, which are the swapped Routes. The gateway does not serve the MFE. |
| 14 | **Own OpenShift project `bluegreen`**, not `my-project`. Project 1 left Routes, a Deployment and a BuildConfig named `payment-api` there, which would collide with this project's Routes. The scripts refuse to run in any other project, and the whole demo can be removed with `oc delete project bluegreen`. Route hostnames become `<route>-bluegreen.apps-crc.testing`. |
