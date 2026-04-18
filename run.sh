#!/bin/bash
# Usage: ./run.sh [CC [CC ...]]
#   CC = country code(s), e.g.: ./run.sh UA DE PL
#   No args = interactive dialog to pick one country.
#
# Each country is extracted in a fresh Docker container with a clean 'gis' database
# and produces an independent dump: results/osm_addresses_<CC>
# OSM IDs are globally unique, so dumps can be restored to production independently.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

declare -A COUNTRY_URLS=(
    ["IL"]="asia/israel-and-palestine-latest.osm.pbf"
    ["AL"]="europe/albania-latest.osm.pbf"
    ["AD"]="europe/andorra-latest.osm.pbf"
    ["AT"]="europe/austria-latest.osm.pbf"
    ["BY"]="europe/belarus-latest.osm.pbf"
    ["BE"]="europe/belgium-latest.osm.pbf"
    ["BG"]="europe/bulgaria-latest.osm.pbf"
    ["HR"]="europe/croatia-latest.osm.pbf"
    ["CZ"]="europe/czech-republic-latest.osm.pbf"
    ["DK"]="europe/denmark-latest.osm.pbf"
    ["FI"]="europe/finland-latest.osm.pbf"
    ["FR"]="europe/france-latest.osm.pbf"
    ["GE"]="europe/georgia-latest.osm.pbf"
    ["DE"]="europe/germany-latest.osm.pbf"
    ["GB"]="europe/great-britain-latest.osm.pbf"
    ["GR"]="europe/greece-latest.osm.pbf"
    ["HU"]="europe/hungary-latest.osm.pbf"
    ["IT"]="europe/italy-latest.osm.pbf"
    ["LV"]="europe/latvia-latest.osm.pbf"
    ["LT"]="europe/lithuania-latest.osm.pbf"
    ["LU"]="europe/luxembourg-latest.osm.pbf"
    ["MD"]="europe/moldova-latest.osm.pbf"
    ["MC"]="europe/monaco-latest.osm.pbf"
    ["ME"]="europe/montenegro-latest.osm.pbf"
    ["NL"]="europe/netherlands-latest.osm.pbf"
    ["NO"]="europe/norway-latest.osm.pbf"
    ["PL"]="europe/poland-latest.osm.pbf"
    ["PT"]="europe/portugal-latest.osm.pbf"
    ["RO"]="europe/romania-latest.osm.pbf"
    ["RU"]="europe/russia-latest.osm.pbf"
    ["RS"]="europe/serbia-latest.osm.pbf"
    ["SK"]="europe/slovakia-latest.osm.pbf"
    ["SI"]="europe/slovenia-latest.osm.pbf"
    ["ES"]="europe/spain-latest.osm.pbf"
    ["SE"]="europe/sweden-latest.osm.pbf"
    ["CH"]="europe/switzerland-latest.osm.pbf"
    ["TR"]="europe/turkey-latest.osm.pbf"
    ["UA"]="europe/ukraine-latest.osm.pbf"
)

# Per-country ID offsets (50M slots, u32-safe up to country #85).
# IDs within each slot: 1..50_000_000 (streets + buildings independently).
declare -A COUNTRY_OFFSETS=(
    ["DE"]=0          ["UA"]=50000000   ["PL"]=100000000
    ["FR"]=150000000  ["GB"]=200000000  ["IT"]=250000000
    ["ES"]=300000000  ["RU"]=350000000  ["TR"]=400000000
    ["NL"]=450000000  ["BE"]=500000000  ["AT"]=550000000
    ["CH"]=600000000  ["CZ"]=650000000  ["HU"]=700000000
    ["RO"]=750000000  ["BY"]=800000000  ["SE"]=850000000
    ["NO"]=900000000  ["FI"]=950000000  ["DK"]=1000000000
    ["SK"]=1050000000 ["HR"]=1100000000 ["RS"]=1150000000
    ["BG"]=1200000000 ["GR"]=1250000000 ["PT"]=1300000000
    ["LT"]=1350000000 ["LV"]=1400000000 ["MD"]=1450000000
    ["SI"]=1500000000 ["AL"]=1550000000 ["ME"]=1600000000
    ["GE"]=1650000000 ["IL"]=1700000000 ["AD"]=1750000000
    ["MC"]=1800000000 ["LU"]=1850000000
)

pick_country_interactive() {
    local OPTIONS=()
    for CC in "${!COUNTRY_URLS[@]}"; do
        OPTIONS+=("$CC" "$CC")
    done
    dialog --clear --title "Select country" \
        --menu "Choose a country:" 25 40 20 \
        "${OPTIONS[@]}" 2>&1 >/dev/tty
}

# Resolve country list
if [ $# -gt 0 ]; then
    COUNTRIES=("$@")
else
    COUNTRIES=("$(pick_country_interactive)")
    clear
fi

# Download imposm3 binary if not present (cached in project root, never re-downloaded)
IMPOSM_ARCHIVE="$SCRIPT_DIR/imposm-0.14.2-linux-x86-64.tar.gz"
IMPOSM_URL="https://github.com/omniscale/imposm3/releases/download/v0.14.2/imposm-0.14.2-linux-x86-64.tar.gz"
if [ ! -f "$IMPOSM_ARCHIVE" ]; then
    echo "Downloading imposm3 v0.14.2..."
    wget -q --show-progress -O "$IMPOSM_ARCHIVE" "$IMPOSM_URL"
fi

# Build image once
echo "Building postgres-extractor image (--no-cache)..."
docker build --no-cache -t postgres-extractor "$SCRIPT_DIR"

mkdir -p "$SCRIPT_DIR/cache" "$SCRIPT_DIR/results"

# Extract each country in a fresh container
for CC in "${COUNTRIES[@]}"; do
    CC="${CC^^}"  # uppercase
    URL="${COUNTRY_URLS[$CC]:-}"
    if [ -z "$URL" ]; then
        echo "Unknown country code: $CC (skipping)"
        continue
    fi

    CONTAINER="postgres-extractor-${CC,,}"
    echo ""
    echo "=== Extracting $CC ==="

    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm   "$CONTAINER" 2>/dev/null || true

    docker run --name "$CONTAINER" \
        -e POSTGRES_PASSWORD=secret \
        --shm-size=2g \
        -v "$SCRIPT_DIR/results":/results \
        -v "$SCRIPT_DIR/cache":/cache \
        -d postgres-extractor \
        postgres \
            -c shared_buffers=4GB \
            -c effective_cache_size=8GB \
            -c work_mem=512MB \
            -c maintenance_work_mem=2GB \
            -c max_parallel_workers_per_gather=4 \
            -c max_parallel_workers=8 \
            -c max_worker_processes=8 \
            -c checkpoint_completion_target=0.9 \
            -c wal_level=minimal \
            -c max_wal_senders=0 \
            -c synchronous_commit=off \
            -c shared_preload_libraries=pg_show_plans \
            -c pg_show_plans.plan_format=text

    # Wait for postgres inside container
    echo "Waiting for postgres..."
    until docker exec "$CONTAINER" pg_isready -U postgres -q; do sleep 1; done

    ID_OFFSET="${COUNTRY_OFFSETS[$CC]:-0}"
    docker exec "$CONTAINER" bash -c "/extract.sh $URL $CC $ID_OFFSET" \
        2>&1 | tee "$SCRIPT_DIR/results/extract_${CC}.log"

    echo "=== $CC done, dump at results/osm_addresses_${CC} ==="
done
