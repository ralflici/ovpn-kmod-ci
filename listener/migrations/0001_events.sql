CREATE TABLE state (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE events (
    id INTEGER PRIMARY KEY,
    category TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('series', 'patch')),
    object_id INTEGER NOT NULL,
    event_date TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'dispatching', 'dispatched')),
    attempts INTEGER NOT NULL DEFAULT 0,
    first_seen TEXT NOT NULL,
    claimed_at TEXT,
    claim_token TEXT,
    dispatched_at TEXT,
    last_error TEXT
);

CREATE INDEX events_pending ON events (status, id);
