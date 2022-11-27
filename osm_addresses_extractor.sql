CREATE EXTENSION IF NOT EXISTS btree_gist;

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
WHERE admin_level = 2; -- countries

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
JOIN country ON (ST_Contains(country.way, ST_Transform(sta.way, 4326))) --country
WHERE place = 'state' OR admin_level = 4; -- states

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
   OR (cit.place = 'state' AND cit.name = 'Berlin');

DROP INDEX IF EXISTS idx_cities_way;
CREATE INDEX idx_cities_way
ON public.city USING gist (way);

DROP INDEX IF EXISTS idx_cities_way_origin;
CREATE INDEX idx_cities_way_origin
ON public.city USING gist (way_origin);

DROP INDEX IF EXISTS idx_city_id;
CREATE UNIQUE INDEX idx_city_id ON city (osm_id);
ALTER TABLE city ADD CONSTRAINT pk_city PRIMARY KEY USING INDEX idx_city_id;

DROP TABLE IF EXISTS lines;
CREATE TABLE lines AS
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
	   ST_X(ST_PointN(ST_ExteriorRing(ST_Envelope(r.way)),1)) AS leftx --3857 IN meters
    FROM import.osm_roads r
    JOIN city c ON (ST_Contains(c.way_origin, r.way))
    WHERE type IN ('trunk','road','footway','primary','secondary','tertiary','primary_link','secondary_link','tertiary_link','construction','pedestrian','residential','track','steps','proposed','trunk_link','living_street','unclassified','unknown','motorway')
)
--SELECT DISTINCT ON (f1.osm_id) f1.* FROM fragments f1 LEFT JOIN fragments f2 ON (f1.osm_id = f2.osm_id AND f1.admin_level < f2.admin_level) WHERE f2.osm_id IS NULL
SELECT DISTINCT ON (f1.osm_id) f1.* FROM fragments f1 LEFT JOIN fragments f2 ON (f1.osm_id = f2.osm_id AND f1.place_order > f2.place_order) WHERE f2.osm_id IS NULL;

DROP INDEX IF EXISTS idx_lines_id;
CREATE UNIQUE INDEX idx_lines_id ON lines (osm_id);
ALTER TABLE lines ADD CONSTRAINT pk_lines PRIMARY KEY USING INDEX idx_lines_id;

CREATE INDEX idx_lines_idx_name_way
    ON lines USING gist(name, city_osm_id, admin_level, way);

DROP TABLE IF EXISTS street;
CREATE TABLE street AS
WITH RECURSIVE anchors AS materialized (
    SELECT a.osm_id, a.city_osm_id, a.name, a.way, a.leftx
	FROM lines a
	WHERE NOT EXISTS (
		SELECT 1 FROM lines b
		WHERE a.osm_id <> b.osm_id AND a.city_osm_id = b.city_osm_id AND a.name=b.name AND a.leftx > b.leftx AND ST_DWithin(b.way, a.way, 1000) -- 1000m
	)
)
, street_fragments (id, osm_id, city_osm_id, name, way, leftx) AS  (
	SELECT row_number() OVER(), a.osm_id, a.city_osm_id, a.name, a.way, a.leftx
	FROM anchors a
	UNION
	SELECT s.id, l.osm_id, l.city_osm_id, s.name, l.way, l.leftx
	FROM lines l
	JOIN street_fragments s ON (s.osm_id <> l.osm_id AND s.name = l.name AND s.city_osm_id = l.city_osm_id AND s.leftx < l.leftx AND ST_DWithin(l.way, s.way, 1000))
)
, street_fragments_rels AS (
	SELECT f.*, r.rel_osm_id FROM street_fragments f
	LEFT JOIN import.osm_associated_streets r ON (f.osm_id = r.member_osm_id AND f.name = r.name AND r.role = 'street')
)
, street_fragments_groups AS (
    SELECT
		s.id,
	    s.name,
	    s.city_osm_id,
		array_remove(array_agg(DISTINCT s.rel_osm_id), NULL) AS rel_osm_ids,
		ST_Union(way) AS way,
        array_agg(s.osm_id) AS osm_ids
    FROM street_fragments_rels s
	GROUP BY id, name, city_osm_id
)
SELECT DISTINCT s.id,
   s.name,
   rel_osm_ids,
   osm_ids,
   s.city_osm_id,
   ST_Area(cit.way) AS city_area,
   r.tags,
   ST_Buffer(s.way, 400) AS way_spot, --400m
   ST_Transform(s.way, 4326) AS way,
   ST_X(ST_Transform(ST_PointOnSurface(s.way), 4326)) AS lon,
   ST_Y(ST_Transform(ST_PointOnSurface(s.way), 4326)) AS lat
FROM street_fragments_groups s
JOIN import.osm_roads r ON (r.osm_id = osm_ids[1])
JOIN city AS cit ON (cit.osm_id = s.city_osm_id);
--SELECT DISTINCT ON (s.id) s.* FROM streets_for_all_cities s; -- TODO: it requires more elegant merge, but acceptable for tests
--JOIN (
--	SELECT id, MAX(city_area) AS city_area
--	FROM streets_for_all_cities
--	GROUP BY id
--) s2 ON (s1.id = s2.id AND s1.city_area = s2.city_area);

