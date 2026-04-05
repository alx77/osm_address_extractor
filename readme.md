# osm_address_extractor

PostGIS + imposm3 + Docker pipeline that extracts addresses from OpenStreetMap PBF files into a relational schema:

```
country → state → city → street → building
```

Each street gets an `importance` score (logarithmic population scale, 0–1) and the most common `postcode` from its buildings.

## Requirements

- Docker (or Podman — see notes below)
- `dialog` package for the country selection menu
- `imposm-0.14.2-linux-x86-64.tar.gz` placed in the project root before the first build
  (download from https://github.com/omniscale/imposm3/releases/tag/v0.14.2)

## Usage

```bash
./run.sh          # shows country selection menu, builds image if needed, runs extraction
```

Results are written to `./results/osm_addresses_<CC>/` as a **pg_dump directory format** archive (4 parallel jobs). Downloaded PBF files are cached in `./cache/` for 3 days.

## Setting up the destination database

Run once before restoring:

```bash
./init-gis-db.sh [host] [port] [user]
# defaults: host=storage.service, port=5432, user=postgres
```

Then restore:

```bash
pg_restore -Fd -j 4 -h <host> -p <port> -U <user> -d gis \
    --no-owner --no-privileges results/osm_addresses_<CC>
```

Multiple countries can be restored into the same `gis` database — each extraction produces independent rows.

## Podman rootless note

Podman rootless ignores `--shm-size`, which prevents PostgreSQL from using parallel workers during extraction. To work around this, uncomment `SET max_parallel_workers_per_gather = 0;` at the top of `osm_addresses_extractor.sql` before building the image.

On a proper Docker host the default settings work fine and parallel workers are used automatically.

## Output schema

| Table    | Key columns |
|----------|-------------|
| country  | osm_id, name, way, lon, lat |
| state    | osm_id, name, country_osm_id, way, lon, lat |
| city     | osm_id, name, place, postal_code, state_osm_id, way, lon, lat |
| street   | id, name, city_osm_id, importance, postcode, way, lon, lat |
| building | id, osm_ids, street_id, housenumber, postcode, way, lon, lat |

## License

GPL v3
