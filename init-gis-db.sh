#!/bin/bash
# Initializes the destination GIS database on storage.
# Run once before the first pg_restore.
#
# Usage:
#   ./init-gis-db.sh [host] [port] [user]
#
# Defaults: host=storage.service, port=5432, user=postgres

set -e

HOST="${1:-storage.service}"
PORT="${2:-5432}"
USER="${3:-postgres}"

echo "Connecting to $HOST:$PORT as $USER"

psql -h "$HOST" -p "$PORT" -U "$USER" postgres -c \
  "CREATE DATABASE gis ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8' TEMPLATE template0;"

psql -h "$HOST" -p "$PORT" -U "$USER" gis <<'SQL'
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE IF NOT EXISTS validation_flags (
    id           BIGSERIAL   PRIMARY KEY,
    internal_id  BIGINT      NOT NULL,
    country_code CHAR(2)     NOT NULL,
    source       TEXT        NOT NULL,
    flag_type    TEXT        NOT NULL,
    old_value    TEXT,
    new_value    TEXT,
    detected_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_vf_internal_id ON validation_flags (internal_id);
CREATE INDEX IF NOT EXISTS idx_vf_detected    ON validation_flags (detected_at DESC);
SQL

echo "Database 'gis' ready on $HOST:$PORT"
echo ""
echo "To restore a dump (directory format, 4 parallel jobs):"
echo "  pg_restore -Fd -j 4 -h $HOST -p $PORT -U $USER -d gis --no-owner --no-privileges <dump_dir>"
