import { dispatch } from "./github.js";
import { pollPages } from "./patchwork.js";

export async function remember(db, items, now) {
  if (!items.length) return;
  await db.batch(items.map(item => db.prepare(`
    INSERT INTO events (id, category, kind, object_id, event_date, first_seen)
    VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING
  `).bind(item.submission.patchwork_event_id, item.category, item.submission.kind,
    item.submission.id, item.date, now)));
}

export async function poll(env, request = fetch, now = new Date()) {
  const before = now.toISOString();
  const previous = await env.DB.prepare("SELECT value FROM state WHERE key = 'last_successful_poll'")
    .first("value");
  const since = new Date(previous ? Date.parse(previous) - 60_000 : now.getTime() - 600_000).toISOString();
  for await (const items of pollPages(env.PATCHWORK_API, env.PATCHWORK_PROJECT, since, before, request)) {
    await remember(env.DB, items, before);
  }
  // Delivery failures do not block ingestion. Overlapping polls cannot move time backwards.
  await env.DB.prepare(`
    INSERT INTO state (key, value) VALUES ('last_successful_poll', ?)
    ON CONFLICT(key) DO UPDATE SET value = MAX(state.value, excluded.value)
  `).bind(before).run();
}

export async function claim(db, id, token, now) {
  return db.prepare(`
    UPDATE events SET status = 'dispatching', claimed_at = ?, claim_token = ?, attempts = attempts + 1
    WHERE id = ? AND (status = 'pending' OR (status = 'dispatching' AND claimed_at < ?))
    RETURNING id AS patchwork_event_id, kind, object_id AS id
  `).bind(now.toISOString(), token, id, new Date(now.getTime() - 600_000).toISOString())
    .first();
}

export async function finish(db, id, token, error) {
  await db.prepare(`
    UPDATE events SET status = ?, dispatched_at = ?, last_error = ?, claim_token = NULL
    WHERE id = ? AND status = 'dispatching' AND claim_token = ?
  `).bind(error === null ? "dispatched" : "pending", error === null ? new Date().toISOString() : null,
    error, id, token).run();
}

export async function deliver(env, request = fetch) {
  // A bounded snapshot means a failing event is tried only once per invocation.
  const { results } = await env.DB.prepare(`
    SELECT id FROM events WHERE status = 'pending'
      OR (status = 'dispatching' AND claimed_at < ?) ORDER BY id LIMIT 20
  `).bind(new Date(Date.now() - 600_000).toISOString()).all();
  let failures = 0;
  for (const row of results) {
    const token = crypto.randomUUID();
    const submission = await claim(env.DB, row.id, token, new Date());
    if (!submission) continue;
    let error = null;
    try {
      await dispatch(env.GITHUB_REPOSITORY, env.GITHUB_EVENT_TYPE, env.GITHUB_TOKEN, submission, request);
    } catch (err) {
      error = String(err).slice(0, 1000);
      failures++;
    }
    await finish(env.DB, row.id, token, error);
    console.log(JSON.stringify({ event: row.id, status: error ? "pending" : "dispatched", error }));
  }
  if (failures) throw new Error(`${failures} dispatches failed; retained for retry`);
}

export async function tick(env, request = fetch) {
  try {
    await poll(env, request);
  } finally {
    // Previously queued events can still be delivered during a Patchwork outage.
    await deliver(env, request);
  }
}

export default {
  async scheduled(_controller, env) {
    await tick(env);
  },
};
