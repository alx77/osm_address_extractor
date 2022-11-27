# osm_address_extractor
This is *postgis* & *imposm3* & *docker* based script which extracts addresses from OSM pbf files to the following relational schema
```
country->state->city->street->building
```
Run *./run.sh* and select country.
As a result you'll find an sql file in *results* folder. Use *pg_restore* utility to upload it to your Postgres (with Postgis & hstore extensions installed).
There are many things to improve, feel free to do this.

## License
This is open source software under the GPL v3 license.
