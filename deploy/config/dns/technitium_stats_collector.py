#!/usr/bin/env python3
import datetime as dt
import json
import os
import pathlib
import time
import urllib.parse
import urllib.request
import sqlite3

BASE = os.environ.get("TECHNITIUM_API_BASE", "http://127.0.0.1:5380").rstrip("/")
TOKEN = os.environ["TECHNITIUM_API_TOKEN"]
OUT = pathlib.Path(os.environ.get("STATS_DIR", "/data"))
EVENTS = pathlib.Path(os.environ.get("QUERY_EVENTS_FILE", str(OUT / "query-events.jsonl")))
INTERVAL = int(os.environ.get("INTERVAL_SECONDS", "3600"))
OUT.mkdir(parents=True, exist_ok=True)
DB = OUT / "dns-stats.sqlite3"
VALID_SOURCES = {"cached", "recursive", "blocked", "nxdomain", "error", "unknown"}

db = sqlite3.connect(DB, timeout=30)
db.execute("PRAGMA foreign_keys=ON")
db.execute("PRAGMA journal_mode=WAL")
db.execute("PRAGMA synchronous=NORMAL")
db.execute("PRAGMA busy_timeout=30000")
db.executescript("""
CREATE TABLE IF NOT EXISTS snapshots(
 id INTEGER PRIMARY KEY, ts TEXT NOT NULL UNIQUE, window_seconds INTEGER NOT NULL,
 counter_reset INTEGER NOT NULL, total_queries INTEGER, total_cached INTEGER,
 total_recursive INTEGER, total_blocked INTEGER, total_nxdomain INTEGER,
 total_noerror INTEGER, total_server_failure INTEGER, cached_entries INTEGER,
 cache_hit_rate REAL);
CREATE TABLE IF NOT EXISTS domain_top(
 snapshot_id INTEGER NOT NULL, domain TEXT NOT NULL, hits INTEGER NOT NULL,
 blocked INTEGER NOT NULL DEFAULT 0, FOREIGN KEY(snapshot_id) REFERENCES snapshots(id) ON DELETE CASCADE);
CREATE INDEX IF NOT EXISTS snapshots_ts ON snapshots(ts);
CREATE INDEX IF NOT EXISTS domain_top_domain ON domain_top(domain, snapshot_id);
CREATE INDEX IF NOT EXISTS domain_top_snapshot ON domain_top(snapshot_id);
CREATE TABLE IF NOT EXISTS query_events(
 id INTEGER PRIMARY KEY, event_id TEXT UNIQUE, ts TEXT NOT NULL,
 domain TEXT NOT NULL, source TEXT NOT NULL, query_type TEXT NOT NULL,
 client TEXT, rcode TEXT);
CREATE INDEX IF NOT EXISTS query_events_ts ON query_events(ts);
CREATE INDEX IF NOT EXISTS query_events_source_ts ON query_events(source,ts);
CREATE INDEX IF NOT EXISTS query_events_domain_ts ON query_events(domain,ts);
CREATE INDEX IF NOT EXISTS query_events_type_ts ON query_events(query_type,ts);
""")

