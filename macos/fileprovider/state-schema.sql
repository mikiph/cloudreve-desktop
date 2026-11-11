-- Version 1. Shared by the Rust host and Swift extension. Changes must be
-- additive while either process from the previous build can still be running.
-- New objects must ALSO be added as idempotent upgrade statements run on every open (Rust RESCAN_INDEX / Swift rescanIndex); SCHEMA only initializes empty databases.
CREATE TABLE IF NOT EXISTS fp_state_schema (version INTEGER NOT NULL);
INSERT INTO fp_state_schema SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM fp_state_schema);
CREATE TABLE IF NOT EXISTS fp_event_heads (
    drive TEXT PRIMARY KEY NOT NULL,
    latest INTEGER NOT NULL DEFAULT 0,
    floor INTEGER NOT NULL DEFAULT 0,
    imported INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS fp_events (
    drive TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    payload TEXT NOT NULL,
    PRIMARY KEY (drive, sequence)
);
CREATE INDEX IF NOT EXISTS idx_fp_events_rescan ON fp_events(drive,sequence)
    WHERE CASE WHEN json_valid(payload) THEN json_extract(payload,'$.type') END='rescan';
CREATE TABLE IF NOT EXISTS fp_records (
    namespace TEXT NOT NULL,
    key TEXT NOT NULL,
    payload TEXT NOT NULL,
    PRIMARY KEY (namespace, key)
);
CREATE TABLE IF NOT EXISTS fp_imports (
    namespace TEXT PRIMARY KEY NOT NULL
);
CREATE TABLE IF NOT EXISTS fp_deliveries (id TEXT PRIMARY KEY NOT NULL);
