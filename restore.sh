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
          -- building partition must be dropped before street (FK dependency)
          IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'building_${CC_LOWER}') THEN
            EXECUTE 'ALTER TABLE building DETACH PARTITION building_${CC_LOWER}';
            EXECUTE 'DROP TABLE building_${CC_LOWER}';
          END IF;
          EXECUTE 'CREATE TABLE building_${CC_LOWER} PARTITION OF building FOR VALUES IN (''$CC'')';

          -- street partition: drop and recreate (instant, no table scan)
          IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'street_${CC_LOWER}') THEN
            EXECUTE 'ALTER TABLE street DETACH PARTITION street_${CC_LOWER}';
            EXECUTE 'DROP TABLE street_${CC_LOWER}';
          END IF;
          EXECUTE 'CREATE TABLE street_${CC_LOWER} PARTITION OF street FOR VALUES IN (''$CC'')';

          -- non-partitioned tables: plain DELETE by country_code
          IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'city') THEN
            DELETE FROM natural_feature WHERE country_code = '$CC';
            DELETE FROM city            WHERE country_code = '$CC';
            DELETE FROM state           WHERE country_code = '$CC';
            DELETE FROM country         WHERE country_code = '$CC';
          END IF;
        END \$\$;"

    # Build a filtered TOC list: exclude tables restored separately via ON CONFLICT DO NOTHING
    # (border objects share osm_ids / internal_ids across countries)
    TOC_FILE="$(mktemp)"
    pg_restore -l "$DUMP_DIR" \
        | grep -v 'external_id_seq' \
        | grep -v 'TABLE DATA public natural_feature' \
        | grep -v 'TABLE DATA public alias_osm' \
        | grep -v 'TABLE DATA public object_registry' \
        > "$TOC_FILE"

    pg_restore --data-only --disable-triggers \
        -h "$HOST" -p "$PORT" -U "$USER" -d gis \
        --use-list="$TOC_FILE" \
        -j 4 "$DUMP_DIR"

    rm -f "$TOC_FILE"

    # Restore natural_feature via staging: pg_restore uses COPY internally which
    # doesn't support ON CONFLICT, so we dump to SQL, redirect COPY to a staging
    # table (no PK), then INSERT ... ON CONFLICT DO NOTHING into the real table.
    echo "Restoring natural_feature (ON CONFLICT DO NOTHING)..."
    NF_SQL="$(mktemp --suffix=.sql)"
    pg_restore --data-only --table=natural_feature -f "$NF_SQL" "$DUMP_DIR" 2>/dev/null || true
    if [ -s "$NF_SQL" ]; then
        psql -h "$HOST" -p "$PORT" -U "$USER" -d gis -c \
            "DROP TABLE IF EXISTS natural_feature_stage;
             CREATE UNLOGGED TABLE natural_feature_stage (LIKE natural_feature);"
        sed 's/COPY public\.natural_feature /COPY public.natural_feature_stage /' "$NF_SQL" | \
            psql -h "$HOST" -p "$PORT" -U "$USER" -d gis
        psql -h "$HOST" -p "$PORT" -U "$USER" -d gis -c \
            "INSERT INTO natural_feature SELECT * FROM natural_feature_stage ON CONFLICT (osm_id) DO NOTHING;
             DROP TABLE natural_feature_stage;"
    fi
    rm -f "$NF_SQL"

    # Restore object_registry with ON CONFLICT DO NOTHING (border objects have same internal_id across countries)
    echo "Restoring object_registry (ON CONFLICT DO NOTHING)..."
    OR_SQL="$(mktemp --suffix=.sql)"
    pg_restore --data-only --table=object_registry -f "$OR_SQL" "$DUMP_DIR" 2>/dev/null || true
    if [ -s "$OR_SQL" ]; then
        psql -h "$HOST" -p "$PORT" -U "$USER" -d gis -c \
            "DROP TABLE IF EXISTS object_registry_stage;
             CREATE UNLOGGED TABLE object_registry_stage (LIKE object_registry);"
        sed 's/COPY public\.object_registry /COPY public.object_registry_stage /' "$OR_SQL" | \
            psql -h "$HOST" -p "$PORT" -U "$USER" -d gis
        psql -h "$HOST" -p "$PORT" -U "$USER" -d gis -c \
            "INSERT INTO object_registry SELECT * FROM object_registry_stage ON CONFLICT (internal_id) DO NOTHING;
             DROP TABLE object_registry_stage;"
    fi
    rm -f "$OR_SQL"

    # Restore alias_osm with ON CONFLICT DO NOTHING (border osm_ids appear in multiple countries)
    echo "Restoring alias_osm (ON CONFLICT DO NOTHING)..."
    AO_SQL="$(mktemp --suffix=.sql)"
    pg_restore --data-only --table=alias_osm -f "$AO_SQL" "$DUMP_DIR" 2>/dev/null || true
    if [ -s "$AO_SQL" ]; then
        psql -h "$HOST" -p "$PORT" -U "$USER" -d gis -c \
            "DROP TABLE IF EXISTS alias_osm_stage;
             CREATE UNLOGGED TABLE alias_osm_stage (LIKE alias_osm INCLUDING ALL);"
        sed 's/COPY public\.alias_osm /COPY public.alias_osm_stage /' "$AO_SQL" | \
            psql -h "$HOST" -p "$PORT" -U "$USER" -d gis
        psql -h "$HOST" -p "$PORT" -U "$USER" -d gis -c \
            "INSERT INTO alias_osm SELECT * FROM alias_osm_stage ON CONFLICT (osm_id) DO NOTHING;
             DROP TABLE alias_osm_stage;"
    fi
    rm -f "$AO_SQL"

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
