// Pure helpers for calling the gateway. No React, no import.meta.env, so node:test can run it.
export const GROUPS = ['pilot', 'standard'];

export function newIdempotencyKey(now = Date.now(), rand = Math.random) {
  return `mfe-${now}-${Math.floor(rand() * 1e6)}`;
}

export function buildRequest({ gateway, group, key, form }) {
  return {
    url: `${gateway.replace(/\/+$/, '')}/api/v1/payments/authorize`,
    options: {
      method: 'POST',
      // Only headers the gateway's CORS allows. The browser adds Origin itself; the page must not.
      headers: {
        'Content-Type': 'application/json',
        'Idempotency-Key': key,
        'X-User-Group': group,
      },
      body: JSON.stringify({
        orderId: form.orderId,
        amount: Number(form.amount),
        currency: form.currency,
        cardToken: form.cardToken,
      }),
    },
  };
}

export async function authorize(args, fetchImpl = fetch) {
  const { url, options } = buildRequest(args);
  let res;
  try {
    res = await fetchImpl(url, options);
  } catch (e) {
    return {
      kind: 'network',
      message: `network or CORS error (${e.message}). Open DevTools, Network and Console, to see which.`,
    };
  }
  let text;
  try {
    text = await res.text();
  } catch (e) {
    return {
      kind: 'network',
      message: `network or CORS error while reading the response (${e.message}). Open DevTools, Network and Console, to see which.`,
    };
  }
  let body = null;
  try { body = JSON.parse(text); } catch { /* not JSON, keep the text */ }
  if (res.ok) return { kind: 'ok', status: res.status, body };
  return { kind: 'http', status: res.status, body, text };
}
