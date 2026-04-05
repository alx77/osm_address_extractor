#!/bin/bash
FILENAME=$(basename -- $1)
CACHE_FILE="/cache/$FILENAME"
CACHE_MAX_DAYS=3

if [ -f "$CACHE_FILE" ]; then
    CACHE_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$CACHE_FILE") ) / 86400 ))
    if [ "$CACHE_AGE_DAYS" -lt "$CACHE_MAX_DAYS" ]; then
        echo "using cached $FILENAME (${CACHE_AGE_DAYS}d old)"
        cp "$CACHE_FILE" .
    else
        echo "cache is ${CACHE_AGE_DAYS}d old, re-downloading $1..."
        wget -q "http://download.geofabrik.de/$1" && cp "$FILENAME" "$CACHE_FILE"
    fi
else
    echo "downloading $1..."
    wget -q "http://download.geofabrik.de/$1" && cp "$FILENAME" "$CACHE_FILE"
fi
echo "creating user..."
createuser -U postgres gis
echo "creating database..."
createdb -U postgres -E UTF8 -O gis gis$2
echo "installing extensions to gis$2 database..."
su postgres -c "psql -U postgres -d gis$2 -c \"CREATE EXTENSION postgis;CREATE EXTENSION hstore;\""
echo "importing $1 to gis$2 database..."
time /imposm3/imposm import -connection postgis://gis:secret@localhost/gis$2 -mapping imposm3/mapping.yaml -read ${FILENAME} -write -overwritecache
echo "extracting addresses from gis$2 database, please wait, it can take a while..."
time su postgres -c "psql -U postgres -d gis$2 -f ./osm_addresses_extractor.sql"
echo "exporting results..."
time pg_dump -Fd -j 4 -U postgres -d gis$2 -T lines -T spatial_ref_sys -f /results/osm_addresses_$2
chmod -R 755 /results/osm_addresses_$2
