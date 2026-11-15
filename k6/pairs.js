// Two groups of users hit the SAME gateway URL; only the browser's Origin differs. For every
// answered request we record WHICH eAPI commit and WHICH domain commit served it, so the
// summary shows how many requests each release pair handled.
//
//   standard users: Origin = live MFE host                       (default 30 rps)
//   pilot users:    Origin = preview MFE host + X-User-Group: pilot   (default 10 rps)
//
// Usage (commits come from `scripts/status.sh`):
//   k6 run -e DURATION=60s \
//          -e EAPI=<eapi commit A>,<eapi commit B> -e DOMAIN=<domain commit A>,<domain commit B> \
//          -e EXPECT_STANDARD=<eapi A>,<domain A> -e EXPECT_PILOT=<eapi B>,<domain B> \
//          k6/pairs.js
//
//   EAPI / DOMAIN       every commit you expect to see. The summary prints a count for EVERY combination.
//   EXPECT_STANDARD /   optional. When set, each answer must be exactly that pair (use it for baselines,
//   EXPECT_PILOT        not while a flip is in progress, when a mix is expected).
//   Other env: BASE_URL, MFE_LIVE, MFE_PREVIEW, STD_RPS, PILOT_RPS, DURATION
//
// Replayed answers (replayed:true) come from the eAPI's memory and do not call the domain, so they are
// never counted as a pair. Every request here uses a fresh Idempotency-Key, so none should be replayed.
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL || 'http://gateway-bluegreen.apps-crc.testing';
const ORIGIN = {
  standard: __ENV.MFE_LIVE || 'http://mfe-bluegreen.apps-crc.testing',
  pilot: __ENV.MFE_PREVIEW || 'http://mfe-preview-bluegreen.apps-crc.testing',
};
const STD_RPS = parseInt(__ENV.STD_RPS || '30');
const PILOT_RPS = parseInt(__ENV.PILOT_RPS || '10');
const DURATION = __ENV.DURATION || '60s';

const list = (name) => (__ENV[name] || '').split(',').map((s) => s.trim()).filter(Boolean);
const EAPI = list('EAPI');
const DOMAIN = list('DOMAIN');
const EXPECT = { standard: list('EXPECT_STANDARD'), pilot: list('EXPECT_PILOT') };

// One increment per answered, non-replayed request, tagged with who answered
const pairs = new Counter('pairs');
// An answer whose commit is not in EAPI / DOMAIN (a release you did not list)
const unexpectedPair = new Counter('unexpected_pair');
// Failed requests by HTTP status (status 0 = connection error or timeout)
const failedRequests = new Counter('failed_requests');

const thresholds = {
  http_req_failed: ['rate==0'],
  checks: ['rate==1'],
  http_req_duration: ['p(95)<2000'],
  dropped_iterations: ['count==0'],
  unexpected_pair: ['count==0'],
  'failed_requests{status:0}': ['count>=0'],
  'failed_requests{status:403}': ['count>=0'],
  'failed_requests{status:500}': ['count>=0'],
  'failed_requests{status:502}': ['count>=0'],
  'failed_requests{status:503}': ['count>=0'],
};
// These "always true" thresholds exist only to make k6 print a line for every combination.
for (const group of ['standard', 'pilot']) {
  for (const e of EAPI) {
    for (const d of DOMAIN) {
      thresholds[`pairs{group:${group},eapi:${e},domain:${d}}`] = ['count>=0'];
    }
  }
}

export const options = {
  scenarios: {
    standard: {
      executor: 'constant-arrival-rate',
      exec: 'standard',
      rate: STD_RPS,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: 60,
      maxVUs: 300,
    },
    pilot: {
      executor: 'constant-arrival-rate',
      exec: 'pilot',
      rate: PILOT_RPS,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: 30,
      maxVUs: 150,
    },
  },
  thresholds,
};

// A mix of amounts so the two releases give visibly different decisions:
// risk score = amount / 20. Release A: review at 60, decline at 90. Release B: 40 and 80.
const AMOUNTS = [49.9, 250, 1000, 1700];
const VALID_STATUS = ['APPROVED', 'PENDING_REVIEW', 'DECLINED'];

function authorize(group, key, orderId, amount) {
  const headers = {
    'Content-Type': 'application/json',
    'Idempotency-Key': key,
    Origin: ORIGIN[group],
  };
  if (group === 'pilot') {
    headers['X-User-Group'] = 'pilot';
  }
  const body = JSON.stringify({ orderId, amount, currency: 'USD', cardToken: 'tok_load_test' });
  return http.post(`${BASE_URL}/api/v1/payments/authorize`, body, {
    headers,
    timeout: '10s',
    tags: { group },
  });
}

function parse(res) {
  try {
    return res.json();
  } catch (e) {
    return null;
  }
}

function run(group) {
  const key = `k6-${group}-${__VU}-${__ITER}-${Date.now()}`;
  const amount = AMOUNTS[__ITER % AMOUNTS.length];
  const res = authorize(group, key, `order-${__VU}-${__ITER}`, amount);

  const ok = res.status === 200;
  if (!ok) {
    failedRequests.add(1, { status: String(res.status), group });
    // Same shape as project 1, so the same grep/awk pipelines work
    console.error(`${new Date().toISOString()} FAIL ${group} status=${res.status} error=${res.error || ''}`);
  }
  const data = ok ? parse(res) : null;
  const eapi = data && data.served && data.served.eapi ? data.served.eapi.commit : null;
  const domain = data && data.served && data.served.domain ? data.served.domain.commit : null;

  check(res, {
    'status is 200': (r) => r.status === 200,
    'status is a valid outcome': () => data !== null && VALID_STATUS.includes(data.status),
    'both commits are reported': () => eapi !== null && domain !== null,
    'expected release pair': () => EXPECT[group].length !== 2 || (eapi === EXPECT[group][0] && domain === EXPECT[group][1]),
  });

  if (data !== null && eapi !== null && domain !== null && data.replayed === false) {
    pairs.add(1, { group, eapi, domain });
    if ((EAPI.length && !EAPI.includes(eapi)) || (DOMAIN.length && !DOMAIN.includes(domain))) {
      unexpectedPair.add(1, { group, eapi, domain });
      console.error(`${new Date().toISOString()} UNEXPECTED ${group} eapi=${eapi} domain=${domain}`);
    }
  }
}

export function standard() { run('standard'); }
export function pilot() { run('pilot'); }

// Runs once before the load: shows which pair each group gets right now, so you can see the commits
// to pass in EAPI / DOMAIN, and fails fast if an Origin is wrong.
export function setup() {
  const found = {};
  for (const group of ['standard', 'pilot']) {
    const res = authorize(group, `k6-setup-${group}-${Date.now()}`, 'setup', 250);
    const data = parse(res);
    if (res.status !== 200 || !data || !data.served) {
      throw new Error(`setup: ${group} request returned ${res.status} ${res.body}. Check BASE_URL and the Origins.`);
    }
    found[group] = `${data.served.eapi.commit},${data.served.domain.commit}`;
  }
  console.log(`setup: standard users get eapi,domain = ${found.standard}`);
  console.log(`setup: pilot users get    eapi,domain = ${found.pilot}`);
  if (!EAPI.length || !DOMAIN.length) {
    console.warn('setup: EAPI and DOMAIN are not set, so there will be no per-pair lines. Pass -e EAPI=... -e DOMAIN=...');
  }
}
