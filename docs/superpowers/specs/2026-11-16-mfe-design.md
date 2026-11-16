# Phase 10: the Vite MFE (design)

Status: approved in conversation on 2026-11-16, not yet implemented.

## Goal

Replace "k6 and HTTPie pretending to be a browser" with a real page, so that the `Origin` header, the CORS
preflight, the pilot group and the flip are exercised by an actual browser. The MFE is a third service in the
swap model: one release per git commit, a live Route and a preview Route, flipped with the same scripts.

## Decisions

| Topic | Decision |
|---|---|
| Stack | React + Vite, one screen, no router, no state library |
| Serving | multi-stage image: Node stage runs `vite build`, `nginxinc/nginx-unprivileged` serves `dist/` (not the dev server, not Spring Boot) |
| Gateway URL | **baked in at build time** as `VITE_GATEWAY_URL` (like the real system's build-time ConfigMaps), so a URL change means a new build. The id is the commit, but the URL comes from the gateway Route at build time: if the gateway host ever changes, rebuild with `release.sh --rebuild mfe` (an existing `mfe:<commit>` image is otherwise reused with the old URL) |
| Build place | inside OpenShift, like the other services (the Maven builds already prove the build pod has network access) |
| Pods | 1 per release, small requests (CRC node memory is about 92% allocated) |
| Release id | last commit touching `services/mfe` (unchanged rule), passed as `GIT_COMMIT` and `VITE_COMMIT` |

## The page

* Banner: the MFE's own commit (`VITE_COMMIT`), the gateway URL it was built with, and a `RELEASE_NOTE` text
  from `src/release-note.js`. A second release changes that one line, so a flip is visible by eye and the
  release stays fully described by its commit (no build value outside git, except the gateway URL).
* Form: order id, amount, currency, fake card token; "Authorize" sends
  `POST <gateway>/api/v1/payments/authorize` with a new `Idempotency-Key` each press.
* Group selector (`pilot` / `standard`): sets `X-User-Group` (stands in for the JWT claim).
* Result panel: status, risk decision, the identity block (`served.eapi`, `served.domain`: commit and pod) and
  readable errors (403 body, 503, network/CORS failure).
* The browser sets `Origin` itself (the MFE host); the page never sets it.

## Release shape

```
services/mfe/
  Dockerfile              node build stage -> nginx-unprivileged; ARG GIT_COMMIT, VITE_GATEWAY_URL
  nginx.conf              static files, SPA fallback, listens on 8080, /healthz
  package.json, vite.config.js, index.html, src/
  k8s/deployment.tmpl.yaml, service.tmpl.yaml     (same pattern as the other services; no ConfigMap, no Secret)
```

Script changes (the only changes outside `services/mfe`):

* `release.sh`: the BuildConfig `buildArgs` list becomes per-service. For `mfe` it carries `GIT_COMMIT`,
  `VITE_COMMIT` and `VITE_GATEWAY_URL` (from `route_host gateway`). Other services keep only `GIT_COMMIT`. The in-pod check `printenv GIT_COMMIT`
  still applies (the nginx image sets `ENV GIT_COMMIT`).
* `release.sh`: the ConfigMap and Secret steps are skipped for a service with no such templates.
* `bind.sh init mfe <commit>`: creates `mfe` and `mfe-preview` Routes (`route.tmpl.yaml` is already generic).
  `swap`, `preview`, `status.sh`, `flip.sh` and `retire.sh` should work unchanged; to be verified.
* `flip.sh` order: callee first, so `risk-domain payment-api mfe` for a promotion, `mfe payment-api risk-domain`
  for a rollback (the page is the outermost caller).

## Tests (run by the user in a browser, results added to README Part D)

| # | Test | Pass condition |
|---|---|---|
| M1 | `release.sh mfe`, `bind.sh init mfe <commit>` | `status.sh` has an `mfe` row, both hosts serve the page |
| M2 | open both hosts | each page shows its commit and the gateway URL |
| M3 | press Authorize | DevTools shows `OPTIONS` 200 then `POST` 200, `Origin` = the MFE host, no CORS error |
| M4 | preview host: `pilot` vs `standard` | pilot gets an answer; standard shows the readable 403 |
| M5 | second MFE release, flip under k6 load | live host serves the new page after the flip, k6 0 failures |
| M6 | a tab left open across the flip | it keeps working; a reload shows the new page |

## Out of scope

No login, no routing, no tests framework for the page, no server-side rendering, no runtime config.

## Risks

* The first image build downloads npm packages inside the build pod (`npm ci`); a lockfile is committed so the
  build is reproducible. If the build pod cannot reach the registry, fall back to building `dist/` locally and
  copying it into the nginx stage.
* `status.sh` and `retire.sh` were written for services with ConfigMaps and Secrets; `retire.sh` must tolerate
  their absence.
* Memory: one more pod per release. A third release (two MFE releases during M5) must still fit; check
  `oc describe node` before M5.
