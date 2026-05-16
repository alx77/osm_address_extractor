#!/usr/bin/env python3
"""
Wikidata cross-validation for city names.

Fetches canonical city labels from Wikidata SPARQL and compares them against
OSM names stored in the production DB. Discrepancies are written to
validation_flags with source='wikidata'.

Only cities with a wikidata=Q... tag in OSM are checked — coverage is ~90%
for cities with population > 20k, near-zero for small villages.

Usage:
    ./wikidata_validator.py <CC> [CC ...]

Environment variables (same as restore.sh):
    PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE
"""

import sys
import os
import time
import difflib
import psycopg2
import requests

COUNTRY_LANGS = {
    'AL': 'sq', 'AD': 'ca', 'AT': 'de', 'BY': 'be', 'BE': 'fr',
    'BG': 'bg', 'HR': 'hr', 'CZ': 'cs', 'DK': 'da', 'FI': 'fi',
    'FR': 'fr', 'GE': 'ka', 'DE': 'de', 'GB': 'en', 'GR': 'el',
    'HU': 'hu', 'IL': 'he', 'IT': 'it', 'LV': 'lv', 'LT': 'lt',
    'LU': 'fr', 'MD': 'ro', 'MC': 'fr', 'ME': 'sr', 'NL': 'nl',
    'NO': 'no', 'PL': 'pl', 'PT': 'pt', 'RO': 'ro', 'RU': 'ru',
    'RS': 'sr', 'SK': 'sk', 'SI': 'sl', 'ES': 'es', 'SE': 'sv',
    'CH': 'de', 'TR': 'tr', 'UA': 'uk',
}

SPARQL_URL = 'https://query.wikidata.org/sparql'
BATCH_SIZE = 100
# Cities whose name similarity to Wikidata label falls below this are flagged.
# 0.7 tolerates transliteration variants and minor spelling differences.
SIMILARITY_THRESHOLD = 0.7


def fetch_labels(qids: list[str], lang: str) -> dict[str, str]:
    values = ' '.join(f'wd:{q}' for q in qids)
    query = f"""
    SELECT ?item ?label WHERE {{
      VALUES ?item {{ {values} }}
      ?item rdfs:label ?label .
      FILTER(LANG(?label) = "{lang}")
    }}
    """
    resp = requests.get(
        SPARQL_URL,
        params={'query': query, 'format': 'json'},
        headers={'User-Agent': 'osm-address-extractor/1.0 (https://github.com/ideaficus)'},
        timeout=30,
    )
    resp.raise_for_status()
    return {
        row['item']['value'].rsplit('/', 1)[-1]: row['label']['value']
        for row in resp.json()['results']['bindings']
    }


def similarity(a: str, b: str) -> float:
    return difflib.SequenceMatcher(None, a.lower(), b.lower()).ratio()


def validate_country(cur, cc: str) -> int:
    lang = COUNTRY_LANGS.get(cc, 'en')

    cur.execute("""
        SELECT internal_id, name, tags->'wikidata'
        FROM city
        WHERE country_code = %s
          AND tags->'wikidata' IS NOT NULL
          AND name IS NOT NULL AND name <> ''
    """, (cc,))
    cities = cur.fetchall()
    print(f'  {len(cities)} cities with wikidata QIDs')

    flags = []
    for i in range(0, len(cities), BATCH_SIZE):
        batch = cities[i:i + BATCH_SIZE]
        qids = [row[2] for row in batch]
        try:
            labels = fetch_labels(qids, lang)
        except requests.RequestException as e:
            print(f'  SPARQL error (batch {i // BATCH_SIZE + 1}): {e}', file=sys.stderr)
            time.sleep(5)
            continue

        for internal_id, osm_name, qid in batch:
            wd_name = labels.get(qid)
            if wd_name is None:
                continue
            if similarity(osm_name, wd_name) < SIMILARITY_THRESHOLD:
                flags.append((internal_id, cc, 'wikidata', 'name_changed', osm_name, wd_name))

        time.sleep(0.5)

    if flags:
        cur.executemany("""
            INSERT INTO validation_flags
                (internal_id, country_code, source, flag_type, old_value, new_value)
            VALUES (%s, %s, %s, %s, %s, %s)
        """, flags)

    print(f'  {len(flags)} discrepancies flagged')
    return len(flags)


def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <CC> [CC ...]', file=sys.stderr)
        sys.exit(1)

    conn = psycopg2.connect(
        host=os.environ.get('PGHOST', 'localhost'),
        port=int(os.environ.get('PGPORT', 5432)),
        user=os.environ.get('PGUSER', 'postgres'),
        password=os.environ.get('PGPASSWORD', 'secret'),
        dbname=os.environ.get('PGDATABASE', 'gis'),
    )
    conn.autocommit = False

    total = 0
    for cc in sys.argv[1:]:
        cc = cc.upper()
        print(f'=== {cc} ===')
        with conn.cursor() as cur:
            total += validate_country(cur, cc)
        conn.commit()

    conn.close()
    print(f'Total: {total} flags written')


if __name__ == '__main__':
    main()
