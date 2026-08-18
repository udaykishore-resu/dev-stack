#!/bin/sh
# Create the two application roles and databases.
#
# WHERE THIS RUNS
#   The postgres:17-alpine entrypoint executes everything in
#   /docker-entrypoint-initdb.d exactly once, when the data directory is empty.
#   The image has BusyBox ash, not bash, so this file is strict POSIX sh:
#   no `[[`, no arrays, no `local`, no process substitution.
#
#   Consequence worth knowing: on an existing pgdata volume this file is NOT
#   re-run.  If you add a role here later, either `make clean` (destroys data)
#   or run the equivalent SQL by hand.  See docs/RUNBOOK.md.
#
# IDEMPOTENCY
#   The entrypoint only runs it once, but people also run it by hand and some
#   CI images replay initdb scripts.  Every statement is therefore guarded.
#   Guards use the psql `\gexec` trick rather than a `DO $$ ... $$` block:
#   psql does NOT interpolate :'variables' inside dollar-quoted strings, so a
#   DO block would receive the literal text `:'role'` and fail to parse.
#   CREATE DATABASE additionally cannot run inside a transaction or a DO body.
#
# AUTH
#   password_encryption is pinned to scram-sha-256 for the duration of each
#   psql session so roles get SCRAM verifiers even if the server default is
#   md5.  The container also passes --auth-host=scram-sha-256 to initdb (see
#   docker-compose.yml), which writes a matching pg_hba.conf.

set -eu

: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_DB:=postgres}"

: "${GS_DB_USER:=guestscore}"
: "${GS_DB_PASSWORD:=guestscore}"
: "${GS_DB_NAME:=guestscore}"

: "${MM_DB_USER:=marketmate}"
: "${MM_DB_PASSWORD:=marketmate}"
: "${MM_DB_NAME:=marketmate}"

echo "init: creating application roles and databases"

psql_super() {
    psql -v ON_ERROR_STOP=1 --no-psqlrc --username "$POSTGRES_USER" "$@"
}

# ---------------------------------------------------------------------------
# Roles.  LOGIN plus a password and nothing else: neither app needs CREATEDB,
# CREATEROLE or SUPERUSER, and handing those out locally teaches habits that
# fail a production review.
#
# The unconditional ALTER on the second statement keeps the password in sync
# with .env, which is what people expect after changing GS_DB_PASSWORD.
# format(%I/%L) does the quoting so a password containing a quote is safe.
# ---------------------------------------------------------------------------
create_role() {
    psql_super --dbname "$POSTGRES_DB" --set=role="$1" --set=password="$2" <<'SQL'
SET password_encryption = 'scram-sha-256';

SELECT format('CREATE ROLE %I WITH LOGIN PASSWORD %L', :'role', :'password')
WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = :'role')
\gexec

SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'role', :'password')
\gexec
SQL
}

# ---------------------------------------------------------------------------
# Databases.  Owned by the application role so the app can create its own
# schema objects on boot (GS_MIGRATE / MM_MIGRATE run embedded migrations).
#
# REVOKE ... FROM PUBLIC stops either app from connecting to the other's
# database: the two tenants share a server, not a trust boundary.
# ---------------------------------------------------------------------------
create_database() {
    dbname="$1"
    owner="$2"

    psql_super --dbname "$POSTGRES_DB" --set=dbname="$dbname" --set=owner="$owner" <<'SQL'
SELECT format('CREATE DATABASE %I OWNER %I', :'dbname', :'owner')
WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_database WHERE datname = :'dbname')
\gexec
SQL

    psql_super --dbname "$POSTGRES_DB" --set=dbname="$dbname" --set=owner="$owner" <<'SQL'
ALTER DATABASE :"dbname" OWNER TO :"owner";
REVOKE ALL ON DATABASE :"dbname" FROM PUBLIC;
GRANT ALL PRIVILEGES ON DATABASE :"dbname" TO :"owner";
SQL

    # The public schema stopped being world-writable in PG 15; the owner still
    # needs it explicitly for migrations that do `CREATE TABLE public.x`.
    psql_super --dbname "$dbname" --set=owner="$owner" <<'SQL'
ALTER SCHEMA public OWNER TO :"owner";
GRANT ALL ON SCHEMA public TO :"owner";
REVOKE ALL ON SCHEMA public FROM PUBLIC;
SQL
}

create_role "$GS_DB_USER" "$GS_DB_PASSWORD"
create_role "$MM_DB_USER" "$MM_DB_PASSWORD"

create_database "$GS_DB_NAME" "$GS_DB_USER"
create_database "$MM_DB_NAME" "$MM_DB_USER"

echo "init: done - databases: $GS_DB_NAME (owner $GS_DB_USER), $MM_DB_NAME (owner $MM_DB_USER)"
