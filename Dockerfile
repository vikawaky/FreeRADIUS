# FreeRADIUS do Orion (PPPoE: PAP, CHAP, MS-CHAP) com Postgres.
# Contas, NAS e accounting ficam no schema `orion` do banco do FreeRADIUS,
# alimentado pelo worker radius-sync do Orion. Multi-ISP: o NAS (IP de origem
# do pacote) define de qual ISP é cada requisição.
FROM freeradius/freeradius-server:3.2.10

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends freeradius-postgresql postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Só o necessário para PPPoE + SQL. Sem EAP/inner-tunnel nem arquivos locais.
RUN cd /etc/freeradius \
 && rm -f sites-enabled/* mods-enabled/eap mods-enabled/ntlm_auth mods-enabled/files \
          mods-enabled/detail mods-enabled/detail.log mods-enabled/radutmp mods-enabled/sradutmp \
          mods-enabled/unix mods-enabled/passwd mods-enabled/digest mods-enabled/soh \
          mods-enabled/dynamic_clients mods-enabled/totp mods-enabled/replicate \
 && sed -i 's/^\(\s*auth\s*=\s*\)no/\1yes/' radiusd.conf \
 && sed -i 's/^\(\s*proxy_requests\s*=\s*\)yes/\1no/' radiusd.conf \
 && sed -i 's/^\(\s*\$INCLUDE proxy.conf\)/#\1/' radiusd.conf

COPY raddb/clients.conf /etc/freeradius/clients.conf
COPY raddb/mods-enabled/sql /etc/freeradius/mods-enabled/sql
COPY raddb/mods-config/orion-queries.conf /etc/freeradius/mods-config/orion-queries.conf
COPY raddb/sites-available/orion /etc/freeradius/sites-available/orion
COPY raddb/sites-available/dynamic-clients /etc/freeradius/sites-available/dynamic-clients
RUN ln -sf ../sites-available/orion /etc/freeradius/sites-enabled/orion \
 && ln -sf ../sites-available/dynamic-clients /etc/freeradius/sites-enabled/dynamic-clients

EXPOSE 1812/udp 1813/udp
