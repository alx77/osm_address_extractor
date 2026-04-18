#!/bin/bash
# Restores an osm_addresses_<CC> dump into the production gis database.
# data_source is excluded from the dump (dropped in osm_addresses_extractor.sql),
# so other countries' data is not affected.
#
# Usage:
#   ./restore.sh <CC> [host] [port] [user]
#
# Example (from storage server directly):
#   ./restore.sh UA
#   PGPASSWORD=secret ./restore.sh DE localhost 5432 postgres

set -e

CC="${1:?Usage: ./restore.sh <CC> [host] [port] [user]}"
CC="${CC^^}"
HOST="${2:-localhost}"
PORT="${3:-5432}"
USER="${4:-postgres}"
export PGPASSWORD="${PGPASSWORD:-secret}"
DUMP_DIR="$(dirname "$0")/results/osm_addresses_${CC}"

if [ ! -d "$DUMP_DIR" ]; then
    echo "ERROR: dump not found: $DUMP_DIR"
    exit 1
fi

echo "=== Restoring $CC into gis@$HOST:$PORT ==="

pg_restore --data-only --disable-triggers \
    -h "$HOST" -p "$PORT" -U "$USER" -d gis \
    -j 4 "$DUMP_DIR"

echo "Row counts:"
psql -h "$HOST" -p "$PORT" -U "$USER" -d gis -c \
    "SELECT 'country' AS tbl, COUNT(*) FROM country
     UNION ALL SELECT 'state',    COUNT(*) FROM state
     UNION ALL SELECT 'city',     COUNT(*) FROM city
     UNION ALL SELECT 'street',   COUNT(*) FROM street
     UNION ALL SELECT 'building', COUNT(*) FROM building;"

echo "=== $CC restore done ==="
