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
SQL

echo "Database 'gis' ready on $HOST:$PORT"
echo ""
echo "To restore a dump (directory format, 4 parallel jobs):"
echo "  pg_restore -Fd -j 4 -h $HOST -p $PORT -U $USER -d gis --no-owner --no-privileges <dump_dir>"
