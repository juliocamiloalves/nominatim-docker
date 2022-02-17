#!/bin/bash -ex

OSMFILE=${PROJECT_DIR}/data.osm.pbf

if [ "$IMPORT_WIKIPEDIA" = "true" ]; then
  echo "Downloading Wikipedia importance dump"
  curl https://nominatim.org/data/wikimedia-importance.sql.gz -L -o ${PROJECT_DIR}/wikimedia-importance.sql.gz
else
  echo "Skipping optional Wikipedia importance import"
fi;

if [ "$IMPORT_GB_POSTCODES" = "true" ]; then
  curl https://nominatim.org/data/gb_postcode_data.sql.gz -L -o ${PROJECT_DIR}/gb_postcode_data.sql.gz
else
  echo "Skipping optional GB postcode import"
fi;

if [ "$IMPORT_US_POSTCODES" = "true" ]; then
  curl https://nominatim.org/data/us_postcode_data.sql.gz -L -o ${PROJECT_DIR}/us_postcode_data.sql.gz
else
  echo "Skipping optional US postcode import"
fi;

if [ "$IMPORT_US_TIGER" = "true" ]; then
  curl https://nominatim.org/data/${US_TIGER_FILE:-tiger-nominatim-preprocessed-latest.csv.tar.gz} -L -o ${PROJECT_DIR}/${US_TIGER_FILE:-tiger-nominatim-preprocessed-latest.csv.tar.gz}
else
  echo "Skipping optional US Tiger import"
fi;

if [ "$PBF_URL" != "" ]; then
  echo Downloading OSM extract from "$PBF_URL"
  curl -L "$PBF_URL" --create-dirs -o $OSMFILE
fi

if [ "$PBF_PATH" != "" ]; then
  echo Reading OSM extract from "$PBF_PATH"
  OSMFILE=$PBF_PATH
fi


# if we use a bind mount then the PG directory is empty and we have to create it
if [ ! -f /var/lib/postgresql/12/main/PG_VERSION ]; then
  chown postgres /var/lib/postgresql/12/main
  sudo -u postgres /usr/lib/postgresql/12/bin/initdb -D /var/lib/postgresql/12/main
fi

sudo service postgresql start && \
sudo -u postgres psql postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='nominatim'" | grep -q 1 || sudo -u postgres createuser -s nominatim && \
sudo -u postgres psql postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='www-data'" | grep -q 1 || sudo -u postgres createuser -SDR www-data && \

sudo -u postgres psql postgres -tAc "ALTER USER nominatim WITH ENCRYPTED PASSWORD '$NOMINATIM_PASSWORD'" && \
sudo -u postgres psql postgres -tAc "ALTER USER \"www-data\" WITH ENCRYPTED PASSWORD '${NOMINATIM_PASSWORD}'" && \

sudo -u postgres psql postgres -c "DROP DATABASE IF EXISTS nominatim"

chown -R nominatim:nominatim ${PROJECT_DIR}

cd ${PROJECT_DIR}
sudo -E -u nominatim nominatim import --osm-file $OSMFILE --threads $THREADS
sudo -E -u nominatim nominatim admin --check-database

if [ "$IMPORT_US_TIGER" = "true" ]; then
  cd ${PROJECT_DIR}
  sudo -E -u nominatim nominatim add-data --tiger-data ${US_TIGER_FILE:-tiger-nominatim-preprocessed-latest.csv.tar.gz}
  sudo -E -u nominatim nominatim refresh --functions
  echo NOMINATIM_USE_US_TIGER_DATA=yes >> .env
fi

if [ "$REPLICATION_URL" != "" ]; then
  sudo -E -u nominatim nominatim replication --init
fi

sudo service postgresql stop

# Remove slightly unsafe postgres config overrides that made the import faster
rm /etc/postgresql/12/main/conf.d/postgres-import.conf

echo "Deleting downloaded dumps in ${PROJECT_DIR}"
rm -f ${PROJECT_DIR}/*sql.gz ${PROJECT_DIR}/*csv.tar.gz

# nominatim needs the tokenizer configuration in the project directory to start up
# but when you start the container with an already imported DB then you don't have this config.
# that's why we save it in /var/lib/postgresql and copy it back if we need it.
# this is of course a terrible hack but there is hope that 4.1 provides a way to restore this
# configuration cleanly.
# More reading: https://github.com/mediagis/nominatim-docker/pull/274/
cp -r ${PROJECT_DIR}/tokenizer /var/lib/postgresql/12/main

if [ "$PBF_URL" != "" ]; then
  rm -f ${OSMFILE}
fi
