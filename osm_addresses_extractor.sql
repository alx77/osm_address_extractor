-- osm_addresses_extractor.sql
-- Runs INSIDE the Docker extractor container against a fresh 'gis' database.
-- DO NOT run against a production gis DB:
--   - Tables are created UNLOGGED (data loss on crash without pg_dump)
--   - session_replication_role=replica disables all triggers
-- The changelog trigger belongs in geocompleter-rs/postgres/create.sql
-- and lives only in the production database.

-- ─── Session tuning ──────────────────────────────────────────────────────────
SET work_mem = '512MB';
SET maintenance_work_mem = '1GB';
SET max_parallel_workers_per_gather = 4;
-- Uncomment when running under Podman rootless (kernel DSM limits in user ns):
-- SET max_parallel_workers_per_gather = 0;

\timing on

-- ─── Input variables ─────────────────────────────────────────────────────────
-- Passed via psql -v:  psql -v id_offset=50000000 -v country_code=UA ...
\set country_code :country_code

-- ─── Extensions ──────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;

-- ─── Schema — no PKs, no FKs, no secondary indexes ───────────────────────────
-- UNLOGGED TABLE IF NOT EXISTS: created UNLOGGED on a fresh Docker container
-- (no WAL → fastest possible inserts). IF NOT EXISTS is a no-op on production.
-- PKs, FKs and all indexes are built in one bulk pass AFTER all data is loaded —
-- bulk index builds are 2-3x faster than per-row B-tree maintenance during INSERT.

CREATE UNLOGGED TABLE IF NOT EXISTS data_source (
    id   smallint,
    name text NOT NULL UNIQUE
);
INSERT INTO data_source (id, name) VALUES (1, 'osm') ON CONFLICT DO NOTHING;

-- ─── Object registry — stable IDs across extractions ─────────────────────────
-- object_registry is PERSISTENT: dumped with the data and restored into
-- production so internal_id never changes between reloads.
-- alias_osm maps osm_id → internal_id for fast bulk lookup during import.
-- Other sources will get their own alias_* tables (alias_here, alias_custom, …).
CREATE UNLOGGED TABLE IF NOT EXISTS object_registry (
    internal_id BIGSERIAL PRIMARY KEY,
    object_type TEXT        NOT NULL,  -- 'street', 'city', 'state', 'country', 'building', 'natural_feature'
    deleted_at  TIMESTAMPTZ            -- soft delete; internal_id is never reused
);

CREATE UNLOGGED TABLE IF NOT EXISTS alias_osm (
    osm_id      BIGINT NOT NULL PRIMARY KEY,
    internal_id BIGINT NOT NULL REFERENCES object_registry
);

CREATE UNLOGGED TABLE IF NOT EXISTS country (
    osm_id      bigint,
    internal_id bigint,
    name        text,
    tags        hstore,
    way         geometry(Geometry, 4326),
    lon         float8,
    lat         float8,
    country_code text,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    deleted_at  timestamptz
);

CREATE UNLOGGED TABLE IF NOT EXISTS state (
    osm_id            bigint,
    internal_id       bigint,
    name              text,
    country_osm_id    bigint,
    tags              hstore,
    way               geometry(Geometry, 4326),
    lon               float8,
    lat               float8,
    country_code      text,
    validation_status smallint NOT NULL DEFAULT 0,
    validation_score  real     NOT NULL DEFAULT 1.0,
    updated_at        timestamptz NOT NULL DEFAULT now(),
    deleted_at        timestamptz
);

CREATE UNLOGGED TABLE IF NOT EXISTS city (
    osm_id            bigint,
    internal_id       bigint,
    name              text,
    place             text,
    postal_code       text,
    tags              hstore,
    admin_level       integer,
    state_osm_id      bigint,
    district_osm_id   bigint,
    importance        float8,
    way_origin        geometry(Geometry, 3857),
    way               geometry(Geometry, 4326),
    lon               float8,
    lat               float8,
    country_code      text,
    validation_status smallint NOT NULL DEFAULT 0,
    validation_score  real     NOT NULL DEFAULT 1.0,
    updated_at        timestamptz NOT NULL DEFAULT now(),
    deleted_at        timestamptz
);

CREATE UNLOGGED TABLE IF NOT EXISTS postcode (
    osm_id       bigint,
    internal_id  bigint,
    postal_code  text NOT NULL,
    way          geometry(Geometry, 4326),
    lon          float8,
    lat          float8,
    country_code text,
    state_osm_id bigint
);

CREATE UNLOGGED TABLE IF NOT EXISTS natural_feature (
    osm_id            bigint,
    internal_id       bigint,
    name              text,
    tags              hstore,
    type              text,
    way               geometry(Geometry, 4326),
    lon               float8,
    lat               float8,
    state_osm_id      bigint,
    city_osm_id       bigint,
    country_code      text,
    importance        float8,
    validation_status smallint NOT NULL DEFAULT 0,
    validation_score  real     NOT NULL DEFAULT 1.0,
    updated_at        timestamptz NOT NULL DEFAULT now(),
    deleted_at        timestamptz
);

CREATE UNLOGGED TABLE IF NOT EXISTS street (
    id                integer,          -- compact surrogate PK (GeoHash order, assigned at end)
    internal_id       bigint,           -- stable external ID from object_registry
    osm_id            bigint,           -- min(osm_id) of the cluster; NULL for non-OSM sources
    name              text NOT NULL,
    city_osm_id       bigint,
    rel_osm_ids       bigint[],
    osm_ids           bigint[],
    city_area         float8,
    tags              hstore,
    importance        float8,
    postcodes         text[],          -- all postcodes from buildings, sorted by frequency (postcodes[1] = most common)
    way               geometry(Geometry, 4326),
    way_3857          geometry,        -- temp column for building spatial join; dropped at end
    lon               float8,
    lat               float8,
    country_code      text,
    source_id         smallint NOT NULL DEFAULT 1,
    source_ref        text,
    validation_status smallint NOT NULL DEFAULT 0,
    validation_score  real     NOT NULL DEFAULT 1.0,
    updated_at        timestamptz NOT NULL DEFAULT now(),
    deleted_at        timestamptz
);

