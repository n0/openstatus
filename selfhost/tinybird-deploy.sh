#!/bin/sh
# Provision the local Tinybird (Classic, COMPATIBILITY_MODE=1) container with the
# OpenStatus data project so the status-page uptime endpoints exist and the
# checker's ingested ping/tcp/dns events flow through the materialized views.
#
# All output is tee'd to a shared volume (/shared/deploy.log) so the local-scheduler
# container (whose logs Coolify surfaces) can echo it for inspection.

LOGFILE=/shared/tinybird-deploy.log
mkdir -p /shared 2>/dev/null

run() {
  set -u
  TB_HOST="${TINYBIRD_URL:-http://tinybird:7181}"
  PROJECT_DIR="${PROJECT_DIR:-/project}"
  TOKEN="${TB_TOKEN:-}"

  log() { echo "[tinybird-deploy] $*"; }

  cd "$PROJECT_DIR" || { log "FATAL: cannot cd to $PROJECT_DIR"; return 1; }
  log "project: datasources=$(ls datasources 2>/dev/null | wc -l) pipes=$(ls pipes 2>/dev/null | wc -l) endpoints=$(ls endpoints 2>/dev/null | wc -l)"

  # Wait for Tinybird, gating on a successful auth with the workspace token.
  i=0
  until tb auth --host "$TB_HOST" --token "$TOKEN" >/tmp/auth.out 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 80 ]; then
      log "FATAL: tb auth never succeeded against $TB_HOST"
      sed 's/^/   auth| /' /tmp/auth.out | tail -n 10
      return 1
    fi
    log "waiting for tinybird/auth at $TB_HOST ... ($i)"
    sleep 3
  done
  log "authenticated against $TB_HOST"

  # Repair tcp_response__v0 when it was auto-created without the requestStatus
  # column (checker sends it with `omitempty`). Without that column every tcp
  # aggregate fails to materialize and the tcp status MV stays empty. We drop the
  # tcp chain and recreate it from the datafile with the correct schema.
  if tb sql "SELECT requestStatus FROM tcp_response__v0 LIMIT 0" >/tmp/chk.out 2>&1; then
    log "tcp_response__v0 already has requestStatus; no repair needed"
  else
    log "=== repairing tcp_response__v0 (missing requestStatus) ==="
    log "  guard check said: $(tail -n 1 /tmp/chk.out)"
    # Drop the tcp materialized-view pipes so they don't block the ALTER, then add
    # the missing columns in place. `tb push --force` still prompts interactively for
    # schema changes (ADD COLUMN ...), so feed the confirmation on stdin. The columns
    # are nullable, so existing rows get NULL; the recreated matviews below only
    # process NEW inserts, so the mv is not polluted by the old null-status rows.
    for f in pipes/*.pipe endpoints/*.pipe; do
      grep -q 'tcp_response__v0' "$f" 2>/dev/null || continue
      name=$(basename "$f" .pipe)
      tb pipe rm "$name" --yes >/tmp/rm.out 2>&1 && log "  dropped pipe $name" || true
    done
    if printf 'y\ny\n' | tb push datasources/tcp_response__v0.datasource --force >/tmp/repair.out 2>&1; then
      log "  altered tcp_response__v0 (added requestStatus/id)"
    else
      log "  alter tcp_response__v0 result:"
      sed 's/^/      | /' /tmp/repair.out | tail -n 14
    fi
    log "  post-repair schema check: $(tb sql 'SELECT requestStatus FROM tcp_response__v0 LIMIT 0' >/tmp/chk2.out 2>&1 && echo OK-has-requestStatus || tail -n 1 /tmp/chk2.out)"
  fi

  OK=0; FAIL=0; FAILED_FILES=""
  push() {
    f="$1"; [ -f "$f" ] || return 0
    if tb push "$f" --force >"/tmp/push.out" 2>&1; then
      OK=$((OK + 1)); log "OK   $f"
    else
      FAIL=$((FAIL + 1)); FAILED_FILES="$FAILED_FILES $f"; log "FAIL $f"
      sed 's/^/      | /' /tmp/push.out | tail -n 6
    fi
  }

  log "=== pushing datasources ==="
  for f in datasources/*.datasource; do push "$f"; done
  log "=== pushing pipes (materialized aggregates) ==="
  for f in pipes/*.pipe; do push "$f"; done
  log "=== pushing endpoints ==="
  for f in endpoints/*.pipe; do push "$f"; done

  log "============ SUMMARY ============"
  log "pushed OK: $OK   failed: $FAIL"
  [ -n "$FAILED_FILES" ] && log "failed files:$FAILED_FILES"
  for name in endpoint__http_status_45d__v1 endpoint__tcp_status_45d__v1 endpoint__dns_status_45d__v0; do
    tb pipe ls 2>/dev/null | grep -q "$name" && log "PRESENT $name" || log "MISSING $name"
  done
  log "DONE"
}

run 2>&1 | tee "$LOGFILE"
echo "[tinybird-deploy] holding container open" | tee -a "$LOGFILE"
sleep infinity
