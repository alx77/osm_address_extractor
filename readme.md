# osm_address_extractor
This is *postgis* & *imposm3* & *docker* based script which extracts addresses in the following relational schema
```
country->state->city->street->building
```
Run *./run.sh* and select country.
As a result you'll find a sql file in *results* folder.
There are many things to improve, feel free to do this.

## License
This is open source software under the GPL v3 license, see the LICENSE file in the project root for the full license text.
