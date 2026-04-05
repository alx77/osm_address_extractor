FROM postgres:18

ENV DEBIAN_FRONTEND=noninteractive

RUN set -x \
&& apt-get -q update \
&& apt-get -y install --no-install-recommends \
 curl \
 wget \
 procps \
 postgresql-18-postgis-3 \
 postgresql-18-postgis-3-scripts \
&& rm -rf /var/lib/apt/lists/*

COPY imposm-0.14.2-linux-x86-64.tar.gz /tmp/imposm3.tar.gz
RUN mkdir imposm3 \
&& tar -xzf /tmp/imposm3.tar.gz \
&& mv imposm-0.14.2-linux-x86-64/* imposm3 \
&& rm /tmp/imposm3.tar.gz

COPY mapping.yaml /imposm3/mapping.yaml
COPY osm_addresses_extractor.sql /osm_addresses_extractor.sql
COPY extract.sh /extract.sh
RUN chmod +x /extract.sh
