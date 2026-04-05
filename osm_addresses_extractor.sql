-- ─── Session tuning ──────────────────────────────────────────────────────────
-- Heavy spatial joins and recursive CTEs need memory to avoid spilling to disk.
SET work_mem = '512MB';
SET maintenance_work_mem = '1GB';
-- Uncomment when running under Podman rootless: parallel workers fail there due to
-- kernel DSM limits in user namespace. On a proper Docker host leave this commented.
-- SET max_parallel_workers_per_gather = 0;

-- ─── Extensions ──────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS btree_gist;

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

-- Speed up admin_level / place filtering (used in every hierarchy step)
DROP INDEX IF EXISTS import.idx_osm_admin_level;
CREATE INDEX idx_osm_admin_level
ON import.osm_admin (admin_level);

DROP INDEX IF EXISTS import.idx_osm_admin_place;
CREATE INDEX idx_osm_admin_place
ON import.osm_admin (place);

-- ─── country ─────────────────────────────────────────────────────────────────
DROP TABLE IF EXISTS country;
CREATE TABLE country AS
SELECT DISTINCT ON (osm_id)
	osm_id,
	name,
	tags,
	ST_Transform(way, 4326) AS way,
	ST_X(ST_Transform(ST_Centroid(way), 4326)) AS lon,
	ST_Y(ST_Transform(ST_Centroid(way), 4326)) AS lat
FROM import.osm_admin
WHERE admin_level = 2;

-- Needed immediately for the state spatial JOIN below
CREATE INDEX idx_country_way ON country USING gist (way);

DROP INDEX IF EXISTS idx_country_osm_id;
CREATE UNIQUE INDEX idx_country_osm_id ON country (osm_id);
ALTER TABLE country ADD CONSTRAINT pk_country PRIMARY KEY USING INDEX idx_country_osm_id;

ANALYZE country;

-- ─── state ───────────────────────────────────────────────────────────────────
DROP TABLE IF EXISTS state;
CREATE TABLE state AS
SELECT DISTINCT ON (sta.osm_id)
	sta.osm_id,
	sta.name,
	country.osm_id AS country_osm_id,
	sta.tags,
	ST_Transform(sta.way, 4326) AS way,
	ST_X(ST_Transform(ST_Centroid(sta.way), 4326)) AS lon,
	ST_Y(ST_Transform(ST_Centroid(sta.way), 4326)) AS lat
FROM import.osm_admin sta
JOIN country ON (ST_Contains(country.way, ST_Transform(sta.way, 4326)))
WHERE place = 'state' OR admin_level = 4;

-- Needed immediately for the city spatial JOIN below
CREATE INDEX idx_state_way ON state USING gist (way);

DROP INDEX IF EXISTS idx_state_osm_id;
CREATE UNIQUE INDEX idx_state_osm_id ON state (osm_id);
ALTER TABLE state ADD CONSTRAINT pk_state PRIMARY KEY USING INDEX idx_state_osm_id;

DROP INDEX IF EXISTS idx_state_country_osm_id;
CREATE INDEX idx_state_country_osm_id ON state (country_osm_id);

ANALYZE state;

-- ─── city ─────────────────────────────────────────────────────────────────────
DROP TABLE IF EXISTS city;
CREATE TABLE city AS
SELECT DISTINCT ON (cit.osm_id)
	cit.osm_id,
	cit.name,
	cit.place,
	cit.postal_code,
	cit.tags,
	cit.admin_level,
	state.osm_id AS state_osm_id,
	cit.way AS way_origin,
	ST_Transform(cit.way, 4326) AS way,
	ST_X(ST_Transform(ST_Centroid(cit.way), 4326)) AS lon,
	ST_Y(ST_Transform(ST_Centroid(cit.way), 4326)) AS lat
FROM import.osm_admin cit
JOIN state ON (ST_Contains(state.way, ST_Transform(cit.way, 4326)))
WHERE cit.admin_level >= 6 OR cit.place IN ('city','hamlet','town','village')
   OR (cit.place = 'state' AND cit.name IN ('Berlin', 'Hamburg', 'Bremen'));

CREATE INDEX idx_cities_way ON public.city USING gist (way);

-- way_origin (EPSG:3857) is used for the lines spatial JOIN — same CRS as roads
CREATE INDEX idx_cities_way_origin ON public.city USING gist (way_origin);

DROP INDEX IF EXISTS idx_city_id;
CREATE UNIQUE INDEX idx_city_id ON city (osm_id);
ALTER TABLE city ADD CONSTRAINT pk_city PRIMARY KEY USING INDEX idx_city_id;

CREATE INDEX idx_city_state_osm_id ON city (state_osm_id);

ANALYZE city;

