#!/bin/bash
# Usage: /extract.sh <geofabrik_path> <COUNTRY_CODE> [ID_OFFSET]
#   ID_OFFSET: integer base for compact street/building IDs (default 0).
#              Each country gets a 50M slot to avoid collisions:
#              DE=0, UA=50000000, PL=100000000, FR=150000000, ...
# Runs inside the Docker container. Uses a single 'gis' database per container.
# Produces /results/osm_addresses_<CC> (directory-format pg_dump).

set -e

FILENAME=$(basename -- "$1")
CACHE_FILE="/cache/$FILENAME"
CACHE_MAX_DAYS=7

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

WIKI_CACHE="/cache/wikimedia-importance.sql.gz"
WIKI_MAX_DAYS=30
WIKI_NEED_DOWNLOAD=1
if [ -f "$WIKI_CACHE" ] && gunzip -t "$WIKI_CACHE" 2>/dev/null; then
    WIKI_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$WIKI_CACHE") ) / 86400 ))
    if [ "$WIKI_AGE_DAYS" -lt "$WIKI_MAX_DAYS" ]; then
        echo "using cached wikimedia-importance.sql.gz (${WIKI_AGE_DAYS}d old)"
        WIKI_NEED_DOWNLOAD=0
    else
        echo "wikimedia-importance cache is ${WIKI_AGE_DAYS}d old, re-downloading..."
    fi
else
    [ -f "$WIKI_CACHE" ] && echo "cached wikimedia-importance.sql.gz is corrupted, re-downloading..."
fi
if [ "$WIKI_NEED_DOWNLOAD" = "1" ]; then
    wget -q --no-use-server-timestamps "https://nominatim.org/data/wikimedia-importance.sql.gz" -O "$WIKI_CACHE"
    gunzip -t "$WIKI_CACHE" || { echo "ERROR: wikimedia-importance.sql.gz download failed/corrupted"; rm -f "$WIKI_CACHE"; exit 1; }
fi
echo "loading wikimedia-importance into gis..."
gunzip -c "$WIKI_CACHE" | psql -U postgres -d gis -q

GEONAMES_CACHE="/cache/geonames_${2}.txt"
GEONAMES_MAX_DAYS=30
GEONAMES_OK=0
if [ -f "$GEONAMES_CACHE" ]; then
    GEONAMES_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$GEONAMES_CACHE") ) / 86400 ))
    if [ "$GEONAMES_AGE_DAYS" -lt "$GEONAMES_MAX_DAYS" ]; then
        echo "using cached GeoNames for $2 (${GEONAMES_AGE_DAYS}d old)"
        GEONAMES_OK=1
    else
        echo "GeoNames cache is ${GEONAMES_AGE_DAYS}d old, re-downloading..."
    fi
fi
if [ "$GEONAMES_OK" = "0" ]; then
    echo "downloading GeoNames for $2..."
    if wget -q "https://download.geonames.org/export/dump/${2}.zip" -O "/tmp/geonames_${2}.zip" \
       && unzip -p "/tmp/geonames_${2}.zip" "${2}.txt" > "$GEONAMES_CACHE"; then
        GEONAMES_OK=1
    else
        echo "WARNING: GeoNames download failed for $2, skipping..."
    fi
    rm -f "/tmp/geonames_${2}.zip"
fi

if [ "$GEONAMES_OK" = "1" ]; then
    echo "loading GeoNames for $2..."
    psql -U postgres -d gis <<EOF
CREATE UNLOGGED TABLE geonames_stage (
    geonameid      integer,
    name           text,
    asciiname      text,
    alternatenames text,
    lat            float8,
    lon            float8,
    feature_class  char(1),
    feature_code   text,
    country_code   char(2),
    cc2            text,
    admin1_code    text,
    admin2_code    text,
    admin3_code    text,
    admin4_code    text,
    population     bigint,
    elevation      integer,
    dem            integer,
    timezone       text,
    modification_date text
);
COPY geonames_stage FROM '${GEONAMES_CACHE}' WITH (FORMAT text, DELIMITER E'\t', NULL '');
CREATE UNLOGGED TABLE geonames AS
SELECT name, lat, lon, feature_class, feature_code, population,
       ST_SetSRID(ST_MakePoint(lon, lat), 4326) AS point
