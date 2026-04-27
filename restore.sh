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

    CC_LOWER="${CC,,}"

    echo "=== Restoring $CC into gis@$HOST:$PORT ==="
    echo "Preparing partitions and cleaning existing $CC rows..."
    psql -h "$HOST" -p "$PORT" -U "$USER" -d gis -c "
        DO \$\$ BEGIN
          -- street partition: drop and recreate (instant, no table scan)
          IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'street_${CC_LOWER}') THEN
            EXECUTE 'ALTER TABLE street DETACH PARTITION street_${CC_LOWER}';
            EXECUTE 'DROP TABLE street_${CC_LOWER}';
          END IF;
          EXECUTE 'CREATE TABLE street_${CC_LOWER} PARTITION OF street FOR VALUES IN (''$CC'')';

          -- building partition: drop and recreate (instant)
          IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'building_${CC_LOWER}') THEN
            EXECUTE 'ALTER TABLE building DETACH PARTITION building_${CC_LOWER}';
            EXECUTE 'DROP TABLE building_${CC_LOWER}';
          END IF;
          EXECUTE 'CREATE TABLE building_${CC_LOWER} PARTITION OF building FOR VALUES IN (''$CC'')';

          -- non-partitioned tables: plain DELETE by country_code
          IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'city') THEN
            DELETE FROM city    WHERE country_code = '$CC';
            DELETE FROM state   WHERE country_code = '$CC';
            DELETE FROM country WHERE country_code = '$CC';
          END IF;
        END \$\$;"

    # Build a filtered TOC list, excluding external_id_seq entries
    # (sequence may be present in old dumps; the sequence does not exist on prod)
    TOC_FILE="$(mktemp)"
    pg_restore -l "$DUMP_DIR" | grep -v 'external_id_seq' > "$TOC_FILE"

    pg_restore --data-only --disable-triggers \
        -h "$HOST" -p "$PORT" -U "$USER" -d gis \
        --use-list="$TOC_FILE" \
        -j 4 "$DUMP_DIR"

    rm -f "$TOC_FILE"

    echo "Row counts after $CC restore:"
    psql -h "$HOST" -p "$PORT" -U "$USER" -d gis -c \
        "SELECT 'country'         AS tbl, COUNT(*) FROM country
         UNION ALL SELECT 'state',          COUNT(*) FROM state
         UNION ALL SELECT 'city',           COUNT(*) FROM city
         UNION ALL SELECT 'street',         COUNT(*) FROM street
         UNION ALL SELECT 'building',       COUNT(*) FROM building
         UNION ALL SELECT 'natural_feature',COUNT(*) FROM natural_feature;"

    echo "=== $CC restore done ==="
done
