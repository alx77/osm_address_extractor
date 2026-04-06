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

-- ─── Extensions ──────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS btree_gist;

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

CREATE SEQUENCE IF NOT EXISTS external_id_seq START 5000000000000000;

CREATE UNLOGGED TABLE IF NOT EXISTS country (
    osm_id     bigint,
    name       text,
    tags       hstore,
    way        geometry(Geometry, 4326),
    lon        float8,
    lat        float8,
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);

CREATE UNLOGGED TABLE IF NOT EXISTS state (
    osm_id         bigint,
    name           text,
    country_osm_id bigint,
    tags           hstore,
    way            geometry(Geometry, 4326),
    lon            float8,
    lat            float8,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    deleted_at     timestamptz
);

CREATE UNLOGGED TABLE IF NOT EXISTS city (
    osm_id       bigint,
    name         text,
    place        text,
    postal_code  text,
    tags         hstore,
    admin_level  integer,
    state_osm_id bigint,
    way_origin   geometry(Geometry, 3857),
    way          geometry(Geometry, 4326),
    lon          float8,
    lat          float8,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    deleted_at   timestamptz
);

CREATE UNLOGGED TABLE IF NOT EXISTS street (
    id           bigint,
    name         text NOT NULL,
    city_osm_id  bigint,
    rel_osm_ids  bigint[],
    osm_ids      bigint[],
    city_area    float8,
    tags         hstore,
    importance   float8,
    postcode     text,
    way          geometry(Geometry, 4326),
    way_3857     geometry,        -- temp column for building spatial join; dropped at end
    lon          float8,
    lat          float8,
    source_id    smallint NOT NULL DEFAULT 1,
    source_ref   text,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    deleted_at   timestamptz
);

