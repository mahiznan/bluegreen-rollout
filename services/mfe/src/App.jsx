import { useState } from 'react';
import { authorize, newIdempotencyKey, GROUPS } from './api.js';
import { config } from './config.js';
import { RELEASE_NOTE } from './release-note.js';

export default function App() {
  const [form, setForm] = useState({ orderId: 'o-1', amount: '250', currency: 'USD', cardToken: 'tok_demo' });
  const [group, setGroup] = useState('pilot');
  const [result, setResult] = useState(null);
  const [busy, setBusy] = useState(false);

  const set = (name) => (e) => setForm({ ...form, [name]: e.target.value });

  async function submit(e) {
    e.preventDefault();
    setBusy(true);
    try {
      setResult(await authorize({ gateway: config.gateway, group, key: newIdempotencyKey(), form }));
    } finally {
      setBusy(false);
    }
  }

  const served = result && result.kind === 'ok' && result.body ? result.body.served : null;

  return (
    <main>
      <header className="banner">
        <strong>mfe {config.commit}</strong>
        <span>page origin: {window.location.origin}</span>
        <span>gateway: {config.gateway}</span>
        <span>note: {RELEASE_NOTE}</span>
      </header>

      <form onSubmit={submit}>
        <label>Order id <input value={form.orderId} onChange={set('orderId')} /></label>
        <label>Amount <input value={form.amount} onChange={set('amount')} inputMode="decimal" /></label>
        <label>Currency <input value={form.currency} onChange={set('currency')} /></label>
        <label>Card token (fake) <input value={form.cardToken} onChange={set('cardToken')} /></label>
        <label>User group (stands in for the JWT claim)
          <select value={group} onChange={(e) => setGroup(e.target.value)}>
            {GROUPS.map((g) => <option key={g}>{g}</option>)}
          </select>
        </label>
        <button disabled={busy}>{busy ? 'Authorizing...' : 'Authorize'}</button>
      </form>

      {result && result.kind === 'ok' && (
        <section className="ok">
          <h2>{result.body?.status} (HTTP {result.status})</h2>
          <p>risk: {result.body?.risk?.decision} (score {result.body?.risk?.score})</p>
          {served && (
            <table>
              <tbody>
                <tr><th>eAPI</th><td>{served.eapi?.commit}</td><td>{served.eapi?.pod}</td></tr>
                <tr><th>domain</th><td>{served.domain?.commit}</td><td>{served.domain?.pod}</td></tr>
              </tbody>
            </table>
          )}
          <details><summary>raw response</summary><pre>{JSON.stringify(result.body, null, 2)}</pre></details>
        </section>
      )}
      {result && result.kind === 'http' && (
        <section className="error">
          <h2>HTTP {result.status}</h2>
          <pre>{result.body ? JSON.stringify(result.body, null, 2) : result.text}</pre>
        </section>
      )}
      {result && result.kind === 'network' && (
        <section className="error"><h2>No answer</h2><p>{result.message}</p></section>
      )}
    </main>
  );
}
