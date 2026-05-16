#!/usr/bin/env python3
"""
fastText language detection for name:XX tags.

Checks that each name:XX tag contains text in the expected language XX.
Mismatches (e.g. name:uk containing Russian text) are written to
validation_flags with source='fasttext', flag_type='name_lang_mismatch'.

Checks city and state tables only — highest signal, manageable row count.
Street/natural_feature can be added but city+state already catch the
most impactful vandalism cases.

Usage:
    ./fasttext_validator.py <CC> [CC ...]

Dependencies:
    pip install fasttext psycopg2

Environment variables (same as restore.sh):
    PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE

The lid.176.bin model (126 MB) is downloaded once to ./cache/ on first run.
"""

import sys
import os
import urllib.request

MODEL_URL = 'https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.bin'
MODEL_PATH = os.path.join(os.path.dirname(__file__), 'cache', 'lid.176.bin')

# ISO 639-1 codes that fastText recognises and that appear as name:XX in OSM.
KNOWN_LANGS = {
    'af','sq','ar','hy','az','eu','be','bn','bs','bg','ca','zh','hr','cs',
    'da','nl','en','et','fi','fr','gl','ka','de','el','gu','he','hi','hu',
    'is','id','ga','it','ja','kn','kk','ko','lv','lt','mk','ms','ml','mt',
    'mr','mn','no','fa','pl','pt','ro','ru','sr','sk','sl','es','sw','sv',
    'ta','te','th','tr','uk','ur','vi',
}

MIN_NAME_LEN   = 5    # shorter names are unreliable for language detection
CONF_THRESHOLD = 0.7  # minimum fastText confidence to trust the prediction


def ensure_model() -> str:
    if not os.path.exists(MODEL_PATH):
        os.makedirs(os.path.dirname(MODEL_PATH), exist_ok=True)
        print(f'Downloading fastText lid model to {MODEL_PATH} ...')
        urllib.request.urlretrieve(MODEL_URL, MODEL_PATH)
        print('Download complete.')
    return MODEL_PATH


def check_tags(tags: dict, model) -> list[tuple[str, str]]:
    """
    Returns list of (tag_key, detected_lang) for name:XX tags whose
    detected language doesn't match the expected language XX.
    """
    mismatches = []
    for key, value in tags.items():
        if not key.startswith('name:') or not value:
            continue
        lang_code = key[5:]
        if lang_code not in KNOWN_LANGS:
            continue
        if len(value) < MIN_NAME_LEN:
            continue
        labels, probs = model.predict(value.replace('\n', ' '), k=1)
        detected = labels[0].replace('__label__', '')
        confidence = float(probs[0])
        if confidence >= CONF_THRESHOLD and detected != lang_code:
            mismatches.append((key, f'{detected} ({confidence:.2f})'))
    return mismatches


def validate_country(cur, model, cc: str) -> int:
    cur.execute("""
        SELECT internal_id, tags
        FROM city
        WHERE country_code = %s AND tags IS NOT NULL
        UNION ALL
        SELECT internal_id, tags
        FROM state
        WHERE country_code = %s AND tags IS NOT NULL
    """, (cc, cc))
    rows = cur.fetchall()
    print(f'  {len(rows)} city+state rows')

    flags = []
    for internal_id, tags in rows:
        for tag_key, detected in check_tags(tags, model):
            flags.append((internal_id, cc, 'fasttext', 'name_lang_mismatch', tag_key, detected))

    if flags:
        cur.executemany("""
            INSERT INTO validation_flags
                (internal_id, country_code, source, flag_type, old_value, new_value)
            VALUES (%s, %s, %s, %s, %s, %s)
        """, flags)

    print(f'  {len(flags)} language mismatches flagged')
    return len(flags)


def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <CC> [CC ...]', file=sys.stderr)
        sys.exit(1)

    try:
        import fasttext
    except ImportError:
        print('fasttext not installed. Run: pip install fasttext', file=sys.stderr)
        sys.exit(1)

    try:
        import psycopg2
        import psycopg2.extras
    except ImportError:
        print('psycopg2 not installed. Run: pip install psycopg2', file=sys.stderr)
        sys.exit(1)

    model_path = ensure_model()
    print(f'Loading model from {model_path} ...')
    model = fasttext.load_model(model_path)

    conn = psycopg2.connect(
        host=os.environ.get('PGHOST', 'localhost'),
        port=int(os.environ.get('PGPORT', 5432)),
        user=os.environ.get('PGUSER', 'postgres'),
        password=os.environ.get('PGPASSWORD', 'secret'),
        dbname=os.environ.get('PGDATABASE', 'gis'),
    )
    psycopg2.extras.register_hstore(conn)
    conn.autocommit = False

    total = 0
    for cc in sys.argv[1:]:
        cc = cc.upper()
        print(f'=== {cc} ===')
        with conn.cursor() as cur:
            total += validate_country(cur, model, cc)
        conn.commit()

    conn.close()
    print(f'Total: {total} flags written')


if __name__ == '__main__':
    main()