FROM geonames_stage
WHERE feature_class IN ('P', 'A')
  AND name IS NOT NULL AND name <> '';
DROP TABLE geonames_stage;
CREATE INDEX idx_geonames_point ON geonames USING gist (point);
ANALYZE geonames;
EOF
fi

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
    nwa/natural=peak,volcano,spring,cape,bay,water,island,wood,wetland,glacier \
    wa/waterway=river,canal,stream,drain \
    -o "$FILTERED" --overwrite

echo "importing $1 into gis..."
time /imposm3/imposm import \
    -connection postgis://gis:secret@localhost/gis \
    -mapping imposm3/mapping.yaml \
    -read "$FILTERED" -write -overwritecache
rm -f "$FILTERED"

ID_OFFSET="${3:-0}"

case "$2" in
    AL) LANG_PRIMARY="sq" ;; AD) LANG_PRIMARY="ca" ;; AT) LANG_PRIMARY="de" ;;
    BY) LANG_PRIMARY="be" ;; BE) LANG_PRIMARY="fr" ;; BG) LANG_PRIMARY="bg" ;;
    HR) LANG_PRIMARY="hr" ;; CZ) LANG_PRIMARY="cs" ;; DK) LANG_PRIMARY="da" ;;
    FI) LANG_PRIMARY="fi" ;; FR) LANG_PRIMARY="fr" ;; GE) LANG_PRIMARY="ka" ;;
    DE) LANG_PRIMARY="de" ;; GB) LANG_PRIMARY="en" ;; GR) LANG_PRIMARY="el" ;;
    HU) LANG_PRIMARY="hu" ;; IL) LANG_PRIMARY="he" ;; IT) LANG_PRIMARY="it" ;;
    LV) LANG_PRIMARY="lv" ;; LT) LANG_PRIMARY="lt" ;; LU) LANG_PRIMARY="fr" ;;
    MD) LANG_PRIMARY="ro" ;; MC) LANG_PRIMARY="fr" ;; ME) LANG_PRIMARY="sr" ;;
    NL) LANG_PRIMARY="nl" ;; NO) LANG_PRIMARY="no" ;; PL) LANG_PRIMARY="pl" ;;
    PT) LANG_PRIMARY="pt" ;; RO) LANG_PRIMARY="ro" ;; RU) LANG_PRIMARY="ru" ;;
    RS) LANG_PRIMARY="sr" ;; SK) LANG_PRIMARY="sk" ;; SI) LANG_PRIMARY="sl" ;;
    ES) LANG_PRIMARY="es" ;; SE) LANG_PRIMARY="sv" ;; CH) LANG_PRIMARY="de" ;;
    TR) LANG_PRIMARY="tr" ;; UA) LANG_PRIMARY="uk" ;; *)  LANG_PRIMARY=""   ;;
esac

echo "extracting addresses for $2 (id_offset=$ID_OFFSET)..."
time psql -U postgres -d gis \
    -v id_offset="$ID_OFFSET" \
    -v country_code="$2" \
    -v lang_primary="$LANG_PRIMARY" \
    -f ./osm_addresses_extractor.sql

if [ "${SKIP_VALIDATION:-0}" = "1" ]; then
    echo "skipping validation (SKIP_VALIDATION=1)..."
    psql -U postgres -d gis -c "
        DROP TABLE IF EXISTS wikipedia_article;
        DROP TABLE IF EXISTS wikipedia_redirect;
        DROP TABLE IF EXISTS geonames;
        DROP TABLE IF EXISTS geonames_stage;"
else
    echo "running validation for $2..."
    time psql -U postgres -d gis \
        -v lang_primary="$LANG_PRIMARY" \
        -v country_code="$2" \
        -f ./validate.sql
fi

echo "exporting results to /results/osm_addresses_$2..."
rm -rf "/results/osm_addresses_$2"
time pg_dump -Fd -j 4 -U postgres -d gis \
    -N import \
    -T lines -T spatial_ref_sys \
    -T wikipedia_article -T wikipedia_redirect \
    -T geonames -T geonames_stage \
    -f "/results/osm_addresses_$2"
chmod -R 755 "/results/osm_addresses_$2"
echo "done: $2"