DROP INDEX IF EXISTS idx_street_id;
CREATE UNIQUE INDEX idx_street_id ON street (id);
ALTER TABLE street ADD CONSTRAINT pk_street PRIMARY KEY USING INDEX idx_street_id;

DROP INDEX IF EXISTS idx_street_name;
CREATE INDEX idx_street_name ON street (name);

DROP INDEX IF EXISTS idx_street_tags;
CREATE INDEX idx_street_tags
ON street USING GIN (tags);

DROP INDEX IF EXISTS idx_street_rel_osm_ids;
CREATE INDEX idx_street_rel_osm_ids
ON street USING GIN (rel_osm_ids);

DROP INDEX IF EXISTS idx_street_way_spot;
CREATE INDEX idx_street_way_spot
ON public.street USING gist (way_spot);

DROP INDEX IF EXISTS idx_street_city_osm_id;
CREATE INDEX idx_street_city_osm_id ON street (city_osm_id);

DROP INDEX IF EXISTS idx_city_osm_id;
CREATE UNIQUE INDEX idx_city_osm_id ON city (osm_id);

DROP TABLE IF EXISTS building;
CREATE TABLE building AS
WITH RECURSIVE buildings_raw AS (
	SELECT
	   b.osm_id,
	   h.type AS housenumber,
	   COALESCE(b."addr:postcode", h."addr:postcode") AS postcode,
	   b.way,
	   ST_X(ST_PointN(ST_ExteriorRing(ST_Envelope(b.way)),1)) AS leftx,
	   str.id AS street_id
	FROM import.osm_buildings b
	JOIN import.osm_housenumbers h ON ST_Intersects(h.way, b.way) AND b.housenumber = '' AND h."addr:street" <> ''
    JOIN street str ON str.name = h."addr:street" AND ST_Within(b.way, str.way_spot)
	UNION ALL
	SELECT
	   b.osm_id,
	   b.housenumber AS housenumber,
	   b."addr:postcode" AS postcode,
	   b.way,
	   ST_X(ST_PointN(ST_ExteriorRing(ST_Envelope(b.way)),1)) AS leftx,
	   str.id AS street_id
    FROM import.osm_buildings b
    JOIN street str ON str.name = b."addr:street" AND ST_Within(b.way, str.way_spot) AND b.housenumber <> ''
	UNION ALL
	SELECT
	   b.osm_id,
	   b.housenumber,
	   COALESCE(b."addr:postcode", rel."addr:postcode") AS postcode,
	   b.way,
	   ST_X(ST_PointN(ST_ExteriorRing(ST_Envelope(b.way)),1)) AS leftx,
	   str.id AS street_id
    FROM import.osm_buildings b
    JOIN import.osm_associated_streets rel ON (b.osm_id = rel.member_osm_id AND rel.role = 'house')
    JOIN street str ON (rel.rel_osm_id = ANY(str.rel_osm_ids))
)
, buildings_unique AS materialized (
	SELECT DISTINCT ON (osm_id)
		osm_id,
		housenumber,
		postcode,
	   	way,
	   	leftx,
	   	street_id
	FROM buildings_raw
)
, anchors AS materialized (
    SELECT a.osm_id, a.housenumber, a.postcode, a.way, a.leftx, a.street_id
	FROM buildings_unique a
	WHERE NOT EXISTS (
		SELECT 1 FROM buildings_unique b
		WHERE a.osm_id <> b.osm_id AND a.housenumber=b.housenumber AND a.street_id = b.street_id AND a.leftx > b.leftx AND ST_DWithin(b.way, a.way, 100) -- 100m
	)
)
, buildings_renumbered (id, osm_id, housenumber, postcode, way, leftx, street_id) AS (
	SELECT row_number() OVER(), a.osm_id, a.housenumber, a.postcode, a.way, a.leftx, a.street_id
	FROM anchors a
	UNION
	SELECT s.id, l.osm_id, l.housenumber, l.postcode, l.way, l.leftx, l.street_id
	FROM buildings_unique l
	JOIN buildings_renumbered s ON (s.osm_id <> l.osm_id AND s.housenumber=l.housenumber AND s.street_id=l.street_id AND s.leftx <= l.leftx AND ST_DWithin(l.way, s.way, 100))
)
, buildings_joined AS (
	SELECT distinct
	  array_agg(DISTINCT osm_id) AS osm_ids,
	  housenumber,
	  postcode,
	  ST_Union(way) AS way,
	  street_id
	FROM buildings_renumbered
	GROUP BY id, housenumber, street_id, postcode
)
SELECT
    row_number() OVER() AS id,
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
CREATE INDEX idx_buildings_way
    ON public.building USING gist (way);

DROP INDEX IF EXISTS idx_building_id;
CREATE UNIQUE INDEX idx_building_id
    ON public.building (id);

DROP INDEX IF EXISTS idx_building_street_id;
CREATE INDEX idx_building_street_id
    ON public.building (street_id);

DROP INDEX IF EXISTS idx_city_state_osm_id;
CREATE INDEX idx_city_state_osm_id
    ON city (state_osm_id);

DROP INDEX IF EXISTS idx_state_country_osm_id;
CREATE INDEX idx_state_country_osm_id
    ON state (country_osm_id);

ALTER TABLE building ADD CONSTRAINT pk_building PRIMARY KEY USING INDEX idx_building_id;
