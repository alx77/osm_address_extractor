#!/bin/bash
# Usage: /extract.sh <geofabrik_path> <COUNTRY_CODE>
# Runs inside the Docker container. Uses a single 'gis' database per container.
# Produces /results/osm_addresses_<CC> (directory-format pg_dump).

set -e

FILENAME=$(basename -- "$1")
CACHE_FILE="/cache/$FILENAME"
CACHE_MAX_DAYS=3

if [ -f "$CACHE_FILE" ]; then
    CACHE_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$CACHE_FILE") ) / 86400 ))
    if [ "$CACHE_AGE_DAYS" -lt "$CACHE_MAX_DAYS" ]; then
        echo "using cached $FILENAME (${CACHE_AGE_DAYS}d old)"
        cp "$CACHE_FILE" .
    else
        echo "cache is ${CACHE_AGE_DAYS}d old, re-downloading..."
        wget -q "http://download.geofabrik.de/$1" && cp "$FILENAME" "$CACHE_FILE"
    fi
else
    echo "downloading $1..."
    wget -q "http://download.geofabrik.de/$1" && cp "$FILENAME" "$CACHE_FILE"
fi

echo "ensuring gis user..."
psql -U postgres -tc "SELECT 1 FROM pg_roles WHERE rolname='gis'" | grep -q 1 \
    || createuser -U postgres gis

echo "ensuring gis database..."
psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname='gis'" | grep -q 1 \
    || createdb -U postgres -E UTF8 -O gis gis

echo "installing extensions..."
psql -U postgres -d gis -c "CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS hstore; CREATE EXTENSION IF NOT EXISTS pg_show_plans;"

FILTERED="${FILENAME%.osm.pbf}-filtered.osm.pbf"
echo "filtering PBF with osmium (roads, buildings, admin, addresses)..."
time osmium tags-filter "$FILENAME" \
    r/type=associatedStreet \
    r/type=street \
    wa/building \
    nw/place \
    wa/boundary=administrative \
    w/highway \
    w/railway=rail,tram,light_rail,subway,narrow_gauge,preserved,funicular,monorail,disused \
    w/man_made=pier,groyne \
    n/addr:housenumber \
    -o "$FILTERED" --overwrite

echo "importing $1 into gis..."
time /imposm3/imposm import \
    -connection postgis://gis:secret@localhost/gis \
    -mapping imposm3/mapping.yaml \
    -read "$FILTERED" -write -overwritecache
rm -f "$FILTERED"

echo "extracting addresses for $2..."
time psql -U postgres -d gis -f ./osm_addresses_extractor.sql

echo "exporting results to /results/osm_addresses_$2..."
rm -rf "/results/osm_addresses_$2"
time pg_dump -Fd -j 4 -U postgres -d gis \
    -T lines -T spatial_ref_sys \
    -f "/results/osm_addresses_$2"
chmod -R 755 "/results/osm_addresses_$2"
echo "done: $2"
