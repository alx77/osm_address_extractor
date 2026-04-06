#!/bin/bash
# Restores an osm_addresses_<CC> dump into the production gis database.
# Truncates all data tables first so the restore is always idempotent.
#
# Usage:
#   ./restore.sh <CC> [host] [port] [user]
#
# Example (from storage server directly):
#   ./restore.sh UA
#   ./restore.sh DE storage.service 5432 postgres

set -e

CC="${1:?Usage: ./restore.sh <CC> [host] [port] [user]}"
CC="${CC^^}"
HOST="${2:-localhost}"
PORT="${3:-5432}"
USER="${4:-postgres}"
DUMP_DIR="$(dirname "$0")/results/osm_addresses_${CC}"

if [ ! -d "$DUMP_DIR" ]; then
    echo "ERROR: dump not found: $DUMP_DIR"
    exit 1
fi

echo "=== Restoring $CC into gis@$HOST:$PORT ==="

echo "Truncating tables..."
psql -h "$HOST" -p "$PORT" -U "$USER" -d gis -c \
    "TRUNCATE building, geocompleter_changelog, street, city, state, country, data_source CASCADE;"

echo "Restoring dump (sequential, --data-only)..."
pg_restore --data-only --disable-triggers \
    -h "$HOST" -p "$PORT" -U "$USER" -d gis \
    -j 1 "$DUMP_DIR"

echo "Row counts:"
psql -h "$HOST" -p "$PORT" -U "$USER" -d gis -c \
    "SELECT 'country' AS tbl, COUNT(*) FROM country
     UNION ALL SELECT 'state',    COUNT(*) FROM state
     UNION ALL SELECT 'city',     COUNT(*) FROM city
     UNION ALL SELECT 'street',   COUNT(*) FROM street
     UNION ALL SELECT 'building', COUNT(*) FROM building;"

echo "=== $CC restore done ==="