CREATE UNLOGGED TABLE IF NOT EXISTS building (
    id           integer,          -- compact surrogate PK (GeoHash order, assigned at end)
    internal_id  bigint,           -- stable external ID from object_registry
    osm_id       bigint,           -- min(osm_id) of the cluster; NULL for non-OSM sources
    street_id    integer,          -- FK → street.id (compact)
    osm_ids      bigint[],
    housenumber  text,
    postcode     text,
    way          geometry(Geometry, 4326),
    lon          float8,
    lat          float8,
    country_code text,
    source_id    smallint NOT NULL DEFAULT 1,
    source_ref   text,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    deleted_at   timestamptz
);

CREATE UNLOGGED TABLE IF NOT EXISTS validation_flags (
    id           BIGSERIAL   PRIMARY KEY,
    internal_id  BIGINT      NOT NULL,
    country_code CHAR(2)     NOT NULL,
    source       TEXT        NOT NULL,
    flag_type    TEXT        NOT NULL,
    old_value    TEXT,
    new_value    TEXT,
    detected_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ─── Bulk load: disable triggers ─────────────────────────────────────────────
SET session_replication_role = replica;

-- ─── Indexes on raw import tables ────────────────────────────────────────────
DROP INDEX IF EXISTS import.idx_osm_associated_streets_tags;
CREATE INDEX idx_osm_associated_streets_tags
    ON import.osm_associated_streets USING GIN (tags);

DROP INDEX IF EXISTS import.idx_osm_associated_streets_member;
CREATE INDEX idx_osm_associated_streets_member
    ON import.osm_associated_streets (member_osm_id, role);

DROP INDEX IF EXISTS import.idx_osm_housenumbers_street;
CREATE INDEX idx_osm_housenumbers_street
    ON import.osm_housenumbers ("addr:street");

DROP INDEX IF EXISTS import.idx_osm_buildings_street;
CREATE INDEX idx_osm_buildings_street
    ON import.osm_buildings ("addr:street");

-- Partial GiST index for the building→street spatial join (branch 2).
-- Without this PostgreSQL chooses hash join with full seq scan of 7.5M rows.
-- With this it uses nested loop: for each street find nearby buildings spatially,
-- then filter by name — much cheaper when addr:street selectivity is <30%.
DROP INDEX IF EXISTS import.idx_osm_buildings_way_addr;
CREATE INDEX idx_osm_buildings_way_addr
    ON import.osm_buildings USING gist (way)
    WHERE "addr:street" IS NOT NULL AND "addr:street" <> '' AND housenumber <> '';

-- Partial GiST index for housenumber nodes → street spatial join (branch 4).
DROP INDEX IF EXISTS import.idx_osm_housenumbers_way_addr;
CREATE INDEX idx_osm_housenumbers_way_addr
    ON import.osm_housenumbers USING gist (way)
    WHERE "addr:street" IS NOT NULL AND "addr:street" <> '' AND type IS NOT NULL;

DROP INDEX IF EXISTS import.idx_osm_admin_level;
CREATE INDEX idx_osm_admin_level
    ON import.osm_admin (admin_level);

DROP INDEX IF EXISTS import.idx_osm_admin_place;
CREATE INDEX idx_osm_admin_place
    ON import.osm_admin (place);

-- ─── country ─────────────────────────────────────────────────────────────────
INSERT INTO country (osm_id, name, tags, way, lon, lat)
SELECT
    osm_id,
    name,
    tags,
    ST_Transform(way, 4326),
    ST_X(ST_Transform(ST_Centroid(way), 4326)),
    ST_Y(ST_Transform(ST_Centroid(way), 4326))
FROM import.osm_admin
WHERE admin_level = 2
ORDER BY ST_Area(way) DESC
LIMIT 1;

UPDATE country
SET country_code = :'country_code';

-- Final GiST index — used both for spatial join below and kept in the dump.
CREATE INDEX idx_country_way_geo ON country USING gist (way);
ANALYZE country;

-- ─── state ───────────────────────────────────────────────────────────────────
INSERT INTO state (osm_id, name, country_osm_id, tags, way, lon, lat)
SELECT DISTINCT ON (sta.osm_id)
    sta.osm_id,
    sta.name,
    country.osm_id,
    sta.tags,
    ST_Transform(sta.way, 4326),
    ST_X(ST_Transform(ST_Centroid(sta.way), 4326)),
    ST_Y(ST_Transform(ST_Centroid(sta.way), 4326))
FROM import.osm_admin sta
JOIN country ON ST_Contains(country.way, ST_Transform(sta.way, 4326))
WHERE sta.place = 'state' OR sta.admin_level = 4;

UPDATE state
SET country_code = :'country_code';

-- Final GiST index — used both for spatial join below and kept in the dump.
CREATE INDEX idx_state_way_geo ON state USING gist (way);
ANALYZE state;

-- ─── city ─────────────────────────────────────────────────────────────────────
INSERT INTO city (osm_id, name, place, postal_code, tags, admin_level,
                  state_osm_id, way_origin, way, lon, lat)
SELECT DISTINCT ON (cit.osm_id)
    cit.osm_id,
    cit.name,
    cit.place,
    cit.postal_code,
    cit.tags,
    cit.admin_level,
    state.osm_id,
    cit.way,
    ST_Transform(cit.way, 4326),
    ST_X(ST_Transform(ST_Centroid(cit.way), 4326)),
    ST_Y(ST_Transform(ST_Centroid(cit.way), 4326))
FROM import.osm_admin cit
JOIN state ON ST_Covers(state.way, ST_Transform(cit.way, 4326))
WHERE cit.admin_level >= 6 OR cit.place IN ('city','hamlet','town','village');

UPDATE city
SET country_code = :'country_code';

-- Final GiST indexes — used both for spatial join below and kept in the dump.
CREATE INDEX idx_city_way_geo    ON city USING gist (way);
CREATE INDEX idx_city_way_origin ON city USING gist (way_origin);
ANALYZE city;

-- ─── city: place polygons without boundary=administrative ────────────────────
-- Relations/ways tagged place=city/town/village/hamlet but without
-- boundary=administrative are missed by the osm_admin import. Examples:
-- Краматорськ, Ясногірка (Ukraine) — real multipolygon boundaries, just tagged
-- differently. Import them directly with their real geometry.
INSERT INTO city (osm_id, name, place, postal_code, tags, admin_level,
                  state_osm_id, way_origin, way, lon, lat, country_code)
SELECT DISTINCT ON (p.osm_id)
    p.osm_id,
    p.name,
    p.type                                                       AS place,
    p.tags->'postal_code'                                        AS postal_code,
    p.tags,
    (p.tags->'admin_level')::int                                 AS admin_level,
    state.osm_id                                                 AS state_osm_id,
    ST_Transform(p.way, 3857)                                    AS way_origin,
    ST_Transform(p.way, 4326)                                    AS way,
    ST_X(ST_Transform(ST_Centroid(p.way), 4326))                 AS lon,
    ST_Y(ST_Transform(ST_Centroid(p.way), 4326))                 AS lat,
    :'country_code'                                              AS country_code
FROM import.osm_place_areas p
JOIN state ON ST_Contains(state.way, ST_Transform(ST_Centroid(p.way), 4326))
WHERE p.type IN ('city', 'town', 'village', 'hamlet')
  AND p.name IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM city c WHERE c.osm_id = p.osm_id)
