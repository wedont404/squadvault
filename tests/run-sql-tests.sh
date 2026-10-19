#!/usr/bin/env bash
# Runs the SQL security tests against a THROWAWAY local Postgres (never your Supabase project).
#   usage: tests/run-sql-tests.sh "postgresql://user@host:port"      (server must allow creating databases)
set -euo pipefail
URL="${1:?usage: run-sql-tests.sh postgresql://user@host:port}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DB="sv_test_$$"
psql "$URL/postgres" -q -c "create database $DB"
trap 'psql "$URL/postgres" -q -c "drop database if exists $DB" >/dev/null' EXIT
run() { psql "$URL/$DB" -q -v ON_ERROR_STOP=1 -f "$1" 2>&1 | grep -v -i notice || true; }
psql "$URL/$DB" -q -v ON_ERROR_STOP=1 -f "$HERE/sql/supabase_stub.sql"
psql "$URL/$DB" -q -v ON_ERROR_STOP=1 -f "$HERE/sql/existing_schema.sql"
for f in "$HERE"/../supabase/migrations/*.sql; do psql "$URL/$DB" -q -v ON_ERROR_STOP=1 -f "$f" 2>&1 | grep -v -i notice || true; done
psql "$URL/$DB" -v ON_ERROR_STOP=1 -f "$HERE/sql/security.test.sql" 2>&1 | grep -v -i notice
