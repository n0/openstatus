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

# 1b. Repair: the checker auto-creates tcp_response__v0 from its first event, and
# because requestStatus is sent with `omitempty` it can be inferred WITHOUT the
# requestStatus column. That makes every tcp aggregate (which references
# requestStatus) fail to materialize, leaving the tcp status MV empty. A plain
# `tb push --force` can't add the column while dependent matviews exist, so we tear
# the tcp chain down and let the push below recreate it from the datafile with the
# correct schema. (Old rows lack requestStatus and would mis-render, so dropping
# them is intentional; the bars rebuild from new checks.) HTTP/DNS are healthy and
# left untouched.
repair_tcp() {
  if ! tb sql "SELECT requestStatus FROM tcp_response__v0 LIMIT 0" >/dev/null 2>&1; then
    log "=== repairing tcp_response__v0 (missing requestStatus column) ==="
    for f in pipes/*.pipe; do
      grep -q 'tcp_response__v0' "$f" 2>/dev/null || continue
      name=$(basename "$f" .pipe)
      tb pipe rm "$name" --yes >/dev/null 2>&1 && log "  dropped matview pipe $name" || true
    done
    tb datasource rm tcp_response__v0 --yes >/dev/null 2>&1 && log "  dropped tcp_response__v0" || log "  could not drop tcp_response__v0"
    # Recreate immediately to minimise the window where a checker event could
    # re-auto-create it with the bad inferred schema.
    if tb push datasources/tcp_response__v0.datasource --force >/tmp/repair.out 2>&1; then
      log "  recreated tcp_response__v0 from datafile"
    else
      log "  FAILED to recreate tcp_response__v0"
      sed 's/^/[tinybird-deploy]      | /' /tmp/repair.out | tail -n 10
    fi
  else
    log "tcp_response__v0 already has requestStatus; no repair needed"
  fi
}
repair_tcp

# 2. Push in dependency order: datasources, then materialized pipes, then endpoints.
log "=== pushing datasources ==="
for f in datasources/*.datasource; do push "$f"; done

log "=== pushing pipes (materialized aggregates) ==="
for f in pipes/*.pipe; do push "$f"; done

log "=== pushing endpoints ==="
for f in endpoints/*.pipe; do push "$f"; done

# Force-(re)materialize the status aggregate pipes and backfill from existing raw
# rows. A plain push only attaches the materialized view to NEW inserts; --populate
# backfills the rows that were ingested before the view existed, and re-running it
# repairs any aggregate whose initial materialization did not attach.
log "=== (re)materializing + populating status aggregates ==="
for f in \
  pipes/aggregate__http_status_45d__v1.pipe \
  pipes/aggregate__tcp_status_45d__v1.pipe \
  pipes/aggregate__dns_status_45d__v1.pipe ; do
  [ -f "$f" ] || { log "skip (missing) $f"; continue; }
  if tb push "$f" --force --populate --wait >"/tmp/pop.out" 2>&1; then
    log "POPULATED $f"
  else
    log "POPULATE-FAIL $f"
    sed 's/^/[tinybird-deploy]      | /' /tmp/pop.out | tail -n 12
  fi
done

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
