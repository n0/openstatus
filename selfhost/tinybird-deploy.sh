#!/bin/sh
# Provision the local Tinybird (Classic, COMPATIBILITY_MODE=1) container with the
# OpenStatus data project so the status-page uptime endpoints exist and the
# checker's ingested ping/tcp/dns events flow through the materialized views.
#
# This is idempotent and tolerant: each datafile is pushed independently with
# --force so a single bad/non-essential file never blocks the rest. The chain
# required for the public status bars is:
#   ping_response__v8 -> aggregate__http_status_45d__v1 -> mv__http_status_45d__v1 -> endpoint__http_status_45d__v1
# (and the tcp/dns equivalents).

set -u

TB_HOST="${TINYBIRD_URL:-http://tinybird:7181}"
PROJECT_DIR="${PROJECT_DIR:-/project}"

log() { echo "[tinybird-deploy] $*"; }

cd "$PROJECT_DIR" || { log "FATAL: cannot cd to $PROJECT_DIR"; sleep infinity; }

# 1. Wait for the local Tinybird API to answer and hand us the admin token.
TOKEN=""
i=0
while [ "$i" -lt 80 ]; do
  TOKEN=$(python3 - "$TB_HOST" <<'PY' 2>/dev/null
import sys, json, urllib.request
host = sys.argv[1].rstrip("/")
try:
    with urllib.request.urlopen(host + "/tokens", timeout=5) as r:
        print(json.load(r).get("workspace_admin_token", ""))
except Exception:
    print("")
PY
)
  [ -n "$TOKEN" ] && { log "tinybird is ready (got admin token from /tokens)"; break; }
  i=$((i + 1))
  log "waiting for tinybird at $TB_HOST ... ($i)"
  sleep 3
done

if [ -z "$TOKEN" ]; then
  TOKEN="${TB_TOKEN:-}"
  [ -n "$TOKEN" ] && log "falling back to TB_TOKEN env" || { log "FATAL: no token available"; sleep infinity; }
fi

# 2. Authenticate the CLI against the local container.
log "authenticating CLI against $TB_HOST"
tb auth --host "$TB_HOST" --token "$TOKEN" || { log "FATAL: tb auth failed"; sleep infinity; }

OK=0
FAIL=0
FAILED_FILES=""

push() {
  f="$1"
  [ -f "$f" ] || return 0
  if tb push "$f" --force >"/tmp/push.out" 2>&1; then
    OK=$((OK + 1))
    log "OK   $f"
  else
    FAIL=$((FAIL + 1))
    FAILED_FILES="$FAILED_FILES $f"
    log "FAIL $f"
    sed 's/^/[tinybird-deploy]      | /' /tmp/push.out | tail -n 8
  fi
}

# 3. Push in dependency order: raw + MV target datasources, then materialized
#    aggregate pipes, then endpoint pipes.
log "=== pushing datasources ==="
for f in datasources/*.datasource; do push "$f"; done

log "=== pushing pipes (materialized aggregates) ==="
for f in pipes/*.pipe; do push "$f"; done

log "=== pushing endpoints ==="
for f in endpoints/*.pipe; do push "$f"; done

log "================ SUMMARY ================"
log "pushed OK: $OK   failed: $FAIL"
[ -n "$FAILED_FILES" ] && log "failed files:$FAILED_FILES"

# 4. Verify the essential status-bar endpoints exist.
log "=== verifying essential endpoints ==="
for name in endpoint__http_status_45d__v1 endpoint__tcp_status_45d__v1 endpoint__dns_status_45d__v0; do
  if tb pipe ls 2>/dev/null | grep -q "$name"; then
    log "PRESENT $name"
  else
    log "MISSING $name"
  fi
done

log "done. holding container open for log inspection."
sleep infinity