ORDER BY p.osm_id, state.osm_id;

ANALYZE city;

-- ─── city: backfill point nodes that have no polygon in OSM ──────────────────
-- Some cities/towns/villages exist only as place=* point nodes with no admin
-- boundary polygon (e.g. Мерефа in Ukraine). Insert them using the smallest
-- enclosing polygon already in `city` (typically the hromada / Gemeinde) as
-- the boundary. Streets in surrounding villages that have their own place node
-- will still be correctly attributed to those villages via the place_order
-- priority in the fragments query (DISTINCT ON place_order ASC).
-- Skipped when a same-level city polygon already covers the point (place IS NOT NULL).
INSERT INTO city (osm_id, name, place, postal_code, tags, admin_level,
                  state_osm_id, way_origin, way, lon, lat, country_code)
SELECT DISTINCT ON (p.osm_id)
    p.osm_id,
    p.name,
    p.type                                                           AS place,
    p.tags->'postal_code'                                            AS postal_code,
    p.tags,
    (p.tags->'admin_level')::int                                     AS admin_level,
    state.osm_id                                                     AS state_osm_id,
    enclosing.way_origin,
    enclosing.way,
    ST_X(ST_Transform(p.way, 4326))                                  AS lon,
    ST_Y(ST_Transform(p.way, 4326))                                  AS lat,
    :'country_code'                                                  AS country_code
FROM import.osm_places p
JOIN state ON ST_Contains(state.way, ST_Transform(p.way, 4326))
JOIN LATERAL (
    SELECT c.way_origin, c.way
    FROM city c
    WHERE ST_Contains(c.way_origin, p.way)
    ORDER BY ST_Area(c.way_origin) ASC
    LIMIT 1
) enclosing ON true
WHERE p.type IN ('city', 'town', 'village', 'hamlet')
  AND p.name IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM city c
      WHERE ST_Contains(c.way_origin, p.way)
        AND c.place IS NOT NULL
  )
ORDER BY p.osm_id, state.osm_id;

ANALYZE city;

-- ─── postcode ────────────────────────────────────────────────────────────────
INSERT INTO postcode (osm_id, postal_code, way, lon, lat, country_code, state_osm_id)
SELECT p.osm_id,
       COALESCE(p.postal_code, p.tags->'postal_code') AS postal_code,
       ST_Transform(p.way, 4326)                       AS way,
       ST_X(ST_Transform(ST_Centroid(p.way), 4326))    AS lon,
       ST_Y(ST_Transform(ST_Centroid(p.way), 4326))    AS lat,
       :'country_code',
       s.osm_id                                        AS state_osm_id
FROM import.osm_postal_codes p
JOIN state s ON ST_Contains(s.way, ST_Transform(ST_Centroid(p.way), 4326))
WHERE COALESCE(p.postal_code, p.tags->'postal_code') IS NOT NULL;

ANALYZE postcode;

-- ─── district_osm_id: link sub-district cities to their rayon/Landkreis/powiat ─
-- Only for cities at admin_level > 7 (or no explicit admin_level but place tag).
-- Cities that ARE districts (admin_level <= 7) are skipped.
UPDATE city c
SET district_osm_id = d.osm_id
FROM city d
WHERE d.admin_level = 6
  AND c.osm_id != d.osm_id
  AND (c.admin_level > 7 OR (c.admin_level IS NULL AND c.place IN ('village','hamlet')))
  AND ST_Contains(d.way, ST_SetSRID(ST_MakePoint(c.lon, c.lat), 4326));

