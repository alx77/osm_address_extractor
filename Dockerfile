FROM postgres:15.1

ENV DEBIAN_FRONTEND=noninteractive

RUN set -x \
&& apt-get -q update \
&& apt-get -y install \
 bash \
 curl \
 procps \
 postgresql-contrib \
 postgresql-postgis

RUN mkdir imposm3 \
&& wget -q https://github.com/omniscale/imposm3/releases/download/v0.11.1/imposm-0.11.1-linux-x86-64.tar.gz \
&& tar -xvzf imposm-0.11.1-linux-x86-64.tar.gz \
&& mv imposm-0.11.1-linux-x86-64/* imposm3

COPY mapping.yaml /imposm3/mapping.yaml
COPY osm_addresses_extractor.sql /osm_addresses_extractor.sql
COPY extract.sh /extract.sh
RUN chmod +x /extract.sh
