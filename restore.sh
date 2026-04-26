#!/bin/bash
# Restores an osm_addresses_<CC> dump into the production gis database.
# data_source is excluded from the dump (dropped in osm_addresses_extractor.sql),
# so other countries' data is not affected.
#
# Usage:
#   ./restore.sh <CC> [CC ...]
#
# Example (from storage server directly):
#   ./restore.sh UA
#   ./restore.sh UA DE PL
#   HOST=localhost PORT=5432 USER=postgres PGPASSWORD=secret ./restore.sh DE

set -e

if [ $# -lt 1 ]; then
    echo "Usage: ./restore.sh <CC> [CC ...]"
    exit 1
fi

HOST="${HOST:-localhost}"
PORT="${PORT:-5432}"
USER="${USER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-secret}"

for CC in "$@"; do
    CC="${CC^^}"
    DUMP_DIR="$(dirname "$0")/results/osm_addresses_${CC}"

    if [ ! -d "$DUMP_DIR" ]; then
        echo "ERROR: dump not found: $DUMP_DIR"
        exit 1
    fi

    echo "=== Restoring $CC into gis@$HOST:$PORT ==="
    echo "Cleaning existing $CC rows..."
    psql -h "$HOST" -p "$PORT" -U "$USER" -d gis -c "
        DO \$\$ BEGIN
          IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'building') THEN
            DELETE FROM building WHERE country_code = '$CC';
            DELETE FROM street   WHERE country_code = '$CC';
            DELETE FROM city     WHERE country_code = '$CC';
            DELETE FROM state    WHERE country_code = '$CC';
            DELETE FROM country  WHERE country_code = '$CC';
          END IF;
        END \$\$;"

    pg_restore --data-only --disable-triggers \
        -h "$HOST" -p "$PORT" -U "$USER" -d gis \
        --exclude-table=external_id_seq \
        -j 4 "$DUMP_DIR"

    echo "Row counts after $CC restore:"
    psql -h "$HOST" -p "$PORT" -U "$USER" -d gis -c \
        "SELECT 'country' AS tbl, COUNT(*) FROM country
         UNION ALL SELECT 'state',    COUNT(*) FROM state
         UNION ALL SELECT 'city',     COUNT(*) FROM city
         UNION ALL SELECT 'street',   COUNT(*) FROM street
         UNION ALL SELECT 'building', COUNT(*) FROM building;"

    echo "=== $CC restore done ==="
done