-- ─── lines (temp — only needed to build street, never exported) ───────────────
DROP TABLE IF EXISTS lines;
CREATE TEMP TABLE lines AS
WITH fragments AS materialized (
    SELECT
        r.osm_id,
        c.osm_id AS city_osm_id,
        r.name,
        (c.tags->'admin_level')::int AS admin_level,
        c.place,
        CASE c.place
            WHEN 'state'   THEN 1
            WHEN 'city'    THEN 2
            WHEN 'hamlet'  THEN 3
            WHEN 'town'    THEN 4
            WHEN 'village' THEN 5
            ELSE 6
        END AS place_order,
        r.tags,
        r.way,
        ST_X(ST_PointN(ST_ExteriorRing(ST_Envelope(r.way)),1)) AS leftx
    FROM import.osm_roads r
    JOIN city c ON ST_Contains(c.way_origin, r.way)
    WHERE type IN ('trunk','road','footway','primary','secondary','tertiary',
                   'primary_link','secondary_link','tertiary_link','construction',
                   'pedestrian','residential','track','steps','proposed',
                   'trunk_link','living_street','unclassified','unknown','motorway')
)
SELECT DISTINCT ON (osm_id) *
FROM fragments
ORDER BY osm_id, place_order ASC, admin_level DESC;

CREATE UNIQUE INDEX idx_lines_id ON lines (osm_id);
ALTER TABLE lines ADD CONSTRAINT pk_lines PRIMARY KEY USING INDEX idx_lines_id;
CREATE INDEX idx_lines_name_way ON lines USING gist(name, city_osm_id, admin_level, way);
ANALYZE lines;

-- ─── street ──────────────────────────────────────────────────────────────────
-- id = min(osm_id) across the cluster — globally unique, stable across dumps.
-- way_3857 populated directly from the cluster union (EPSG:3857 from osm_roads),
-- used for building spatial joins; dropped at the end.
INSERT INTO street (osm_id, name, rel_osm_ids, osm_ids, city_osm_id,
                    city_area, tags, way, way_3857, lon, lat)
WITH clusters AS materialized (
    SELECT
        ST_ClusterDBSCAN(way, eps := 1000, minpoints := 1) OVER (
            PARTITION BY name, city_osm_id
        ) AS cluster_id,
        osm_id, city_osm_id, name, way
    FROM lines
)
, street_groups AS materialized (
    SELECT
        row_number() OVER ()  AS _row,
        name,
        city_osm_id,
        min(osm_id)           AS min_osm_id,
        array_agg(osm_id)     AS osm_ids,
        ST_Union(way)         AS way
    FROM clusters
    GROUP BY name, city_osm_id, cluster_id
)
, street_unnested AS (
    SELECT sg._row, sg.name, sg.city_osm_id, sg.min_osm_id, sg.osm_ids, sg.way,
           unnest(sg.osm_ids) AS member_osm_id
    FROM street_groups sg
)
, street_rels AS (
    SELECT
        su._row, su.name, su.city_osm_id, su.min_osm_id, su.osm_ids, su.way,
        array_remove(array_agg(DISTINCT r.rel_osm_id), NULL) AS rel_osm_ids
    FROM street_unnested su
    LEFT JOIN import.osm_associated_streets r
        ON r.member_osm_id = su.member_osm_id
       AND r.name = su.name AND r.role = 'street'
    GROUP BY su._row, su.name, su.city_osm_id, su.min_osm_id, su.osm_ids, su.way
)
SELECT DISTINCT ON (sr.min_osm_id)
    sr.min_osm_id                                        AS osm_id,
    sr.name,
    sr.rel_osm_ids,
    sr.osm_ids,
    sr.city_osm_id,
    ST_Area(cit.way)                                     AS city_area,
    r.tags,
    ST_Transform(sr.way, 4326)                           AS way,
    sr.way                                               AS way_3857,
    ST_X(ST_Transform(ST_PointOnSurface(sr.way), 4326)) AS lon,
    ST_Y(ST_Transform(ST_PointOnSurface(sr.way), 4326)) AS lat
FROM street_rels sr
JOIN import.osm_roads r ON r.osm_id = sr.min_osm_id
JOIN city cit           ON cit.osm_id = sr.city_osm_id;

UPDATE street
SET country_code = :'country_code';

-- idx_street_way_3857: temp, dropped automatically when way_3857 column is dropped after building join.
-- The rest are final index names — built here once on bulk-loaded data (2-3x faster than per-row).
CREATE INDEX idx_street_way_3857    ON street USING gist (way_3857) WHERE way_3857 IS NOT NULL;
CREATE INDEX idx_street_name        ON street (name);
CREATE INDEX idx_street_rel_osm_ids ON street USING GIN (rel_osm_ids);
CREATE INDEX idx_street_city_osm_id ON street (city_osm_id);
ANALYZE street;

-- ─── importance ───────────────────────────────────────────────────────────────
-- Step 1: population-based fallback importance for all cities
UPDATE city
SET importance = LEAST(1.0,
    LN(GREATEST(100, COALESCE(
        NULLIF(regexp_replace(tags->'population', '[^0-9]', '', 'g'), '')::float,
        CASE place
            WHEN 'state'   THEN 2000000
            WHEN 'city'    THEN 500000
            WHEN 'town'    THEN 30000
            WHEN 'village' THEN 2000
            WHEN 'hamlet'  THEN 300
            ELSE                 5000
        END
    ))) / LN(10000000.0)
);

-- Step 2: override with Wikidata/Wikipedia pagerank where available
-- (wikimedia-importance.sql.gz loaded by extract.sh into wikipedia_article table)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'wikipedia_article') THEN
        UPDATE city c
        SET importance = COALESCE(w.importance, c.importance)
        FROM wikipedia_article w
        WHERE c.tags->'wikidata' = w.wd_page_title
          AND w.importance IS NOT NULL;
    ELSE
        RAISE NOTICE 'wikipedia_article table not found, skipping Wikidata importance override';
    END IF;