-- ─── lines (temp — only needed to build street, never exported) ───────────────
DROP TABLE IF EXISTS lines;
CREATE TEMP TABLE lines AS
WITH fragments AS materialized (
    SELECT
	   r.osm_id,
	   c.osm_id as city_osm_id,
	   r.name,
	   (c.tags->'admin_level')::int as admin_level,
	   c.place,
	   case c.place
           when 'state' then 1
           when 'city' then 2
           when 'hamlet' then 3
           when 'town' then 4
           when 'village' then 5
	       else 6
       end AS place_order,
	   r.tags,
	   r.way,
	   ST_X(ST_PointN(ST_ExteriorRing(ST_Envelope(r.way)),1)) AS leftx
    FROM import.osm_roads r
    JOIN city c ON (ST_Contains(c.way_origin, r.way))
    WHERE type IN ('trunk','road','footway','primary','secondary','tertiary','primary_link','secondary_link','tertiary_link','construction','pedestrian','residential','track','steps','proposed','trunk_link','living_street','unclassified','unknown','motorway')
)
SELECT DISTINCT ON (osm_id) *
FROM fragments
ORDER BY osm_id, place_order;

CREATE UNIQUE INDEX idx_lines_id ON lines (osm_id);
ALTER TABLE lines ADD CONSTRAINT pk_lines PRIMARY KEY USING INDEX idx_lines_id;

CREATE INDEX idx_lines_idx_name_way
    ON lines USING gist(name, city_osm_id, admin_level, way);

ANALYZE lines;

-- ─── street (ST_ClusterDBSCAN replaces recursive CTE) ────────────────────────
-- ST_ClusterDBSCAN groups road segments with the same name within the same city
-- that are within 1000m of each other — same semantics as the old recursive CTE,
-- but a single pass instead of iterative graph traversal.
DROP TABLE IF EXISTS street;
CREATE TABLE street AS
WITH clusters AS materialized (
    SELECT
        ST_ClusterDBSCAN(way, eps := 1000, minpoints := 1) OVER (
            PARTITION BY name, city_osm_id
        ) AS cluster_id,
        osm_id,
        city_osm_id,
        name,
        way
    FROM lines
)
, street_groups AS materialized (
    SELECT
        row_number() OVER () AS id,
        name,
        city_osm_id,
        array_agg(osm_id ORDER BY osm_id) AS osm_ids,
        ST_Union(way) AS way
    FROM clusters
    GROUP BY name, city_osm_id, cluster_id
)
, street_unnested AS (
    -- Unnest osm_ids so the JOIN with osm_associated_streets can use
    -- idx_osm_associated_streets_member instead of ANY(array) scan
    SELECT sg.id, sg.name, sg.city_osm_id, sg.osm_ids, sg.way,
           unnest(sg.osm_ids) AS member_osm_id
    FROM street_groups sg
)
, street_rels AS (
    SELECT
        su.id,
        su.name,
        su.city_osm_id,
        su.osm_ids,
        su.way,
        array_remove(array_agg(DISTINCT r.rel_osm_id), NULL) AS rel_osm_ids
    FROM street_unnested su
    LEFT JOIN import.osm_associated_streets r
        ON r.member_osm_id = su.member_osm_id AND r.name = su.name AND r.role = 'street'
    GROUP BY su.id, su.name, su.city_osm_id, su.osm_ids, su.way
)
SELECT DISTINCT ON (sr.id)
    sr.id,
    sr.name,
    sr.rel_osm_ids,
    sr.osm_ids,
    sr.city_osm_id,
    ST_Area(cit.way) AS city_area,
    r.tags,
    -- way_3857 kept temporarily for building ST_DWithin joins (same CRS as osm_buildings)
    -- dropped after building table is constructed
    sr.way AS way_3857,
    ST_Transform(sr.way, 4326) AS way,
    ST_X(ST_Transform(ST_PointOnSurface(sr.way), 4326)) AS lon,
    ST_Y(ST_Transform(ST_PointOnSurface(sr.way), 4326)) AS lat
FROM street_rels sr
JOIN import.osm_roads r ON r.osm_id = sr.osm_ids[1]
JOIN city cit ON cit.osm_id = sr.city_osm_id;

DROP INDEX IF EXISTS idx_street_id;
CREATE UNIQUE INDEX idx_street_id ON street (id);
ALTER TABLE street ADD CONSTRAINT pk_street PRIMARY KEY USING INDEX idx_street_id;

CREATE INDEX idx_street_name ON street (name);
CREATE INDEX idx_street_tags ON street USING GIN (tags);
CREATE INDEX idx_street_rel_osm_ids ON street USING GIN (rel_osm_ids);
-- GiST on way_3857 (EPSG:3857) for fast ST_DWithin in building joins
CREATE INDEX idx_street_way_3857 ON street USING gist (way_3857);
CREATE INDEX idx_street_city_osm_id ON street (city_osm_id);

-- ─── importance ───────────────────────────────────────────────────────────────
-- Logarithmic scale: LN(population) / LN(10_000_000) → [0, 1]
-- Uses real population from OSM tags when available, falls back to place type.
-- Universal: works the same for DE, UA, PL and any other country.
ALTER TABLE street ADD COLUMN importance float;

