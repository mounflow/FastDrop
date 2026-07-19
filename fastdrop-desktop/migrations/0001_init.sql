-- FastDrop initial schema (spec §22).
-- Five tables. Chunk completion is a bitmap BLOB, NOT one row per chunk.

CREATE TABLE IF NOT EXISTS devices (
    id            TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    platform      TEXT NOT NULL,
    app_version   TEXT,
    last_ip       TEXT,
    first_seen_at INTEGER NOT NULL,
    last_seen_at  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    id          TEXT PRIMARY KEY,
    device_id   TEXT NOT NULL,
    token_hash  TEXT NOT NULL,
    source_ip   TEXT,
    created_at  INTEGER NOT NULL,
    expires_at  INTEGER NOT NULL,
    revoked_at  INTEGER,
    FOREIGN KEY(device_id) REFERENCES devices(id)
);

CREATE INDEX IF NOT EXISTS idx_sessions_device ON sessions(device_id);
CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at);

CREATE TABLE IF NOT EXISTS transfers (
    id                 TEXT PRIMARY KEY,
    session_id         TEXT,
    peer_device_id     TEXT NOT NULL,
    direction          TEXT NOT NULL,           -- client_to_server | server_to_client
    status             TEXT NOT NULL,           -- see §12 state machine
    total_files        INTEGER NOT NULL,
    total_bytes        INTEGER NOT NULL,
    transferred_bytes  INTEGER NOT NULL DEFAULT 0,
    created_at         INTEGER NOT NULL,
    started_at         INTEGER,
    completed_at       INTEGER,
    error_code         TEXT,
    error_message      TEXT
);

CREATE INDEX IF NOT EXISTS idx_transfers_session ON transfers(session_id);
CREATE INDEX IF NOT EXISTS idx_transfers_status  ON transfers(status);

CREATE TABLE IF NOT EXISTS transfer_files (
    id                  TEXT PRIMARY KEY,
    transfer_id         TEXT NOT NULL,
    client_file_id      TEXT,
    original_name       TEXT NOT NULL,
    saved_name          TEXT,
    source_path         TEXT,
    target_path         TEXT,
    mime_type           TEXT,
    total_bytes         INTEGER NOT NULL,
    transferred_bytes   INTEGER NOT NULL DEFAULT 0,
    chunk_size          INTEGER NOT NULL,
    total_chunks        INTEGER NOT NULL,
    completed_chunks    INTEGER NOT NULL DEFAULT 0,
    sha256_expected     TEXT,
    sha256_actual       TEXT,
    status              TEXT NOT NULL,
    created_at          INTEGER NOT NULL,
    completed_at        INTEGER,
    error_code          TEXT,
    FOREIGN KEY(transfer_id) REFERENCES transfers(id)
);

CREATE INDEX IF NOT EXISTS idx_transfer_files_transfer ON transfer_files(transfer_id);

-- Per-file bitmap BLOB. Each bit corresponds to a chunk index.
CREATE TABLE IF NOT EXISTS file_chunk_states (
    file_id            TEXT PRIMARY KEY,
    completed_bitmap   BLOB NOT NULL,
    updated_at         INTEGER NOT NULL
);
