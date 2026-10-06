#!/usr/bin/env python3
"""Extract only explicitly logged Technitium recursive failures as query events.

Technitium's dashboard is aggregate-only, so this producer never labels an
event cached/recursive unless the log line proves it. It is deliberately
conservative; successful cached queries require a native query-log producer.
"""
import datetime as dt, hashlib, json, os, pathlib, re, time

LOG_DIR = pathlib.Path(os.environ.get("DNS_LOG_DIR", "/logs"))
OUT = pathlib.Path(os.environ.get("EVENTS_OUT", "/data/query-events.jsonl"))
STATE = pathlib.Path(os.environ.get("EVENTS_STATE", "/data/query-events.state.json"))
POLL = float(os.environ.get("POLL_SECONDS", "2"))
PAT = re.compile(r"\[(?P<ts>[^]]+)\].*?failed to resolve the request '(?P<q>[^']+)'", re.I)

def parse_q(q):
    p = q.rstrip().split()
    if len(p) < 3: return None
    domain, qtype, qclass = p[0].lower().rstrip("."), p[1].upper(), p[2].upper()
    if qclass != "IN" or not domain or not re.match(r"^[a-z0-9_.:-]+$", domain): return None
    return domain, qtype

def main():
    OUT.parent.mkdir(parents=True, exist_ok=True)
    try: state = json.loads(STATE.read_text())
    except Exception: state = {}
    offsets = {k:int(v) for k,v in state.items()}
    while True:
        for path in sorted(LOG_DIR.glob("*.log")):
            key = str(path); off = offsets.get(key, 0)
            try:
                size = path.stat().st_size
                if off > size: off = 0
                with path.open(encoding="utf-8", errors="replace") as f:
                    f.seek(off)
                    while True:
                        line = f.readline()
                        if not line: break
                        m = PAT.search(line)
                        if not m: continue
                        parsed = parse_q(m.group("q"))
                        if not parsed: continue
                        domain, qtype = parsed
                        try: ts = dt.datetime.strptime(m.group("ts"), "%Y-%m-%d %H:%M:%S UTC").replace(tzinfo=dt.timezone.utc).isoformat()
                        except ValueError: continue
                        eid = hashlib.sha256((ts+"|"+domain+"|"+qtype+"|recursive").encode()).hexdigest()
                        with OUT.open("a", encoding="utf-8") as out:
                            out.write(json.dumps({"event_id":eid,"timestamp":ts,"domain":domain,"query_type":qtype,"source":"recursive","rcode":"SERVFAIL"},separators=(",",":"))+"\n")
                    offsets[key] = f.tell()
            except OSError as exc:
                print(f"producer read/write error for {path}: {exc}", flush=True)
                continue
        STATE.write_text(json.dumps(offsets,separators=(",",":")))
        time.sleep(POLL)
if __name__ == "__main__": main()
