#!/bin/sh
# Provision the local Tinybird (Classic, COMPATIBILITY_MODE=1) container with the
# OpenStatus data project so the status-page uptime endpoints exist and the
# checker's ingested ping/tcp/dns events flow through the materialized views.
#
# Idempotent and tolerant: each datafile is pushed independently with --force so a
# single bad/non-essential file never blocks the rest. Required chain for the
# public status bars:
#   ping_response__v8 -> aggregate__http_status_45d__v1 -> mv__http_status_45d__v1 -> endpoint__http_status_45d__v1
# (and the tcp/dns equivalents).
#
# The data project files are baked into the image at /project (see
# selfhost/tinybird-deploy.Dockerfile) so they are guaranteed present.

set -u

TB_HOST="${TINYBIRD_URL:-http://tinybird:7181}"
PROJECT_DIR="${PROJECT_DIR:-/project}"
TOKEN="${TB_TOKEN:-}"   # equals TB_LOCAL_WORKSPACE_TOKEN, the workspace admin token

log() { echo "[tinybird-deploy] $*"; }

cd "$PROJECT_DIR" || { log "FATAL: cannot cd to $PROJECT_DIR"; sleep infinity; }

log "project contents: datasources=$(ls datasources 2>/dev/null | wc -l) pipes=$(ls pipes 2>/dev/null | wc -l) endpoints=$(ls endpoints 2>/dev/null | wc -l)"

# 1. Wait for Tinybird to be ready by retrying auth with the known workspace token.
i=0
until tb auth --host "$TB_HOST" --token "$TOKEN" >/tmp/auth.out 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 80 ]; then
    log "FATAL: tb auth never succeeded against $TB_HOST"
    sed 's/^/[tinybird-deploy]   auth| /' /tmp/auth.out | tail -n 10
    sleep infinity
  fi
  log "waiting for tinybird/auth at $TB_HOST ... ($i)"
  sleep 3
done
log "authenticated against $TB_HOST"

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

# 2. Push in dependency order: datasources, then materialized pipes, then endpoints.
log "=== pushing datasources ==="
for f in datasources/*.datasource; do push "$f"; done

log "=== pushing pipes (materialized aggregates) ==="
for f in pipes/*.pipe; do push "$f"; done

log "=== pushing endpoints ==="
for f in endpoints/*.pipe; do push "$f"; done

log "================ SUMMARY ================"
log "pushed OK: $OK   failed: $FAIL"
[ -n "$FAILED_FILES" ] && log "failed files:$FAILED_FILES"

# 3. Verify the essential status-bar endpoints exist.
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