CREATE UNLOGGED TABLE IF NOT EXISTS building (
    id           bigint,
    street_id    bigint,
    osm_ids      bigint[],
    housenumber  text,
    postcode     text,
    way          geometry(Geometry, 4326),
    lon          float8,
    lat          float8,
    source_id    smallint NOT NULL DEFAULT 1,
    source_ref   text,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    deleted_at   timestamptz
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

DROP INDEX IF EXISTS import.idx_osm_admin_level;
CREATE INDEX idx_osm_admin_level
    ON import.osm_admin (admin_level);

DROP INDEX IF EXISTS import.idx_osm_admin_place;
CREATE INDEX idx_osm_admin_place
    ON import.osm_admin (place);

-- ─── country ─────────────────────────────────────────────────────────────────
INSERT INTO country (osm_id, name, tags, way, lon, lat)
SELECT DISTINCT ON (osm_id)
    osm_id,
    name,
    tags,
    ST_Transform(way, 4326),
    ST_X(ST_Transform(ST_Centroid(way), 4326)),
    ST_Y(ST_Transform(ST_Centroid(way), 4326))
FROM import.osm_admin
WHERE admin_level = 2;

-- Minimal index for subsequent spatial join (state → country)
CREATE INDEX idx_country_way ON country USING gist (way);
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

-- Minimal index for subsequent spatial join (city → state)
CREATE INDEX idx_state_way ON state USING gist (way);
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
JOIN state ON ST_Contains(state.way, ST_Transform(cit.way, 4326))
WHERE cit.admin_level >= 6 OR cit.place IN ('city','hamlet','town','village')
   OR (cit.place = 'state' AND cit.name IN ('Berlin', 'Hamburg', 'Bremen'));

-- Minimal indexes for subsequent spatial join (lines → city)
CREATE INDEX idx_city_way        ON city USING gist (way);
CREATE INDEX idx_city_way_origin ON city USING gist (way_origin);
ANALYZE city;

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
ORDER BY osm_id, place_order;

CREATE UNIQUE INDEX idx_lines_id ON lines (osm_id);
ALTER TABLE lines ADD CONSTRAINT pk_lines PRIMARY KEY USING INDEX idx_lines_id;
CREATE INDEX idx_lines_name_way ON lines USING gist(name, city_osm_id, admin_level, way);
ANALYZE lines;

-- ─── street ──────────────────────────────────────────────────────────────────
-- id = min(osm_id) across the cluster — globally unique, stable across dumps.
-- way_3857 populated directly from the cluster union (EPSG:3857 from osm_roads),
-- used for building spatial joins; dropped at the end.
INSERT INTO street (id, name, rel_osm_ids, osm_ids, city_osm_id,
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
    sr.min_osm_id                                        AS id,
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

-- Minimal indexes for building spatial join and importance update
CREATE INDEX idx_street_way_3857    ON street USING gist (way_3857) WHERE way_3857 IS NOT NULL;
CREATE INDEX idx_street_name_tmp    ON street (name);
CREATE INDEX idx_street_rels_tmp    ON street USING GIN (rel_osm_ids);
CREATE INDEX idx_street_city_id_tmp ON street (city_osm_id);
ANALYZE street;

-- ─── importance ───────────────────────────────────────────────────────────────
UPDATE street s
SET importance = LEAST(1.0,
    LN(GREATEST(100, COALESCE(
        NULLIF(regexp_replace(c.tags->'population', '[^0-9]', '', 'g'), '')::float,
        CASE c.place
            WHEN 'state'   THEN 2000000
            WHEN 'city'    THEN 500000
            WHEN 'town'    THEN 30000
            WHEN 'village' THEN 2000
            WHEN 'hamlet'  THEN 300
            ELSE                 5000
        END
    ))) / LN(10000000.0)
)
FROM city c
WHERE c.osm_id = s.city_osm_id;

-- ─── building ────────────────────────────────────────────────────────────────
-- id = min(osm_id) across the cluster — globally unique, stable across dumps.
INSERT INTO building (id, osm_ids, way, street_id, housenumber, postcode, lon, lat)
WITH buildings_raw AS (
    -- branch 1: no housenumber on building, but housenumber node is inside it
    SELECT
        b.osm_id,
        h.type AS housenumber,
        COALESCE(b."addr:postcode", h."addr:postcode") AS postcode,
        b.way,
        str.id AS street_id
    FROM import.osm_buildings b
    JOIN import.osm_housenumbers h
        ON ST_Intersects(h.way, b.way) AND b.housenumber = '' AND h."addr:street" <> ''
    JOIN street str
        ON str.name = h."addr:street" AND ST_DWithin(b.way, str.way_3857, 400)
    UNION ALL
    -- branch 2: building has addr:housenumber + addr:street tags
    SELECT
        b.osm_id,
        b.housenumber,
        b."addr:postcode",
        b.way,
        str.id
    FROM import.osm_buildings b
    JOIN street str
        ON str.name = b."addr:street" AND ST_DWithin(b.way, str.way_3857, 400)
       AND b.housenumber <> ''
    UNION ALL
    -- branch 3: building in an associatedStreet relation
    SELECT
        b.osm_id,
        b.housenumber,
        COALESCE(b."addr:postcode", rel."addr:postcode"),
        b.way,
        str.id
    FROM import.osm_buildings b
    JOIN import.osm_associated_streets rel
        ON b.osm_id = rel.member_osm_id AND rel.role = 'house'
    JOIN street str ON rel.rel_osm_id = ANY(str.rel_osm_ids)
)
, buildings_unique AS materialized (
    SELECT DISTINCT ON (osm_id)
        osm_id, housenumber, postcode, way, street_id
    FROM buildings_raw
)
, building_clusters AS materialized (
    SELECT
        ST_ClusterDBSCAN(way, eps := 100, minpoints := 1) OVER (
            PARTITION BY housenumber, street_id
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
    b.min_osm_id                                        AS id,
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

ANALYZE building;

-- ─── street.postcode — most common postcode among its buildings ───────────────
UPDATE street s
SET postcode = (
    SELECT b.postcode
    FROM building b
    WHERE b.street_id = s.id
      AND b.postcode IS NOT NULL AND b.postcode <> ''
    GROUP BY b.postcode
    ORDER BY count(*) DESC
    LIMIT 1
)
WHERE s.postcode IS NULL;

-- ─── Drop temporary way_3857 column (before dump) ────────────────────────────
ALTER TABLE street DROP COLUMN IF EXISTS way_3857;

-- ─── Bulk add PKs, FKs, and all secondary indexes ────────────────────────────
-- Done in one pass after all data is loaded — bulk index builds are 2-3x faster
-- than per-row index maintenance during INSERT. Order: parent tables first.

ALTER TABLE data_source ADD PRIMARY KEY (id);

ALTER TABLE country ADD PRIMARY KEY (osm_id);
CREATE INDEX idx_country_way_geo ON country USING gist (way);

ALTER TABLE state ADD PRIMARY KEY (osm_id);
ALTER TABLE state ADD CONSTRAINT fk_state_country
    FOREIGN KEY (country_osm_id) REFERENCES country(osm_id);
CREATE INDEX idx_state_country_osm_id ON state (country_osm_id);
CREATE INDEX idx_state_way_geo        ON state USING gist (way);

ALTER TABLE city ADD PRIMARY KEY (osm_id);
ALTER TABLE city ADD CONSTRAINT fk_city_state
    FOREIGN KEY (state_osm_id) REFERENCES state(osm_id);
CREATE INDEX idx_city_state_osm_id ON city (state_osm_id);
CREATE INDEX idx_city_way_geo      ON city USING gist (way);
CREATE INDEX idx_city_way_origin   ON city USING gist (way_origin);

ALTER TABLE street ADD PRIMARY KEY (id);
ALTER TABLE street ADD CONSTRAINT fk_street_city
    FOREIGN KEY (city_osm_id) REFERENCES city(osm_id);
ALTER TABLE street ADD CONSTRAINT fk_street_source
    FOREIGN KEY (source_id) REFERENCES data_source(id);
CREATE UNIQUE INDEX idx_street_active       ON street (id)            WHERE deleted_at IS NULL;
CREATE INDEX idx_street_name                ON street (name);
CREATE INDEX idx_street_city_osm_id         ON street (city_osm_id);
CREATE INDEX idx_street_importance          ON street (importance DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_street_postcode            ON street (postcode)       WHERE postcode IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX idx_street_tags                ON street USING GIN (tags);
CREATE INDEX idx_street_rel_osm_ids         ON street USING GIN (rel_osm_ids);
CREATE UNIQUE INDEX idx_street_source_ref   ON street (source_id, source_ref)
    WHERE source_ref IS NOT NULL AND deleted_at IS NULL;

ALTER TABLE building ADD PRIMARY KEY (id);
ALTER TABLE building ADD CONSTRAINT fk_building_street
    FOREIGN KEY (street_id) REFERENCES street(id);
ALTER TABLE building ADD CONSTRAINT fk_building_source
    FOREIGN KEY (source_id) REFERENCES data_source(id);
CREATE INDEX idx_building_street_id ON building (street_id);
CREATE INDEX idx_building_way       ON building USING gist (way) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX idx_building_source_ref ON building (source_id, source_ref)
    WHERE source_ref IS NOT NULL AND deleted_at IS NULL;

-- ─── Set LOGGED (reverse FK order) and re-enable triggers ────────────────────
ALTER TABLE building    SET LOGGED;
ALTER TABLE street      SET LOGGED;
ALTER TABLE city        SET LOGGED;
ALTER TABLE state       SET LOGGED;
ALTER TABLE country     SET LOGGED;
ALTER TABLE data_source SET LOGGED;

SET session_replication_role = DEFAULT;

-- ─── Final statistics ────────────────────────────────────────────────────────
ANALYZE country;
ANALYZE state;
ANALYZE city;
ANALYZE street;
ANALYZE building;
