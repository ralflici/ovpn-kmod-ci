import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { completion, pollPages } from "../src/patchwork.js";
import { dispatch } from "../src/github.js";
import { remember, poll, claim, finish, deliver, tick } from "../src/index.js";

// Exercise the actual SQL and migration with SQLite, exposing the D1 methods used.
function database() {
  const sql = new DatabaseSync(":memory:");
  sql.exec(readFileSync(new URL("../migrations/0001_events.sql", import.meta.url), "utf8"));
  return {
    sql,
    prepare(query) {
      const statement = sql.prepare(query);
      let params = [];
      return {
        bind(...values) { params = values; return this; },
        async first(column) {
          const row = statement.get(...params);
          return row ? (column ? row[column] : { ...row }) : null;
        },
        async all() { return { results: statement.all(...params).map(row => ({ ...row })) }; },
        async run() { return { meta: statement.run(...params) }; },
      };
    },
    async batch(statements) {
      sql.exec("BEGIN");
      try {
        const results = [];
        for (const statement of statements) results.push(await statement.run());
        sql.exec("COMMIT");
        return results;
      } catch (error) {
        sql.exec("ROLLBACK");
        throw error;
      }
    },
  };
}

const event = {
  id: 23472, category: "series-completed", project: { link_name: "ovpn" },
  date: "2026-09-16T08:38:03.226710", payload: { series: { id: 4064 } },
};
const item = completion(event, "ovpn");
const now = new Date("2026-09-16T09:00:00Z");
function environment(DB = database()) {
  return { DB, PATCHWORK_API: "https://patchwork.test/api/1.3", PATCHWORK_PROJECT: "ovpn",
    GITHUB_REPOSITORY: "example/ci", GITHUB_EVENT_TYPE: "ovpn-patchwork", GITHUB_TOKEN: "test-token" };
}
async function pages(...args) {
  const items = [];
  for await (const page of pollPages(...args)) items.push(...page);
  return items;
}

test("completion selects series and standalone patches, never series members", () => {
  assert.deepEqual(item.submission, { patchwork_event_id: 23472, kind: "series", id: 4064 });
  const patch = { ...event, category: "patch-completed", payload: { patch: { id: 42 }, series: null } };
  assert.equal(completion(patch, "ovpn").submission.kind, "patch");
  patch.payload.series = { id: 4064 };
  assert.equal(completion(patch, "ovpn"), null);
  delete patch.payload.series;
  assert.throws(() => completion(patch, "ovpn"), /Missing series/);
  assert.throws(() => completion(event, "another-project"), /project/);
  assert.throws(() => completion({ ...event, id: "23472" }, "ovpn"), /ID/);
});

test("pagination follows Link, reads the project stream and enforces its cap", async () => {
  let count = 0;
  const request = async url => {
    const parsed = new URL(url);
    if (++count === 1) {
      assert.equal(parsed.searchParams.has("category"), false);
      assert.equal(parsed.searchParams.get("before"), now.toISOString());
    }
    return Response.json([event], { headers: count === 1
      ? { Link: '<https://patchwork.test/api/1.3/events/?page=2>; rel="next"' } : {} });
  };
  const args = ["https://patchwork.test/api/1.3", "ovpn", "2026-09-16T08:00:00Z", now.toISOString()];
  assert.equal((await pages(...args, request)).length, 2);
  count = 0;
  await assert.rejects(pages(...args, request, 1), /pagination limit/);
  await assert.rejects(pages(...args, async () => Response.json([], {
    headers: { Link: '<https://other.test/events/>; rel="next"' },
  })), /Unexpected.*URL/);
});

test("failed later pages preserve the watermark and previously stored events", async () => {
  const env = environment();
  let count = 0;
  const request = async () => ++count === 1 ? Response.json([event], {
    headers: { Link: '<https://patchwork.test/api/1.3/events/?page=2>; rel="next"' },
  }) : new Response("unavailable", { status: 503 });
  await assert.rejects(poll(env, request, now), /503/);
  assert.equal(env.DB.sql.prepare("SELECT COUNT(*) n FROM events").get().n, 1);
  assert.equal(env.DB.sql.prepare("SELECT * FROM state").get(), undefined);
  await poll(env, async () => Response.json([event]), now);
  assert.equal(env.DB.sql.prepare("SELECT COUNT(*) n FROM events").get().n, 1);
  assert.equal(env.DB.sql.prepare("SELECT value FROM state").get().value, now.toISOString());
  await poll(env, async url => {
    assert.equal(new URL(url).searchParams.get("since"), "2026-09-16T08:59:00.000Z");
    return Response.json([]);
  }, new Date("2026-09-16T08:59:30Z"));
  assert.equal(env.DB.sql.prepare("SELECT value FROM state").get().value, now.toISOString());
});

test("claims exclude competitors; expired claims cannot overwrite their successors", async () => {
  const db = database();
  await remember(db, [item], now.toISOString());
  const claims = await Promise.all([claim(db, event.id, "a", now), claim(db, event.id, "b", now)]);
  assert.equal(claims.filter(Boolean).length, 1);
  assert.ok(await claim(db, event.id, "c", new Date(now.getTime() + 601_000)));
  await finish(db, event.id, "a", null);
  assert.equal(db.sql.prepare("SELECT status FROM events").get().status, "dispatching");
  await finish(db, event.id, "c", null);
  assert.equal(db.sql.prepare("SELECT status FROM events").get().status, "dispatched");
  assert.equal(await claim(db, event.id, "d", new Date()), null);
});

test("GitHub dispatch sends the minimal payload and accepts only 204", async () => {
  await dispatch("example/ci", "ovpn-patchwork", "secret", item.submission, async (url, init) => {
    assert.equal(url, "https://api.github.com/repos/example/ci/dispatches");
    assert.deepEqual(JSON.parse(init.body), { event_type: "ovpn-patchwork", client_payload: item.submission });
    assert.equal(init.headers.Authorization, "Bearer secret");
    return new Response(null, { status: 204 });
  });
  await assert.rejects(dispatch("example/ci", "test", "secret", item.submission,
    async () => new Response("rate limit", { status: 403 })), /403/);
});

test("failed deliveries retry outside the polling window and success deduplicates", async () => {
  const env = environment();
  await remember(env.DB, [item], now.toISOString());
  await assert.rejects(deliver(env, async () => new Response("failure", { status: 500 })), /retained/);
  assert.equal(env.DB.sql.prepare("SELECT status FROM events").get().status, "pending");
  let sent = 0;
  const request = async url => {
    if (url.startsWith("https://patchwork.test")) return new Response("outage", { status: 503 });
    sent++;
    return new Response(null, { status: 204 });
  };
  await assert.rejects(tick(env, request), /503/);
  await deliver(env, request);
  assert.equal(sent, 1);
  assert.equal(env.DB.sql.prepare("SELECT attempts FROM events").get().attempts, 2);
});
