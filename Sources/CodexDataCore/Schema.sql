PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;
PRAGMA secure_delete = ON;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS sources (
    id INTEGER PRIMARY KEY,
    kind TEXT NOT NULL,
    external_id TEXT NOT NULL,
    thread_source TEXT NOT NULL,
    source_app TEXT NOT NULL,
    cli_version TEXT NOT NULL,
    source_timestamp TEXT NOT NULL,
    working_directory_encrypted BLOB,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(kind, external_id)
);

CREATE TABLE IF NOT EXISTS source_cursors (
    source_id INTEGER PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
    device_id INTEGER NOT NULL DEFAULT 0,
    inode INTEGER NOT NULL DEFAULT 0,
    safe_offset INTEGER NOT NULL DEFAULT 0,
    safe_line_number INTEGER NOT NULL DEFAULT 0,
    file_size INTEGER NOT NULL DEFAULT 0,
    parser_version INTEGER NOT NULL DEFAULT 1,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS conversations (
    id INTEGER PRIMARY KEY,
    source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    external_id TEXT NOT NULL,
    source_timestamp TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(source_id, external_id)
);

CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY,
    conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    external_id TEXT NOT NULL,
    role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
    source_timestamp TEXT NOT NULL,
    body_encrypted BLOB NOT NULL,
    body_character_count INTEGER NOT NULL,
    redaction_counts_json TEXT NOT NULL,
    source_line_number INTEGER NOT NULL,
    source_byte_offset INTEGER NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(conversation_id, external_id)
);

CREATE TABLE IF NOT EXISTS import_runs (
    id INTEGER PRIMARY KEY,
    source_kind TEXT NOT NULL,
    started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    finished_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status TEXT NOT NULL,
    inserted_message_count INTEGER NOT NULL,
    existing_message_count INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS source_tombstones (
    id INTEGER PRIMARY KEY,
    kind TEXT NOT NULL,
    external_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(kind, external_id)
);

CREATE TABLE IF NOT EXISTS expressions (
    id INTEGER PRIMARY KEY,
    digest BLOB NOT NULL UNIQUE,
    body_encrypted BLOB NOT NULL,
    occurrence_count INTEGER NOT NULL CHECK(occurrence_count > 0),
    conversation_count INTEGER NOT NULL CHECK(conversation_count > 0),
    last_source_timestamp TEXT NOT NULL,
    extractor_version INTEGER NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS expression_occurrences (
    expression_id INTEGER NOT NULL REFERENCES expressions(id) ON DELETE CASCADE,
    message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    PRIMARY KEY(expression_id, message_id)
);

CREATE TABLE IF NOT EXISTS expression_tombstones (
    digest BLOB PRIMARY KEY,
    body_encrypted BLOB NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS expression_builds (
    id INTEGER PRIMARY KEY,
    extractor_version INTEGER NOT NULL,
    status TEXT NOT NULL,
    source_message_count INTEGER NOT NULL,
    active_expression_count INTEGER NOT NULL,
    skipped_tombstone_count INTEGER NOT NULL,
    started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    finished_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT OR IGNORE INTO schema_migrations(version) VALUES(1);
INSERT OR IGNORE INTO schema_migrations(version) VALUES(2);
INSERT OR IGNORE INTO schema_migrations(version) VALUES(3);
INSERT OR IGNORE INTO schema_migrations(version) VALUES(4);
