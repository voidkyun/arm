#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Requires PostgreSQL server/client binaries. Own cluster, own processes, no
# existing databases or roles touched. PostgreSQL 14+ and Python 3 are sufficient.
PG_BIN="${PG_BIN:-$(pg_config --bindir)}"
export PATH="$PG_BIN:$PATH"
work="$(mktemp -d "${TMPDIR:-/tmp}/arm-e2e.XXXXXX")"
log_dir="${ARM_E2E_LOG_DIR:-$work/logs}"
mkdir -p "$log_dir"
server_pid=""
readonly_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  if [[ -n "$readonly_pid" ]]; then kill "$readonly_pid" 2>/dev/null || true; wait "$readonly_pid" 2>/dev/null || true; fi
  if [[ -f "$work/data/postmaster.pid" ]]; then pg_ctl -D "$work/data" -m fast -w stop >> "$log_dir/postgres.log" 2>&1 || true; fi
  # Keep the fixture/logs for diagnosis; print its exact path rather than delete.
  printf 'E2E fixture: %s\nE2E logs: %s\n' "$work" "$log_dir"
}
trap cleanup EXIT
initdb_options=()
if [[ -n "${PG_SHARE:-}" ]]; then initdb_options=(-L "$PG_SHARE"); fi
initdb -D "$work/data" -U arm --auth=trust --encoding=UTF8 --no-locale "${initdb_options[@]}" > "$log_dir/initdb.log"
pg_ctl -D "$work/data" -l "$log_dir/postgres.log" -o "-h 127.0.0.1 -p ${ARM_TEST_PG_PORT:-55439} -k $work" -w start
export ARM_TEST_DATABASE_URL="host=127.0.0.1 port=${ARM_TEST_PG_PORT:-55439} dbname=arm_task user=arm"
createdb -h 127.0.0.1 -p "${ARM_TEST_PG_PORT:-55439}" -U arm arm_task
psql "$ARM_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f arm-example-task/sql/001-schema.sql -f arm-example-task/sql/002-seed.sql > "$log_dir/schema.log"
cabal build all -j2
"$(cabal list-bin task-sql-check)" | tee "$log_dir/sql-check.log"
export ARM_PORT="${ARM_TEST_HTTP_PORT:-18089}"
ARM_DATABASE_URL="$ARM_TEST_DATABASE_URL" "$(cabal list-bin arm-example-task:exe:arm-example-task)" > "$log_dir/http.log" 2>&1 &
server_pid=$!
ARM_OBSERVATIONS_ONLY=1 ARM_PORT="${ARM_TEST_READONLY_PORT:-18090}" ARM_DATABASE_URL="$ARM_TEST_DATABASE_URL options='-c default_transaction_read_only=on'" \
  "$(cabal list-bin arm-example-task:exe:arm-example-task)" > "$log_dir/readonly-http.log" 2>&1 &
readonly_pid=$!
ARM_TEST_READONLY_PORT="${ARM_TEST_READONLY_PORT:-18090}" python3 scripts/e2e.py | tee "$log_dir/http-check.log"
