import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

LIBSQL_URL = os.environ.get("LIBSQL_URL", "http://libsql:8080").rstrip("/")
CHECKER_URL = os.environ.get("CHECKER_URL", "http://checker:8080/checker/http?data=true")
CRON_SECRET = os.environ.get("CRON_SECRET", "")
INTERVAL_SECONDS = int(os.environ.get("INTERVAL_SECONDS", "60"))

PERIOD_SECONDS = {
    "30s": 30,
    "1m": 60,
    "5m": 300,
    "10m": 600,
    "30m": 1800,
    "1h": 3600,
}

def log(*args):
    print(datetime.now(timezone.utc).isoformat(), *args, flush=True)

def post_json(url, payload, headers=None, timeout=30):
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={"Content-Type": "application/json", **(headers or {})},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = resp.read()
        if resp.status >= 400:
            raise RuntimeError(f"{url} returned HTTP {resp.status}: {data[:500]!r}")
        if not data:
            return None
        try:
            return json.loads(data)
        except json.JSONDecodeError:
            return data.decode(errors="replace")

def libsql(sql):
    return post_json(
        f"{LIBSQL_URL}/v2/pipeline",
        {"requests": [{"type": "execute", "stmt": {"sql": sql}}, {"type": "close"}]},
        timeout=30,
    )

def cell_value(cell):
    if isinstance(cell, dict):
        if "value" in cell:
            return cell["value"]
        if "integer" in cell:
            return cell["integer"]
        if "text" in cell:
            return cell["text"]
        if cell.get("type") == "null":
            return None
    return cell

def extract_result(payload):
    results = payload.get("results") or payload.get("responses") or []
    for item in results:
        response = item.get("response", item) if isinstance(item, dict) else item
        result = response.get("result", response) if isinstance(response, dict) else response
        if isinstance(result, dict) and ("cols" in result or "columns" in result or "rows" in result):
            cols = result.get("cols") or result.get("columns") or []
            rows = result.get("rows") or []
            names = []
            for col in cols:
                if isinstance(col, dict):
                    names.append(col.get("name") or col.get("column") or col.get("label"))
                else:
                    names.append(str(col))
            out = []
            for row in rows:
                values = row.get("values", row) if isinstance(row, dict) else row
                out.append({name: cell_value(value) for name, value in zip(names, values)})
            return out
    return []

def parse_json_field(value, fallback):
    if value is None or value == "":
        return fallback
    if isinstance(value, (list, dict)):
        return value
    try:
        return json.loads(value)
    except Exception:
        return fallback

def active_monitors():
    sql = """
    SELECT id, workspace_id, url, method, status, body, headers, assertions,
           timeout, degraded_after, retry, follow_redirects, regions, periodicity
    FROM monitor
    WHERE active = 1
      AND deleted_at IS NULL
      AND job_type = 'http'
      AND periodicity IN ('30s','1m','5m','10m','30m','1h')
    ORDER BY id
    """.replace("\n", " ")
    return extract_result(libsql(sql))

def should_run(periodicity, now_ms):
    seconds = PERIOD_SECONDS.get(periodicity or "1m", 60)
    return int(now_ms / 1000) % seconds < INTERVAL_SECONDS

def run_monitor(monitor, now_ms):
    headers = parse_json_field(monitor.get("headers"), [])
    if isinstance(headers, dict):
        headers = [{"key": k, "value": str(v)} for k, v in headers.items()]
    assertions = parse_json_field(monitor.get("assertions"), [])
    payload = {
        "workspaceId": str(monitor.get("workspace_id") or monitor.get("workspaceId") or ""),
        "monitorId": str(monitor.get("id")),
        "url": monitor.get("url"),
        "method": monitor.get("method") or "GET",
        "status": monitor.get("status") or "active",
        "body": monitor.get("body") or "",
        "headers": headers or [],
        "assertions": assertions or [],
        "cronTimestamp": now_ms,
        "timeout": int(monitor.get("timeout") or 45000),
        "degradedAfter": int(monitor.get("degraded_after") or 0),
        "retry": int(monitor.get("retry") or 1),
        "followRedirects": bool(monitor.get("follow_redirects") if monitor.get("follow_redirects") is not None else True),
        "trigger": "cron",
    }
    post_json(CHECKER_URL, payload, {"Authorization": f"Basic {CRON_SECRET}"}, timeout=60)

log("starting self-host local scheduler", f"libsql={LIBSQL_URL}", f"checker={CHECKER_URL}", f"interval={INTERVAL_SECONDS}s")
while True:
    now_ms = int(time.time() * 1000)
    try:
        monitors = active_monitors()
        due = [m for m in monitors if should_run(m.get("periodicity") or "1m", now_ms)]
        log(f"loaded={len(monitors)} due={len(due)}")
        ok = 0
        failed = 0
        for monitor in due:
            try:
                run_monitor(monitor, now_ms)
                ok += 1
            except Exception as exc:
                failed += 1
                log(f"monitor {monitor.get('id')} failed: {exc}")
        log(f"tick complete ok={ok} failed={failed}")
    except Exception as exc:
        log("scheduler tick failed:", repr(exc))
    time.sleep(INTERVAL_SECONDS)