def get_stats():
    q = urllib.parse.urlencode({"token": TOKEN})
    req = urllib.request.Request(BASE + "/api/dashboard/stats/get?" + q, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        body = json.loads(r.read().decode())
    if body.get("status") != "ok":
        raise RuntimeError("Technitium returned non-ok status")
    return body["response"]

def nums(response):
    s = response.get("stats", {})
    return {k: s.get(k, 0) for k in ("totalQueries", "totalCached", "totalRecursive", "totalBlocked", "totalNxDomain", "totalNoError", "totalServerFailure", "cachedEntries")}

def emit(path, row):
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")

def store(row):
    s = row["stats"]; d = row["delta"]
    cur = db.execute("""INSERT OR IGNORE INTO snapshots
      (ts,window_seconds,counter_reset,total_queries,total_cached,total_recursive,total_blocked,total_nxdomain,total_noerror,total_server_failure,cached_entries,cache_hit_rate)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""", (row["ts"],row["window_seconds"],int(row["counter_reset"]),s["totalQueries"],s["totalCached"],s["totalRecursive"],s["totalBlocked"],s["totalNxDomain"],s["totalNoError"],s["totalServerFailure"],s["cachedEntries"],row["cache_hit_rate"]))
    sid = cur.lastrowid or db.execute("SELECT id FROM snapshots WHERE ts=?",(row["ts"],)).fetchone()[0]
    domains = [(sid, str(x.get("name","")).strip().lower().rstrip("."), int(x.get("hits",0)), 0) for x in row.get("top_domains",[]) if x.get("name")]
    blocked = [(sid, str(x.get("name","")).strip().lower().rstrip("."), int(x.get("hits",0)), 1) for x in row.get("top_blocked_domains",[]) if x.get("name")]
    db.executemany("INSERT INTO domain_top(snapshot_id,domain,hits,blocked) VALUES(?,?,?,?)", domains + blocked)
    db.execute("DELETE FROM snapshots WHERE ts < datetime('now','-90 days')")
    db.execute("DELETE FROM domain_top WHERE snapshot_id NOT IN (SELECT id FROM snapshots)")
    db.commit()

def ingest_events():
    """Ingest normalized per-query events supplied by a log/API producer.

    Technitium's dashboard counters are aggregate-only; this optional file is
    intentionally an input contract, not an invented API endpoint. Each JSON
    line must contain timestamp, domain, source and query_type. event_id is
    recommended for safe deduplication.
    """
    if not EVENTS.exists():
        return 0
    count = 0
    with EVENTS.open(encoding="utf-8") as f:
        for line in f:
            try: e = json.loads(line)
            except json.JSONDecodeError: continue
            try:
                ts = dt.datetime.fromisoformat(str(e["timestamp"]).replace("Z", "+00:00")).astimezone(dt.timezone.utc).isoformat()
                domain = str(e["domain"]).strip().lower().rstrip(".")
                source = str(e["source"]).strip().lower()
                qtype = str(e["query_type"]).strip().upper()
                if not domain or source not in VALID_SOURCES or not qtype: continue
                eid = str(e["event_id"]).strip() if e.get("event_id") else None
                cur = db.execute("INSERT OR IGNORE INTO query_events(event_id,ts,domain,source,query_type,client,rcode) VALUES(?,?,?,?,?,?,?)", (eid,ts,domain,source,qtype,e.get("client"),e.get("rcode")))
                count += cur.rowcount
            except (KeyError, TypeError, ValueError): continue
    db.execute("DELETE FROM query_events WHERE ts < datetime('now','-90 days')")
    db.commit()
    return count

previous = None
state = OUT / "state.json"
if state.exists():
    try: previous = json.loads(state.read_text(encoding="utf-8"))
    except Exception: previous = None

while True:
    now = dt.datetime.now(dt.timezone.utc)
    try:
        ingest_events()
        response = get_stats(); current = nums(response)
        reset = bool(previous and any(current[k] < previous.get(k, current[k]) for k in current))
        delta = {k: (current[k] if reset else current[k] - previous.get(k, current[k])) for k in current}
        total = delta["totalQueries"]
        row = {"ts": now.isoformat(), "window_seconds": INTERVAL, "counter_reset": reset, "stats": current, "delta": delta,
               "cache_hit_rate": (delta["totalCached"] / total if total > 0 else None),
               "top_domains": response.get("topDomains", []), "top_blocked_domains": response.get("topBlockedDomains", []),
               "query_types": response.get("queryTypeChartData", {}).get("labels", [])}
        store(row)
        emit(OUT / "hourly.jsonl", row)
        emit(OUT / ("daily-" + now.strftime("%Y-%m-%d") + ".jsonl"), row)
        cutoff = now.date() - dt.timedelta(days=90)
        for old in OUT.glob("daily-*.jsonl"):
            try:
                if dt.date.fromisoformat(old.name[6:16]) < cutoff:
                    old.unlink()
            except (ValueError, OSError):
                pass
        state.write_text(json.dumps(current), encoding="utf-8")
        previous = current
    except Exception as e:
        emit(OUT / "errors.jsonl", {"ts": now.isoformat(), "error": type(e).__name__ + ": " + str(e)})
    time.sleep(INTERVAL)
