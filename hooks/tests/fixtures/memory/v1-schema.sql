-- atelier-memory schema v1 (LATEST_SCHEMA=1) plus one seed record, for the
-- v1 -> v2 migration cases in atelier-memory-import.test.sh. Frozen on purpose:
-- do not update it when the live schema moves. __PROJECT__ is replaced at test time.
CREATE TABLE records (
  id            TEXT NOT NULL UNIQUE,
  type          TEXT NOT NULL CHECK (type IN ('request','question','decision','fact','held','digest')),
  project       TEXT NOT NULL,
  source        TEXT NOT NULL CHECK (source IN ('operator-verbatim','agent-inferred','board-derived')),
  title         TEXT NOT NULL,
  body          TEXT NOT NULL DEFAULT '',
  quote         TEXT,
  refs          TEXT NOT NULL DEFAULT '[]',
  created_at    TEXT NOT NULL,
  created_by    TEXT NOT NULL,
  superseded_by TEXT,
  superseded_at TEXT,
  closed_at     TEXT,
  closed_by     TEXT,
  CHECK (source <> 'operator-verbatim' OR length(trim(coalesce(quote,''))) > 0)
);
CREATE VIRTUAL TABLE records_fts USING fts5(title, body, quote, content='records', content_rowid='rowid');
CREATE TRIGGER records_ai AFTER INSERT ON records BEGIN
  INSERT INTO records_fts(rowid, title, body, quote) VALUES (new.rowid, new.title, new.body, coalesce(new.quote,''));
END;
CREATE TRIGGER records_immutable BEFORE UPDATE ON records
WHEN NEW.rowid IS NOT OLD.rowid OR NEW.id IS NOT OLD.id OR NEW.type IS NOT OLD.type
  OR NEW.project IS NOT OLD.project OR NEW.source IS NOT OLD.source OR NEW.title IS NOT OLD.title
  OR NEW.body IS NOT OLD.body OR NEW.quote IS NOT OLD.quote OR NEW.refs IS NOT OLD.refs
  OR NEW.created_at IS NOT OLD.created_at OR NEW.created_by IS NOT OLD.created_by
  OR (OLD.superseded_by IS NOT NULL AND NEW.superseded_by IS NOT OLD.superseded_by)
  OR (OLD.superseded_at IS NOT NULL AND NEW.superseded_at IS NOT OLD.superseded_at)
  OR (OLD.closed_at IS NOT NULL AND NEW.closed_at IS NOT OLD.closed_at)
  OR (OLD.closed_by IS NOT NULL AND NEW.closed_by IS NOT OLD.closed_by)
BEGIN SELECT RAISE(ABORT, 'records are immutable: supersede instead of editing'); END;
CREATE TRIGGER records_no_delete BEFORE DELETE ON records
BEGIN SELECT RAISE(ABORT, 'records are never deleted: supersede or close instead'); END;
CREATE INDEX records_project_type ON records(project, type);
INSERT INTO records (id, type, project, source, title, created_at, created_by)
  VALUES ('D-1', 'decision', '__PROJECT__', 'agent-inferred', 'Legacy', '2026-01-01T00:00:00Z', 'agent');
PRAGMA user_version=1;
