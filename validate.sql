-- validate.sql
-- Optional validation phase. Run after osm_addresses_extractor.sql completes.
-- Skip by setting SKIP_VALIDATION=1 in extract.sh.
--
-- Requires psql variables:
--   lang_primary   — ISO 639-1 code for the country's primary language (e.g. 'uk', 'de')
--                    Empty string disables the Wikidata name comparison.
--   country_code   — two-letter country code (e.g. 'UA')

-- ─── validation_status / validation_score ────────────────────────────────────
-- status: 0=ok  1=suspect  2=rejected
-- Rules applied to state, city, street, natural_feature (worst wins):
--   2: name has no alphabetic characters
--   1: name shorter than 3 chars, or contains ASCII control characters
--   1: city has no streets (ghost towns, mapping gaps, import errors)
DO $$
DECLARE
    name_rules  TEXT := $r$
        CASE
            WHEN NOT (name ~ '[[:alpha:]]') THEN 2
            WHEN LENGTH(name) < 3 OR name ~ E'[\\x01-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]' THEN 1
            ELSE 0
        END
    $r$;
    score_rules TEXT := $r$
        CASE
            WHEN NOT (name ~ '[[:alpha:]]') THEN 0.0
            WHEN LENGTH(name) < 3 OR name ~ E'[\\x01-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]' THEN 0.5
            ELSE 1.0
        END
    $r$;
BEGIN
    EXECUTE 'UPDATE state           SET validation_status = ' || name_rules || ', validation_score = ' || score_rules;
    EXECUTE 'UPDATE city            SET validation_status = ' || name_rules || ', validation_score = ' || score_rules;
    EXECUTE 'UPDATE street          SET validation_status = ' || name_rules || ', validation_score = ' || score_rules;
    EXECUTE 'UPDATE natural_feature SET validation_status = ' || name_rules || ', validation_score = ' || score_rules;
END $$;

UPDATE city SET validation_status = 1, validation_score = 0.5
WHERE validation_status = 0
  AND NOT EXISTS (SELECT 1 FROM street WHERE street.city_osm_id = city.osm_id);

-- ─── Wikidata name validation ─────────────────────────────────────────────────
-- Compare city names against Wikipedia article titles from the pre-loaded
-- wikimedia-importance dump. Flags cities where the OSM name differs from the
-- canonical title by more than 30% (levenshtein / max length).
-- Skipped when lang_primary is empty or wikipedia_article is unavailable.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'wikipedia_article')
       AND :'lang_primary' <> ''
    THEN
        INSERT INTO validation_flags
            (internal_id, country_code, source, flag_type, old_value, new_value)
        SELECT
            c.internal_id,
            c.country_code,
            'wikidata',
            'name_changed',
            c.name,
            w.title
        FROM city c
        JOIN wikipedia_article w
            ON c.tags->'wikidata' = w.wd_page_title
           AND w.language = :'lang_primary'
        WHERE c.internal_id IS NOT NULL
          AND c.name  IS NOT NULL AND c.name  <> ''
          AND w.title IS NOT NULL AND w.title <> ''
          AND levenshtein(lower(c.name), lower(w.title))
              > greatest(length(c.name), length(w.title)) * 0.3;
    END IF;
END $$;

-- Drop wikipedia tables — kept alive from main script for the comparison above.
DROP TABLE IF EXISTS wikipedia_article;
DROP TABLE IF EXISTS wikipedia_redirect;

-- ─── GeoNames name validation ─────────────────────────────────────────────────
-- For each city, find the nearest GeoNames populated place or admin area within
-- 10 km and flag if the names diverge by more than 35%.
-- Catches vandalism that slipped past the Wikidata check (small cities with no
-- Wikidata entry often have a GeoNames record). Skipped when the table is absent
-- (download failed or SKIP_VALIDATION=1).
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'geonames') THEN
        INSERT INTO validation_flags
            (internal_id, country_code, source, flag_type, old_value, new_value)
        SELECT
            c.internal_id,
            c.country_code,
            'geonames',
            'name_changed',
            c.name,
            g.name
        FROM city c
        JOIN LATERAL (
            SELECT name
            FROM geonames
            WHERE ST_DWithin(
                ST_SetSRID(ST_MakePoint(c.lon, c.lat), 4326)::geography,
                point::geography,
                10000
            )
              AND feature_code IN (
                'PPL','PPLA','PPLA2','PPLA3','PPLA4','PPLC','PPLX','PPLS',
                'ADM1','ADM2'
              )
            ORDER BY point <-> ST_SetSRID(ST_MakePoint(c.lon, c.lat), 4326)
            LIMIT 1
        ) g ON true
        WHERE c.internal_id IS NOT NULL
          AND c.name  IS NOT NULL AND c.name  <> ''
          AND (c.place IN ('city','town','village','hamlet','municipality')
               OR (c.admin_level IS NOT NULL AND c.admin_level::int <= 5))
          AND NOT lower(c.name) LIKE '%' || lower(g.name) || '%'
          AND levenshtein(lower(c.name), lower(g.name))
              > greatest(length(c.name), length(g.name)) * 0.35;
    END IF;
END $$;

DROP TABLE IF EXISTS geonames;
