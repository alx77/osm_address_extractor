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

# Build image once
if [[ "$(docker images -q postgres-extractor 2>/dev/null)" == "" ]]; then
    echo "Building postgres-extractor image..."
    docker build -t postgres-extractor "$SCRIPT_DIR"
fi

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
            -c synchronous_commit=off

    # Wait for postgres inside container
    echo "Waiting for postgres..."
    until docker exec "$CONTAINER" pg_isready -U postgres -q; do sleep 1; done

    docker exec "$CONTAINER" bash -c "/extract.sh $URL $CC" \
        2>&1 | tee "$SCRIPT_DIR/results/extract_${CC}.log"

    echo "=== $CC done, dump at results/osm_addresses_${CC} ==="
done
