FROM freeradius/freeradius-server:3.2.10

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends freeradius-postgresql postgresql-client \
    && rm -rf /var/lib/apt/lists/*

COPY raddb/mods-enabled/sql /etc/freeradius/mods-enabled/sql