END $$;

-- Step 3: propagate city importance to streets
UPDATE street s
SET importance = c.importance
FROM city c
WHERE c.osm_id = s.city_osm_id;

-- Step 4: raise street importance to state floor (MAX(city.importance in state) * 0.8).
-- Streets in high-importance states (Berlin, Hamburg) should not rank below
-- streets in obscure cities that happen to have high borough-level importance.
UPDATE street s
SET importance = GREATEST(s.importance, sf.state_imp * 0.8)
FROM city c
JOIN (
    SELECT state_osm_id, MAX(importance) AS state_imp
    FROM city
    WHERE state_osm_id IS NOT NULL
    GROUP BY state_osm_id
) sf ON sf.state_osm_id = c.state_osm_id
WHERE c.osm_id = s.city_osm_id
  AND sf.state_imp * 0.8 > s.importance;

-- Spatial indexes for the natural_feature → state/city containment joins.
CREATE INDEX idx_state_way ON state USING gist (way);
CREATE INDEX idx_city_way  ON city  USING gist (way);

-- ─── natural_feature ─────────────────────────────────────────────────────────
-- Merged from osm_natural_points, osm_natural_areas, osm_waterways.
-- city_osm_id: set only when feature centroid is inside a city polygon (e.g. Труханів→Київ).
-- state_osm_id: from spatial join with state (oblast).
INSERT INTO natural_feature (osm_id, name, tags, type, way, lon, lat, state_osm_id, city_osm_id)
WITH raw AS (
    SELECT osm_id, name, tags, type,
           ST_Transform(way, 4326) AS way,
           ST_X(ST_Transform(ST_Centroid(way), 4326)) AS lon,
           ST_Y(ST_Transform(ST_Centroid(way), 4326)) AS lat
    FROM import.osm_natural_points
    WHERE name IS NOT NULL AND name <> ''
      AND type IN ('peak','volcano','glacier','cliff','cave_entrance',
                   'hot_spring','geyser','saddle','rock','stone','sinkhole')
    UNION ALL
    SELECT osm_id, name, tags, type,
           ST_Transform(way, 4326),
           ST_X(ST_Transform(ST_Centroid(way), 4326)),
           ST_Y(ST_Transform(ST_Centroid(way), 4326))
    FROM import.osm_natural_areas
    WHERE name IS NOT NULL AND name <> ''
      AND type IN ('water','bay','strait','lake','reservoir','island','islet',
                   'glacier','beach','peninsula','cape')
    UNION ALL
    SELECT osm_id, name, tags, type,
           ST_Transform(way, 4326),
           ST_X(ST_Transform(ST_Centroid(way), 4326)),
           ST_Y(ST_Transform(ST_Centroid(way), 4326))
    FROM import.osm_waterways
    WHERE name IS NOT NULL AND name <> ''
      AND type IN ('river','canal')
)
SELECT DISTINCT ON (r.osm_id)
    r.osm_id,
    r.name,
    r.tags,
    r.type,
    r.way,
    r.lon,
    r.lat,
    s.osm_id  AS state_osm_id,
    c.osm_id  AS city_osm_id
FROM raw r
LEFT JOIN state s   ON ST_Contains(s.way, ST_SetSRID(ST_MakePoint(r.lon, r.lat), 4326))
LEFT JOIN city  c   ON ST_Contains(c.way, ST_SetSRID(ST_MakePoint(r.lon, r.lat), 4326))
                   AND c.place IN ('city','town') AND c.importance >= 0.5;

UPDATE natural_feature
SET country_code = :'country_code';

-- importance: set BEFORE deduplication so geometry is still intact.
-- Points (peaks, volcanoes, glaciers) — individual geometry used directly.
-- Area features (lakes, islands) — area-based.
-- Rivers/canals — total length computed inside the dedup CTE below.
UPDATE natural_feature
SET importance = CASE
    WHEN type = 'water' THEN
        LEAST(1.0, 0.25 + LN(GREATEST(1.0,
            SQRT(ST_Area(way::geography) / 1000000.0)
        )) / 15.0)
    WHEN type = 'island' THEN
        LEAST(0.9, 0.25 + LN(GREATEST(1.0,
            SQRT(ST_Area(way::geography) / 1000000.0)
        )) / 15.0)
    WHEN type = 'peak' THEN
        LEAST(0.9, 0.2 + COALESCE(
            NULLIF(regexp_replace(tags->'ele', '[^0-9.]', '', 'g'), '')::float,
            500.0
        ) / 10000.0)
    WHEN type = 'volcano' THEN 0.55
    WHEN type = 'glacier' THEN 0.40
    ELSE                       0.20
END
WHERE type NOT IN ('river', 'canal');

-- override with Wikipedia/Wikidata importance where available
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'wikipedia_article') THEN
        UPDATE natural_feature nf
        SET importance = COALESCE(w.importance, nf.importance)
        FROM wikipedia_article w
        WHERE nf.tags->'wikidata' = w.wd_page_title
          AND w.importance IS NOT NULL;
    END IF;
END $$;

