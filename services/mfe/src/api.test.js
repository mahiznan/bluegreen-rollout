import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildRequest, authorize, newIdempotencyKey, GROUPS } from './api.js';

const form = { orderId: 'o-1', amount: '250', currency: 'USD', cardToken: 'tok_x' };

test('GROUPS lists pilot and standard', () => {
  assert.deepEqual(GROUPS, ['pilot', 'standard']);
});

test('newIdempotencyKey is mfe-<now>-<int> and changes with the random part', () => {
  assert.equal(newIdempotencyKey(1000, () => 0.5), 'mfe-1000-500000');
  assert.notEqual(newIdempotencyKey(1000, () => 0.1), newIdempotencyKey(1000, () => 0.2));
});

test('buildRequest strips a trailing slash and targets the authorize path', () => {
  const { url } = buildRequest({ gateway: 'http://gw.test/', group: 'pilot', key: 'k1', form });
  assert.equal(url, 'http://gw.test/api/v1/payments/authorize');
});

test('buildRequest sends only the headers the gateway CORS allows, never Origin', () => {
  const { options } = buildRequest({ gateway: 'http://gw.test', group: 'pilot', key: 'k1', form });
  assert.equal(options.method, 'POST');
  assert.deepEqual(options.headers, {
    'Content-Type': 'application/json',
    'Idempotency-Key': 'k1',
    'X-User-Group': 'pilot',
  });
  assert.equal('Origin' in options.headers, false);
});

test('buildRequest sends amount as a number', () => {
  const { options } = buildRequest({ gateway: 'http://gw.test', group: 'standard', key: 'k', form });
  assert.deepEqual(JSON.parse(options.body), { orderId: 'o-1', amount: 250, currency: 'USD', cardToken: 'tok_x' });
});

const respond = (status, bodyText) => async () => ({
  ok: status >= 200 && status < 300,
  status,
  text: async () => bodyText,
});

test('authorize returns kind ok with the parsed body', async () => {
  const r = await authorize({ gateway: 'http://gw.test', group: 'pilot', key: 'k', form },
    respond(200, '{"status":"APPROVED"}'));
  assert.equal(r.kind, 'ok');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { status: 'APPROVED' });
});

test('authorize returns kind http for a 403 and keeps the gateway error body', async () => {
  const r = await authorize({ gateway: 'http://gw.test', group: 'standard', key: 'k', form },
    respond(403, '{"error":"preview is for the pilot group only"}'));
  assert.equal(r.kind, 'http');
  assert.equal(r.status, 403);
  assert.equal(r.body.error, 'preview is for the pilot group only');
});

test('authorize keeps the raw text when the body is not JSON', async () => {
  const r = await authorize({ gateway: 'http://gw.test', group: 'pilot', key: 'k', form },
    respond(503, '<html>Application is not available</html>'));
  assert.equal(r.kind, 'http');
  assert.equal(r.body, null);
  assert.match(r.text, /not available/);
});

test('authorize returns kind network when fetch throws (offline or blocked by CORS)', async () => {
  const r = await authorize({ gateway: 'http://gw.test', group: 'pilot', key: 'k', form },
    async () => { throw new TypeError('Failed to fetch'); });
  assert.equal(r.kind, 'network');
  assert.match(r.message, /CORS|network/i);
});

test('authorize returns kind network when reading the body fails mid-response', async () => {
  const r = await authorize({ gateway: 'http://gw.test', group: 'pilot', key: 'k', form },
    async () => ({ ok: true, status: 200, text: async () => { throw new TypeError('terminated'); } }));
  assert.equal(r.kind, 'network');
  assert.match(r.message, /network/i);
});
