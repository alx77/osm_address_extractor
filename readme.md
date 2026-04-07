# osm_address_extractor

Docker pipeline that extracts addresses from OpenStreetMap PBF files into a relational schema:

```
country → state → city → street → building
```

Each street gets an `importance` score (logarithmic population scale, 0–1) derived from city
population and Wikidata importance data. Buildings are linked to streets with housenumber and
postcode.

## Requirements

- Docker (or Podman)
- `wget`, `dialog` (for interactive country menu)

`imposm3` is downloaded automatically on first run.

## Quick start

```bash
# Interactive menu — pick a country and run extraction
./run.sh

# Extract one country directly
./run.sh UA

# Extract multiple countries in sequence
./run.sh UA DE PL
```

Results are written to `./results/osm_addresses_<CC>/` as a **pg_dump directory format** archive.
Downloaded PBF files are cached in `./cache/` for 3 days and reused on subsequent runs.

## Restoring to the production database

Initialize the schema once (only needed on a fresh database):

```bash
./init-gis-db.sh [host] [port] [user]
# defaults: host=storage.service, port=5432, user=postgres
```

Restore a country:

```bash
./restore.sh UA
./restore.sh DE storage.service 5432 postgres
```

Multiple countries can be restored independently — OSM IDs are globally unique, so there are no
conflicts between countries. `data_source` is excluded from the dump and already seeded by
`init-gis-db.sh`.

## Typical workflow

```bash
# New country — extract and restore
./run.sh PL
./restore.sh PL storage.service 5432 postgres

# Re-extract an existing country (overwrites previous dump, then restore again)
./run.sh UA
./restore.sh UA storage.service 5432 postgres
```

Row counts are printed by `restore.sh` automatically after each restore.

## Podman rootless note

Podman rootless ignores `--shm-size`, which prevents PostgreSQL from using parallel workers.
To work around this, uncomment `SET max_parallel_workers_per_gather = 0;` at the top of
`osm_addresses_extractor.sql` before building the image.

On a proper Docker host the default settings work fine.

## Output schema

| Table    | Key columns                                                        |
|----------|--------------------------------------------------------------------|
| country  | osm_id, name, tags, way, lon, lat                                  |
| state    | osm_id, name, country_osm_id, tags, way, lon, lat                  |
| city     | osm_id, name, place, state_osm_id, importance, tags, way, lon, lat |
| street   | id, name, city_osm_id, importance, postcodes, tags, way, lon, lat  |
| building | id, street_id, osm_ids, housenumber, postcode, way, lon, lat       |

## Supported countries

Europe: AL AD AT BY BE BG HR CZ DK FI FR GE DE GB GR HU IT LV LT LU MD MC ME NL NO PL PT RO RU RS SK SI ES SE CH TR UA

Middle East: IL

## License

GPL v3