-- Deduplicate: rivers/canals/lakes are split into many OSM way segments.
-- Rivers: importance = total length of merged segments (computed here before way→point).
--   Rhein ~800km → 0.3 + ln(800)/15 ≈ 0.75   Elbe ~1100km → ≈ 0.78
--   small stream 5km  → 0.3 + ln(5)/15  ≈ 0.41
-- Other types: keep max(importance) already set above.
WITH groups AS (
    SELECT
        min(osm_id)                        AS rep_osm_id,
        name, type, state_osm_id, country_code,
        ST_PointOnSurface(ST_Collect(way)) AS center,
        CASE
            WHEN type IN ('river', 'canal') THEN
                LEAST(1.2, 0.3 + LN(GREATEST(1.0,
                    ST_Length(ST_Collect(way)::geography) / 1000.0
                )) / 15.0)
            ELSE max(importance)
        END                                AS best_importance
    FROM natural_feature
    GROUP BY name, type, state_osm_id, country_code
)
UPDATE natural_feature nf
SET
    lon        = ST_X(g.center),
    lat        = ST_Y(g.center),
    way        = g.center,
    importance = g.best_importance
FROM groups g
WHERE nf.osm_id = g.rep_osm_id;

DELETE FROM natural_feature
WHERE osm_id NOT IN (
    SELECT min(osm_id)
    FROM natural_feature
    GROUP BY name, type, state_osm_id, country_code
);

CREATE INDEX idx_natural_feature_way ON natural_feature USING gist (way);
ANALYZE natural_feature;

-- wikipedia tables are kept alive for validate.sql (Wikidata name comparison).
-- Dropped there, or by extract.sh when SKIP_VALIDATION=1.

-- ─── building ────────────────────────────────────────────────────────────────
-- id = min(osm_id) across the cluster — globally unique, stable across dumps.
-- Branch 1 (housenumber node ST_Intersects building polygon) omitted:
-- it causes O(nodes×polygons) spatial join — extremely slow for UA/DE scale.
-- Branch 2 (addr:street on building itself) covers 95%+ of OSM data.
-- Branch 3 (associatedStreet relation) kept — cheap index lookup.
-- building.street_id temporarily stores street.osm_id for the join;
-- it is remapped to street.id (compact) at the end of the script.
-- Materialize buildings_raw into a temp table so the data lands on disk
-- rather than in shared_buffers/work_mem. For large countries (DE) branch 4
-- adds millions of address nodes that would otherwise blow RAM as a CTE.
CREATE TEMP TABLE buildings_unique AS
SELECT DISTINCT ON (osm_id)
    osm_id, housenumber, postcode, way, street_id
FROM (
    -- branch 2: building has addr:housenumber + addr:street tags (main branch)
    SELECT
        b.osm_id,
        b.housenumber,
        b."addr:postcode" AS postcode,
        b.way,
        str.osm_id AS street_id
    FROM import.osm_buildings b
    JOIN street str
        ON str.name = b."addr:street" AND ST_DWithin(b.way, str.way_3857, 400)
    WHERE b.housenumber <> ''
    UNION ALL
    -- branch 3: building in an associatedStreet relation
    SELECT
        b.osm_id,
        b.housenumber,
        COALESCE(b."addr:postcode", rel."addr:postcode"),
        b.way,
        str.osm_id
    FROM import.osm_associated_streets rel
    JOIN import.osm_buildings b ON b.osm_id = rel.member_osm_id
    JOIN street str ON str.rel_osm_ids @> ARRAY[rel.rel_osm_id]
    WHERE rel.role IN ('house', 'address', 'building', '')
    UNION ALL
    -- branch 4: address/entrance nodes with addr:street tag (common in DE for building entrances)
    SELECT
        h.osm_id,
        h.type AS housenumber,
        h."addr:postcode" AS postcode,
        h.way,
        str.osm_id AS street_id
    FROM import.osm_housenumbers h
    JOIN street str
        ON str.name = h."addr:street" AND ST_DWithin(h.way, str.way_3857, 400)
    WHERE h."addr:street" IS NOT NULL AND h."addr:street" <> ''
      AND h.type IS NOT NULL AND h.type <> ''
) buildings_raw
ORDER BY osm_id;

-- Index allows the DBSCAN window function to stream one (housenumber, street_id)
-- partition at a time instead of holding all rows in RAM simultaneously.
CREATE INDEX ON buildings_unique (housenumber, street_id);
ANALYZE buildings_unique;

INSERT INTO building (osm_id, osm_ids, way, street_id, housenumber, postcode, lon, lat)
WITH building_clusters AS (
    SELECT
        ST_ClusterDBSCAN(way, eps := 100, minpoints := 1) OVER (
            PARTITION BY housenumber, street_id
            ORDER BY housenumber, street_id
        ) AS cluster_id,
        osm_id, housenumber, postcode, way, street_id
    FROM buildings_unique
)
, buildings_joined AS (
    SELECT
        min(osm_id)       AS min_osm_id,
        array_agg(osm_id) AS osm_ids,
        housenumber,
        postcode,
        ST_Union(way)     AS way,
        street_id
    FROM building_clusters
    GROUP BY cluster_id, housenumber, street_id, postcode
)
SELECT
    b.min_osm_id                                        AS osm_id,
    b.osm_ids,
    ST_Transform(b.way, 4326)                           AS way,
    b.street_id,
    ltrim(btrim(b.housenumber, '" '''), '#№')           AS housenumber,
    b.postcode,
    ST_X(ST_Transform(ST_PointOnSurface(b.way), 4326)) AS lon,
    ST_Y(ST_Transform(ST_PointOnSurface(b.way), 4326)) AS lat
FROM buildings_joined b
WHERE left(ltrim(btrim(b.housenumber, '" '''), '#№'), 1) IN
      ('0','1','2','3','4','5','6','7','8','9');

UPDATE building
SET country_code = :'country_code';

ANALYZE building;

