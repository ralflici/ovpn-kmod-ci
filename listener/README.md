# Patchwork listener

A scheduled Cloudflare Worker polls the ovpn project every two minutes and sends
one `ovpn-patchwork` repository dispatch per completed series or standalone patch.
It contains no kernel/test policy. Series-member events and other categories are
ignored. There is no public HTTP endpoint.

The payload is deliberately small:

```json
{
  "event_type": "ovpn-patchwork",
  "client_payload": {
    "patchwork_event_id": 23472,
    "kind": "series",
    "id": 4064
  }
}
```

## Local checks

The Worker, tests and preview script are plain JavaScript (`.js`).
`package.json` sets `"type": "module"` to enable `import`/`export`. Tests and
preview import `src/` directly; there is no TypeScript compilation step or
generated source tree. Wrangler bundles the source when deploying.

Use Node 22.13+ and run these commands in `listener/`:

```sh
npm ci
npm test
npx wrangler deploy --dry-run
npx wrangler d1 migrations apply ovpn-patchwork-listener --local
```

Tests use Node's SQLite support with the real migration and SQL, and mocked HTTP
responses. SQLite may print an experimental-feature warning on Node 22.

Preview a real event without a GitHub token, a Cloudflare account, or database
writes:

```sh
npm run preview -- \
  --since 2026-09-16T08:38:00Z --before 2026-09-16T08:39:00Z \
  --event-id 23472
```

Without arguments, preview reads the last ten minutes. Events are retrieved from
the list endpoint: this instance does not have `/events/<id>/`. It also accepts
only one category filter value, so the Worker selects both completion categories
from the project event stream locally.

`npm run dev` exposes the local scheduled handler at
`http://localhost:8787/__scheduled`. Calling it runs a real polling pass with a
local D1 database. With no `GITHUB_TOKEN`, discovered events stay pending. Only
use preview if you want a guaranteed read-only run; supplying a token to the
local Worker permits real GitHub dispatches.

## Cloudflare setup

The GitHub workflow `.github/workflows/patchwork.yml` must be on the destination
repository's **default branch before enabling the listener**. A successful
dispatch response does not prove that GitHub started a workflow. While developing
on another branch, test locally; do not deploy the cron yet.

1. In Cloudflare's left sidebar, open **Storage & databases → D1 SQL Database**.
   Click **Create database**, name it `ovpn-patchwork-listener`, leave the location
   at its default, and click **Create**. On the new database's **Overview** page,
   copy its **Database ID** (a UUID) into `wrangler.toml`.
   Alternatively, create it from the terminal:

   ```sh
   npx wrangler login
   npx wrangler d1 create ovpn-patchwork-listener
   ```

2. Check `GITHUB_REPOSITORY` in `wrangler.toml`. Create a GitHub fine-grained
   personal access token restricted to that repository, with **Contents: read
   and write** (required by the repository-dispatch API). Keep its expiry in mind.
   Store it as a Worker secret; do not put the token in this repository or chat:

   ```sh
   npx wrangler secret put GITHUB_TOKEN
   ```

   If Wrangler asks to create the named Worker because it does not exist yet,
   allow it. Deploying the code and schedule is a separate command below.

3. Apply the migration to Cloudflare, then deploy once GitHub is ready:

   ```sh
   npx wrangler d1 migrations apply ovpn-patchwork-listener --remote
   npm run deploy
   npx wrangler tail
   ```

The Worker, D1 binding, variables and cron schedule are managed by Wrangler;
there is no need to paste code into the dashboard editor. The Worker name
must match if you already created one manually.

## Updating the Worker

Deployment is manual, independent of Git pushes and the validation workflow.
After reviewing changes, run from `listener/`:

```sh
npm ci
npm test
npm run deploy
```

Wrangler uploads and activates a new version of the existing Worker. There is
no service to stop and restart manually. The existing D1 database, polling
watermark, delivery records and Worker secret are retained. Code-only updates
do not require running the database migration again; apply new migrations
separately if the schema changes. Rolling back code does not roll back D1 data.

If a poll is interrupted, the next scheduled invocation resumes from the
stored watermark. Interrupted dispatch claims become retryable after ten
minutes; the duplicate-delivery caveat below still applies. GitHub jobs already
started are independent of the Worker and keep running.

## Delivery and recovery

D1 stores dispatchable events keyed by Patchwork event ID. Each run reads from
one minute before its last successful poll to the current poll start. The first
run looks back ten minutes. The watermark advances only after all pages are
stored, independently of dispatch success. Pages are capped at 20; reaching the
cap fails the pass without advancing the watermark.

Pending events are claimed atomically, at most 20 per invocation. Failure returns
an event to pending for the next cron. Claims older than ten minutes can be
reclaimed; claim tokens prevent old invocations from overwriting new claims.
The pending queue is also processed when polling fails. D1 read replication is
not needed and should remain disabled for this small database.

Delivery is at least once: a crash between GitHub accepting the event and D1
recording success can cause a duplicate run. V1 tolerates this. D1 does not track
test completion or suppress later manual workflow reruns.

Inspect delivery state:

```sh
npx wrangler d1 execute ovpn-patchwork-listener --remote \
  --command "SELECT id, kind, object_id, status, attempts, last_error FROM events ORDER BY id DESC LIMIT 20"
```

For old submissions, use GitHub's manual workflow inputs (`kind` and `id`);
there is no need to rewind the listener. Worker logs and the D1 `last_error`
field show authentication, rate-limit, and API errors. No Patchwork token is
needed. Posting results to Patchwork is deferred.
