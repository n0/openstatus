import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

LIBSQL_URL = os.environ.get("LIBSQL_URL", "http://libsql:8080").rstrip("/")
CHECKER_BASE_URL = os.environ.get("CHECKER_BASE_URL")
CHECKER_URL = os.environ.get("CHECKER_URL", "http://checker:8080/checker/http?data=true")
CRON_SECRET = os.environ.get("CRON_SECRET", "")
INTERVAL_SECONDS = int(os.environ.get("INTERVAL_SECONDS", "60"))
TINYBIRD_URL = os.environ.get("TINYBIRD_URL", "").rstrip("/")
TB_TOKEN = os.environ.get("TB_TOKEN", "")

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

def checker_base_url():
    if CHECKER_BASE_URL:
        return CHECKER_BASE_URL.rstrip("/")
    marker = "/checker/"
    if marker in CHECKER_URL:
        return CHECKER_URL.split(marker, 1)[0].rstrip("/")
    return CHECKER_URL.rstrip("/")

def checker_url(job_type):
    if job_type not in {"http", "tcp", "dns"}:
        raise RuntimeError(f"unsupported monitor job_type {job_type!r}")
    return f"{checker_base_url()}/checker/{job_type}?data=true"

def parse_bool(value, default=False):
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    return str(value).lower() in {"1", "true", "yes", "on"}

def active_monitors():
    sql = """
    SELECT id, workspace_id, job_type, url, method, status, body, headers, assertions,
           timeout, degraded_after, retry, follow_redirects, regions, periodicity
    FROM monitor
    WHERE active = 1
      AND deleted_at IS NULL
      AND job_type IN ('http', 'tcp', 'dns')
      AND periodicity IN ('30s','1m','5m','10m','30m','1h')
    ORDER BY id
    """.replace("\n", " ")
    return extract_result(libsql(sql))

def should_run(periodicity, now_ms):
    seconds = PERIOD_SECONDS.get(periodicity or "1m", 60)
    return int(now_ms / 1000) % seconds < INTERVAL_SECONDS

def run_monitor(monitor, now_ms):
    job_type = monitor.get("job_type") or monitor.get("jobType")
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
        "trigger": "cron",
    }
    if job_type == "http":
        payload.update({
            "url": monitor.get("url"),
            "method": monitor.get("method") or "GET",
            "body": monitor.get("body") or "",
            "headers": headers or [],
            "followRedirects": parse_bool(monitor.get("follow_redirects"), True),
        })
    elif job_type in {"tcp", "dns"}:
        payload["uri"] = monitor.get("url")
    else:
        raise RuntimeError(f"unsupported monitor job_type {job_type!r}")
    post_json(checker_url(job_type), payload, {"Authorization": f"Basic {CRON_SECRET}"}, timeout=60)

def tb_sql(sql):
    if not TINYBIRD_URL:
        return None
    url = f"{TINYBIRD_URL}/v0/sql?q=" + urllib.parse.quote(sql + " FORMAT JSON")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {TB_TOKEN}"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())

def tb_count(table):
    try:
        r = tb_sql(f"SELECT count() AS n FROM {table}")
        return r["data"][0]["n"]
    except Exception as exc:  # noqa: BLE001
        return f"ERR:{exc}"

def tinybird_diagnostics():
    if not TINYBIRD_URL:
        log("tb-diag: TINYBIRD_URL not set, skipping")
        return
    for t in ("ping_response__v8", "tcp_response__v0", "dns_response__v0",
              "mv__http_status_45d__v1", "mv__tcp_status_45d__v1", "mv__dns_status_45d__v0"):
        log("tb-diag count", t, "=", tb_count(t))
    try:
        ds = tb_sql("SELECT name FROM tinybird.datasources_ops_log LIMIT 0")  # noqa: F841
    except Exception:
        pass
    try:
        r = tb_sql("SELECT monitorId, requestStatus, cronTimestamp FROM tcp_response__v0 ORDER BY timestamp DESC LIMIT 3")
        log("tb-diag tcp sample:", json.dumps(r.get("data", [])) if r else None)
    except Exception as exc:  # noqa: BLE001
        log("tb-diag tcp sample ERR:", exc)
    try:
        r = tb_sql("SELECT monitorId, requestStatus, cronTimestamp FROM dns_response__v0 ORDER BY timestamp DESC LIMIT 3")
        log("tb-diag dns sample:", json.dumps(r.get("data", [])) if r else None)
    except Exception as exc:  # noqa: BLE001
        log("tb-diag dns sample ERR:", exc)

import urllib.parse  # noqa: E402
log("starting self-host local scheduler", f"libsql={LIBSQL_URL}", f"checker_base={checker_base_url()}", f"interval={INTERVAL_SECONDS}s")
try:
    tinybird_diagnostics()
except Exception as exc:  # noqa: BLE001
    log("tb-diag failed:", exc)
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