-- ─── street.postcodes — all postcodes sorted by frequency (most common first) ──
-- Single aggregation pass + join instead of 263k correlated subqueries.
UPDATE street s
SET postcodes = sub.postcodes
FROM (
    SELECT street_id,
           array_agg(postcode ORDER BY cnt DESC, postcode) AS postcodes
    FROM (
        SELECT street_id, postcode, count(*) AS cnt
        FROM building
        WHERE postcode IS NOT NULL AND postcode <> '' AND street_id IS NOT NULL
        GROUP BY street_id, postcode
    ) pc
    GROUP BY street_id
) sub
WHERE sub.street_id = s.osm_id;

-- ─── street.postcodes — fill from street's own addr:postcode tag if missing ───
-- Streets with no buildings (or buildings without postcode) still get a postcode
-- if the street way itself carries addr:postcode.
UPDATE street s
SET postcodes = ARRAY[s.tags->'addr:postcode'] || COALESCE(s.postcodes, '{}')
WHERE s.tags->'addr:postcode' IS NOT NULL
  AND s.tags->'addr:postcode' <> ''
  AND NOT (COALESCE(s.postcodes, '{}') @> ARRAY[s.tags->'addr:postcode']);

-- ─── postcode: synthetic polygons from buildings (fallback) ─────────────────
-- Used when boundary=postal_code relations are absent in OSM (e.g. Ukraine).
-- Concave hull (0.99) traces the actual cluster shape; NOT EXISTS skips zones
-- already covered by real OSM postal_code polygons.
WITH missing AS (
    SELECT DISTINCT b.postcode FROM building b
    WHERE b.postcode IS NOT NULL AND b.postcode != ''
    EXCEPT
    SELECT postal_code FROM postcode WHERE country_code = :'country_code'
)
INSERT INTO postcode (postal_code, way, lon, lat, country_code, state_osm_id)
SELECT b.postcode,
       ST_Transform(
           ST_ConcaveHull(ST_Collect(ST_Transform(b.way, 3857)), 0.99),
           4326
       )                                                             AS way,
       ST_X(ST_Centroid(ST_Collect(b.way)))                         AS lon,
       ST_Y(ST_Centroid(ST_Collect(b.way)))                         AS lat,
       :'country_code',
       s.osm_id                                                      AS state_osm_id
FROM building b
JOIN missing m ON m.postcode = b.postcode
JOIN state s ON ST_Contains(s.way, ST_SetSRID(ST_MakePoint(b.lon, b.lat), 4326))
GROUP BY b.postcode, s.osm_id;

ANALYZE postcode;

-- ─── Drop before compact ID assignment ───────────────────────────────────────
-- way_3857: temp column used only for the building spatial join.
ALTER TABLE street DROP COLUMN IF EXISTS way_3857;

-- ─── Assign compact surrogate IDs (GeoHash order) ────────────────────────────
-- Streets and buildings are numbered independently within their own tables.
-- IDs sorted by Z-curve (Morton) geohash so nearby objects get nearby IDs —
-- this maximises RoaringBitmap container density (fewer containers, better AND/OR perf).
-- Precision 7 ≈ 150 m cells; increase to 8 (≈ 40 m) for denser urban areas.
--
-- ID_OFFSET: per-country base so IDs are globally unique across countries.
-- Each country gets a 50M slot → supports up to 85 countries within u32 range.
-- Set via psql variable:  psql -v id_offset=50000000 ...
-- Default (0) is correct for the first country loaded into a fresh DB.
\set id_offset :id_offset

-- ─── Align object_registry sequence to country offset ───────────────────────
SELECT setval('object_registry_internal_id_seq', GREATEST(:id_offset, 1));

-- ─── Assign id + internal_id for streets ────────────────────────────────────
-- Single pass: rn gives compact GeoHash-ordered id; nextval gives internal_id.
-- ROW_NUMBER() OVER () preserves subquery ORDER BY order (no extra sort).
CREATE TEMP TABLE _ids_street AS
SELECT osm_id,
       (ROW_NUMBER() OVER ())::integer AS rn,
       nextval('object_registry_internal_id_seq') AS internal_id
FROM (SELECT osm_id, lon, lat FROM street
      ORDER BY ST_GeoHash(ST_SetSRID(ST_MakePoint(lon, lat), 4326), 7)) s;

INSERT INTO object_registry (internal_id, object_type)
SELECT internal_id, 'street' FROM _ids_street;

INSERT INTO alias_osm (osm_id, internal_id)
SELECT osm_id, internal_id FROM _ids_street WHERE osm_id IS NOT NULL ON CONFLICT DO NOTHING;

UPDATE street SET id = t.rn + :id_offset, internal_id = t.internal_id
FROM _ids_street t WHERE t.osm_id = street.osm_id;

DROP TABLE _ids_street;

-- Remap building.street_id from osm_id space to compact id space.
UPDATE building b
SET street_id = s.id
FROM street s
WHERE s.osm_id = b.street_id;

-- ─── Assign id + internal_id for buildings ───────────────────────────────────
CREATE TEMP TABLE _ids_building AS
SELECT osm_id,
       (ROW_NUMBER() OVER ())::integer AS rn,
       nextval('object_registry_internal_id_seq') AS internal_id
FROM (SELECT osm_id, lon, lat FROM building
      ORDER BY ST_GeoHash(ST_SetSRID(ST_MakePoint(lon, lat), 4326), 7)) s;

CREATE INDEX ON _ids_building (osm_id);

INSERT INTO object_registry (internal_id, object_type)
SELECT internal_id, 'building' FROM _ids_building;

INSERT INTO alias_osm (osm_id, internal_id)
SELECT osm_id, internal_id FROM _ids_building WHERE osm_id IS NOT NULL ON CONFLICT DO NOTHING;

UPDATE building SET id = t.rn + :id_offset, internal_id = t.internal_id
FROM _ids_building t WHERE t.osm_id = building.osm_id;

DROP TABLE _ids_building;

