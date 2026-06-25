# Plan 10 — SQLite data layer

**Theme:** Scale · **Effort:** L · **Depends on:** 05 (editing API as the seam) · defer until needed

## Goal

Replace the flat-JSON store with SQLite (system `libsqlite3`, no new SwiftPM dependency) so
lookups, graph traversal, and full-text search are indexed, and saves are incremental rather than
"rewrite the whole file every mutation".

## Why — and when

`Store` currently encodes/decodes and rewrites entire arrays on every change (Store.swift:47,
`saveSegments`/`saveMemories` write the full file). Graph traversal is O(n) filtering
(`AppState.memory(_:)`, `memories(in:)`, `segments(in:)`). This is **completely fine today** and
for thousands of memories — so this plan is explicitly **deferred** until one of these bites:
- memory/segment counts where full-file rewrites cause visible save latency or disk churn, or
- features that need real queries (FTS over transcripts, fast graph walks, time-range scans).

Doing it after plan 05 means the editing/provenance API (`updateMemory`, `sourceSegments`, etc.) is
the stable seam we port behind, rather than refactoring twice.

## Current state

- `Store` (Store.swift) = JSON files under `~/.config/nemo/data/`: `transcript.json`,
  `memories.json`, `sessions.json`, `speakers.json`, `briefing.json` (+ future `embeddings.json`,
  `usage.json`).
- All access goes through `Store.load*` / `Store.save*` and `AppState`'s in-memory `@Published`
  arrays — a clean choke point to swap.

## Design

### Principle: swap the backend, keep the API

Keep `AppState`'s published arrays as the in-memory working set (the UI binds to them). Change only
*how* they're loaded and persisted. Two viable shapes:

1. **Full SQLite store** — `nemo.db` with tables `memories`, `segments`, `sessions`, `speakers`,
   `memory_links`, plus FTS5 virtual tables for transcript + memory search. `Store` becomes a thin
   DAO over `sqlite3` C API (or a hand-rolled minimal wrapper — no GRDB unless the
   no-dependency rule is revisited).
2. **Hybrid** (smaller step) — keep JSON for small/whole-load data (sessions, speakers, briefing),
   move only the two unbounded tables (segments, memories + links) to SQLite. Lower risk, captures
   most of the win.

Recommend starting with the **hybrid**.

### Schema sketch

```sql
CREATE TABLE memories(
  id TEXT PRIMARY KEY, title TEXT, content TEXT, category TEXT,
  importance INTEGER, weight REAL, pinned INTEGER, user_edited INTEGER,
  superseded INTEGER, superseded_by TEXT, source TEXT,
  created TEXT, updated TEXT, last_surfaced TEXT, hit_count INTEGER
);
CREATE TABLE memory_entities(memory_id TEXT, entity TEXT);      -- indexed
CREATE TABLE memory_links(a TEXT, b TEXT);                       -- bidirectional, indexed
CREATE TABLE memory_sources(memory_id TEXT, segment_id TEXT);    -- provenance (plan 05)
CREATE TABLE segments(id TEXT PRIMARY KEY, text TEXT, start TEXT, end TEXT,
  marked INTEGER, session_id TEXT, consolidated INTEGER, speaker INTEGER);
CREATE VIRTUAL TABLE segments_fts USING fts5(text, content='segments', content_rowid='rowid');
CREATE INDEX idx_seg_session ON segments(session_id);
CREATE INDEX idx_ent ON memory_entities(entity);
```

This makes plan 03's candidate generation (shared-entity lookup), plan 05's provenance resolution,
and any transcript search index-backed instead of full scans.

### Migration

- One-time: if `nemo.db` is absent but JSON files exist, import them into SQLite, then leave the
  JSON in place as a backup (rename to `*.json.bak`). Idempotent and reversible.
- Mirror `Store.migrateLegacyConfigIfNeeded`'s "run once before any read" pattern (Store.swift:8).

### Writes

- Per-mutation upserts/deletes instead of whole-file rewrites. Wrap multi-row changes
  (consolidation result) in a transaction. Keep writes off the main thread (as `Store.save` does
  today).

## Files touched

- `Sources/Nemo/Store.swift` — becomes (or delegates to) a SQLite DAO; keep the same static
  method signatures so `AppState` barely changes.
- **New:** `Sources/Nemo/SQLite.swift` — minimal `sqlite3` wrapper (open, prepare, bind, step,
  finalize) if not using a package.
- `Package.swift` — link `libsqlite3` (system library; `linkerSettings: [.linkedLibrary("sqlite3")]`).
- `AppState` — likely unchanged beyond load/save calls; verify the in-memory arrays still suit the
  UI (they do for thousands of rows).

## Edge cases

- **Corruption / partial migration:** keep JSON backups; on DB open failure, fall back to JSON and
  surface a warning rather than data loss.
- **Concurrency:** single connection on a serial queue, or WAL mode for concurrent reads; keep
  writes serialized.
- **The "load everything into @Published arrays" model** still holds the full set in memory — fine
  for the foreseeable scale; if that ever becomes the bottleneck, paginate the UI as a separate
  step (out of scope here).

## Testing (see plan 07)

- Unit: round-trip a memory/segment through the DAO (insert → query → matches).
- Unit: JSON→SQLite migration produces identical logical data (counts, links, provenance).
- Unit: FTS query returns expected segments.
- Manual: large synthetic dataset (e.g. 50k segments) — confirm save latency drops vs JSON.

## Risks / open questions

- Hand-rolling a `sqlite3` wrapper is fiddly (C interop, memory management). If the no-dependency
  rule can flex for a vetted, zero-transitive-dep SQLite wrapper, reconsider — but the system
  library keeps the "Apple frameworks only" spirit.
- Biggest risk is migration correctness; the JSON-backup + fallback makes it safe to ship behind a
  flag and verify on real data before removing the JSON path.
