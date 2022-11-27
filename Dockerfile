FROM postgres:15.1

ENV DEBIAN_FRONTEND=noninteractive
# ARG DB_NAME=gis
# ARG DB_HOST=storage
# ARG DB_USER=gis
# ARG DB_PASSWORD

RUN set -x \
&& apt-get -q update \
&& apt-get -y install \
 bash \
 curl \
 wget \
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

# RUN mv /tmp/renderd.conf /usr/local/etc/renderd.conf \
# && mv /tmp/tile.conf /tmp/tile.load /etc/apache2/mods-available \
# && a2enmod tile


# Add apache to run and configure
# RUN sed -i "s/#LoadModule\ rewrite_module/LoadModule\ rewrite_module/" /etc/apache2/httpd.conf \
#     && sed -i "s/#LoadModule\ session_module/LoadModule\ session_module/" /etc/apache2/httpd.conf \
#     && sed -i "s/#LoadModule\ session_cookie_module/LoadModule\ session_cookie_module/" /etc/apache2/httpd.conf \
#     && sed -i "s/#LoadModule\ session_crypto_module/LoadModule\ session_crypto_module/" /etc/apache2/httpd.conf \
#     && sed -i "s/#LoadModule\ deflate_module/LoadModule\ deflate_module/" /etc/apache2/httpd.conf \
#     && sed -i "s#^DocumentRoot \".*#DocumentRoot \"/app/web\"#g" /etc/apache2/httpd.conf \
#     && sed -i "s#/var/www/localhost/htdocs#/app/web#" /etc/apache2/httpd.conf \
#     && sed -i "s/ErrorLog\ logs\/error.log/ErrorLog\ \/proc\/self\/fd\/2/" /etc/apache2/httpd.conf \
#     && sed -i "s/CustomLog\ logs\/access.log\ combined/CustomLog\ \/proc\/self\/fd\/1\ common/" /etc/apache2/httpd.conf \
#     && printf "\n<Directory \"/app/web\">\n\tAllowOverride All\n</Directory>\n" >> /etc/apache2/httpd.conf

# RUN mkdir -p /var/run/renderd /nfs \
# && mkdir src \
# && cd src \
# && git clone git://github.com/openstreetmap/mod_tile.git \
# && cd ./mod_tile \
# && ./autogen.sh \
# && ./configure \
# && make -j $(nproc)\
# && make install \
# && make install-mod_tile \
# && ldconfig

# RUN mkdir -p /usr/local/share/maps/style \
# && cd /usr/local/share/maps/style \
# && wget -q https://github.com/mapbox/osm-bright/archive/master.zip \
# && wget -q https://osmdata.openstreetmap.de/download/simplified-land-polygons-complete-3857.zip \
# && wget -q https://osmdata.openstreetmap.de/download/land-polygons-split-3857.zip \
# && wget -q http://www.qgistutorials.com/downloads/ne_10m_populated_places_simple.zip

# RUN sed -i "s/ErrorLog\ \${APACHE_LOG_DIR}\/error.log/ErrorLog\ \/proc\/self\/fd\/2/" /etc/apache2/sites-available/000-default.conf \
# && sed -i "s/CustomLog\ \${APACHE_LOG_DIR}\/access.log\ combined/CustomLog\ \/proc\/self\/fd\/1\ common/" /etc/apache2/sites-available/000-default.conf \
# && sed -i "s/Include\ ports.conf/Include\ ports.conf\nServerName\ localhost/" /etc/apache2/apache2.conf