-- cities
CREATE TEMP TABLE _ids_city AS
SELECT osm_id, nextval('object_registry_internal_id_seq') AS internal_id
FROM (SELECT osm_id, lon, lat FROM city WHERE osm_id IS NOT NULL
      ORDER BY ST_GeoHash(ST_SetSRID(ST_MakePoint(lon, lat), 4326), 7)) s;

INSERT INTO object_registry (internal_id, object_type)
SELECT internal_id, 'city' FROM _ids_city;

INSERT INTO alias_osm (osm_id, internal_id)
SELECT osm_id, internal_id FROM _ids_city ON CONFLICT DO NOTHING;

UPDATE city SET internal_id = t.internal_id
FROM _ids_city t WHERE t.osm_id = city.osm_id;

DROP TABLE _ids_city;

-- states
CREATE TEMP TABLE _ids_state AS
SELECT osm_id, nextval('object_registry_internal_id_seq') AS internal_id
FROM (SELECT osm_id, lon, lat FROM state WHERE osm_id IS NOT NULL
      ORDER BY ST_GeoHash(ST_SetSRID(ST_MakePoint(lon, lat), 4326), 7)) s;

INSERT INTO object_registry (internal_id, object_type)
SELECT internal_id, 'state' FROM _ids_state;

INSERT INTO alias_osm (osm_id, internal_id)
SELECT osm_id, internal_id FROM _ids_state ON CONFLICT DO NOTHING;

UPDATE state SET internal_id = t.internal_id
FROM _ids_state t WHERE t.osm_id = state.osm_id;

DROP TABLE _ids_state;

-- countries
CREATE TEMP TABLE _ids_country AS
SELECT osm_id, nextval('object_registry_internal_id_seq') AS internal_id
FROM (SELECT osm_id, lon, lat FROM country WHERE osm_id IS NOT NULL
      ORDER BY ST_GeoHash(ST_SetSRID(ST_MakePoint(lon, lat), 4326), 7)) s;

INSERT INTO object_registry (internal_id, object_type)
SELECT internal_id, 'country' FROM _ids_country;

INSERT INTO alias_osm (osm_id, internal_id)
SELECT osm_id, internal_id FROM _ids_country ON CONFLICT DO NOTHING;

UPDATE country SET internal_id = t.internal_id
FROM _ids_country t WHERE t.osm_id = country.osm_id;

DROP TABLE _ids_country;

-- natural_features
CREATE TEMP TABLE _ids_natural_feature AS
SELECT osm_id, nextval('object_registry_internal_id_seq') AS internal_id
FROM (SELECT osm_id, lon, lat FROM natural_feature WHERE osm_id IS NOT NULL
      ORDER BY ST_GeoHash(ST_SetSRID(ST_MakePoint(lon, lat), 4326), 7)) s;

INSERT INTO object_registry (internal_id, object_type)
SELECT internal_id, 'natural_feature' FROM _ids_natural_feature;

INSERT INTO alias_osm (osm_id, internal_id)
SELECT osm_id, internal_id FROM _ids_natural_feature ON CONFLICT DO NOTHING;

UPDATE natural_feature SET internal_id = t.internal_id
FROM _ids_natural_feature t WHERE t.osm_id = natural_feature.osm_id;

DROP TABLE _ids_natural_feature;

-- postcodes
CREATE TEMP TABLE _ids_postcode AS
SELECT osm_id, nextval('object_registry_internal_id_seq') AS internal_id
FROM (SELECT osm_id, lon, lat FROM postcode WHERE osm_id IS NOT NULL
      ORDER BY ST_GeoHash(ST_SetSRID(ST_MakePoint(lon, lat), 4326), 7)) s;

INSERT INTO object_registry (internal_id, object_type)
SELECT internal_id, 'postcode' FROM _ids_postcode;

INSERT INTO alias_osm (osm_id, internal_id)
SELECT osm_id, internal_id FROM _ids_postcode ON CONFLICT DO NOTHING;

UPDATE postcode SET internal_id = t.internal_id
FROM _ids_postcode t WHERE t.osm_id = postcode.osm_id;

DROP TABLE _ids_postcode;

-- ─── Primary keys and final indexes ──────────────────────────────────────────
ALTER TABLE street   ADD CONSTRAINT pk_street   PRIMARY KEY (id);
ALTER TABLE building ADD CONSTRAINT pk_building PRIMARY KEY (id);

-- osm_id: nullable, partial index (non-OSM sources have NULL).
CREATE INDEX idx_street_osm_id   ON street   (osm_id) WHERE osm_id IS NOT NULL;
CREATE INDEX idx_building_osm_id ON building (osm_id) WHERE osm_id IS NOT NULL;

-- internal_id indexes — used by geocompleter and for deduplication across sources.
CREATE INDEX idx_street_internal_id   ON street   (internal_id) WHERE internal_id IS NOT NULL;
CREATE INDEX idx_building_internal_id ON building (internal_id) WHERE internal_id IS NOT NULL;
CREATE INDEX idx_city_internal_id     ON city     (internal_id) WHERE internal_id IS NOT NULL;

-- building → street lookup (used by geocompleter to fetch buildings per street).
CREATE INDEX idx_building_street_id ON building (street_id);

-- ─── Drop before dump ────────────────────────────────────────────────────────
-- data_source: seeded by create.sql in production (id=1 'osm' already exists).
-- Including it in the dump causes duplicate key conflicts on pg_restore when
-- other countries' data is already present — so we drop it here instead of
-- excluding it via pg_dump -T.
-- object_registry and alias_osm are NOT dropped — they are included in the dump
-- and restored into production to preserve stable internal_ids across extractions.
DROP TABLE data_source;

SET session_replication_role = DEFAULT;