UPDATE street s
SET importance = LEAST(1.0,
    LN(GREATEST(100, COALESCE(
        -- Strip non-numeric chars to handle "1,500,000" style values
        NULLIF(regexp_replace(c.tags->'population', '[^0-9]', '', 'g'), '')::float,
        -- Fallback: representative population estimate per place type
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

CREATE INDEX idx_street_importance ON street (importance DESC);

ANALYZE street;

-- ─── building (ST_ClusterDBSCAN replaces recursive anchors CTE) ──────────────
DROP TABLE IF EXISTS building;
CREATE TABLE building AS
WITH buildings_raw AS (
    -- branch 1: building polygon has no housenumber, but a housenumber node is inside it
    SELECT
        b.osm_id,
        h.type AS housenumber,
        COALESCE(b."addr:postcode", h."addr:postcode") AS postcode,
        b.way,
        str.id AS street_id
    FROM import.osm_buildings b
    JOIN import.osm_housenumbers h ON ST_Intersects(h.way, b.way) AND b.housenumber = '' AND h."addr:street" <> ''
    JOIN street str ON str.name = h."addr:street" AND ST_DWithin(b.way, str.way_3857, 400)
    UNION ALL
    -- branch 2: building has addr:housenumber and addr:street tags
    SELECT
        b.osm_id,
        b.housenumber AS housenumber,
        b."addr:postcode" AS postcode,
        b.way,
        str.id AS street_id
    FROM import.osm_buildings b
    JOIN street str ON str.name = b."addr:street" AND ST_DWithin(b.way, str.way_3857, 400) AND b.housenumber <> ''
    UNION ALL
    -- branch 3: building belongs to an associatedStreet relation
    SELECT
        b.osm_id,
        b.housenumber,
        COALESCE(b."addr:postcode", rel."addr:postcode") AS postcode,
        b.way,
        str.id AS street_id
    FROM import.osm_buildings b
    JOIN import.osm_associated_streets rel ON (b.osm_id = rel.member_osm_id AND rel.role = 'house')
    JOIN street str ON (rel.rel_osm_id = ANY(str.rel_osm_ids))
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
        osm_id,
        housenumber,
        postcode,
        way,
        street_id
    FROM buildings_unique
)
, buildings_joined AS (
    SELECT
        array_agg(DISTINCT osm_id) AS osm_ids,
        housenumber,
        postcode,
        ST_Union(way) AS way,
        street_id
    FROM building_clusters
    GROUP BY cluster_id, housenumber, street_id, postcode
)
SELECT
    row_number() OVER () AS id,
    b.osm_ids,
    ST_Transform(b.way, 4326) AS way,
    b.street_id,
    housenumber,
    postcode,
    ST_X(ST_Transform(ST_PointOnSurface(b.way), 4326)) AS lon,
    ST_Y(ST_Transform(ST_PointOnSurface(b.way), 4326)) AS lat
FROM buildings_joined b;

UPDATE building SET housenumber = ltrim(btrim(housenumber,'" '''),'#№') WHERE left(housenumber,1) NOT IN ('0','1','2','3','4','5','6','7','8','9');
DELETE FROM building WHERE left(housenumber,1) NOT IN ('0','1','2','3','4','5','6','7','8','9');

DROP INDEX IF EXISTS idx_buildings_way;
CREATE INDEX idx_buildings_way ON public.building USING gist (way);

DROP INDEX IF EXISTS idx_building_id;
CREATE UNIQUE INDEX idx_building_id ON public.building (id);

DROP INDEX IF EXISTS idx_building_street_id;
CREATE INDEX idx_building_street_id ON public.building (street_id);

ALTER TABLE building ADD CONSTRAINT pk_building PRIMARY KEY USING INDEX idx_building_id;

-- ─── street.postcode — most common postcode among its buildings ───────────────
-- Nullable: populated where buildings have postcode data (DE, PL, etc.), NULL elsewhere.
ALTER TABLE street ADD COLUMN postcode text;

UPDATE street s
SET postcode = (
    SELECT b.postcode
    FROM building b
    WHERE b.street_id = s.id
      AND b.postcode IS NOT NULL
      AND b.postcode <> ''
    GROUP BY b.postcode
    ORDER BY count(*) DESC
    LIMIT 1
);

CREATE INDEX idx_street_postcode ON street (postcode) WHERE postcode IS NOT NULL;

-- ─── way_3857 no longer needed after building is constructed ──────────────────
-- Dropping it reduces the dump size (raw EPSG:3857 geometry per street row).
ALTER TABLE street DROP COLUMN way_3857;

-- ─── Final statistics for query planner in destination DB ────────────────────
ANALYZE country;
ANALYZE state;
ANALYZE city;
ANALYZE street;
ANALYZE building;
