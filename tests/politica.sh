#!/usr/bin/env bash
# Prova local da política do servidor `orion` (PPPoE + IPoE) com um FreeRADIUS e um Postgres
# descartáveis. Não fala com nenhum banco nem roteador real.
#
#   tests/politica.sh [caminho/para/orion-isp/worker/radius-sync/schema.sql]
#
# Precisa de: freeradius, freeradius-postgresql, freeradius-utils (radclient) e os binários do
# PostgreSQL (initdb/pg_ctl). Em Debian/Ubuntu: apt-get install freeradius freeradius-postgresql
# freeradius-utils postgresql. Sucesso: termina com "OK: N casos". Falha: lista o caso e sai com 1.
set -euo pipefail

AQUI="$(cd "$(dirname "$0")/.." && pwd)"
SCHEMA="${1:-$AQUI/../orion-isp/worker/radius-sync/schema.sql}"
[ -f "$SCHEMA" ] || { echo "schema.sql não encontrado: $SCHEMA" >&2; exit 2; }
RADDB_ORIG=/etc/freeradius/3.0; [ -f "$RADDB_ORIG/radiusd.conf" ] || RADDB_ORIG=/etc/freeradius
[ -f "$RADDB_ORIG/radiusd.conf" ] || { echo "FreeRADIUS não encontrado em /etc/freeradius" >&2; exit 2; }
PGBIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)"
[ -x "$PGBIN/initdb" ] || { echo "PostgreSQL (initdb) não encontrado" >&2; exit 2; }

T="$(mktemp -d /tmp/orion-radius-XXXXXX)"; chmod 755 "$T"
PGPORT=$((20000 + RANDOM % 20000))
como_pg() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/sh -c "$*"; else sh -c "$*"; fi; }
limpar() {
  [ -f "$T/radius.pid" ] && kill "$(cat "$T/radius.pid")" 2>/dev/null || true
  como_pg "$PGBIN/pg_ctl -D $T/pg -m immediate stop" >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap limpar EXIT

# ---- Postgres com o schema real do radius-sync ----
mkdir "$T/pg"; [ "$(id -u)" = 0 ] && chown postgres "$T/pg"
como_pg "$PGBIN/initdb -D $T/pg -U postgres -A trust --no-sync" >/dev/null
como_pg "$PGBIN/pg_ctl -D $T/pg -o '-p $PGPORT -k $T/pg -c listen_addresses=127.0.0.1' -l $T/pg/pg.log -w start" >/dev/null
SQL() { psql -qAt -h 127.0.0.1 -p "$PGPORT" -U postgres -d freeradius -v ON_ERROR_STOP=1 "$@"; }
psql -q -h 127.0.0.1 -p "$PGPORT" -U postgres -c "CREATE DATABASE freeradius" postgres
SQL -f "$SCHEMA" >/dev/null
SQL >/dev/null <<'SQLEOF'
INSERT INTO orion.nas (id, organization_id, nasname, shortname, secret) VALUES
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1', '127.0.0.1', 'local', 'testing123');
INSERT INTO orion.nas_pools (nas_id, organization_id, nombre, orden) VALUES
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1', 'pool-pppoe', 0);
INSERT INTO orion.accounts (organization_id, username_key, username, password, reply, connection_id, hash, tipo) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'cliente1', 'cliente1', 'senha1',
   '[{"attribute":"Mikrotik-Rate-Limit","value":"10M/10M","op":":="}]', '00000000-0000-0000-0000-000000000001', 'h', 'pppoe'),
  ('00000000-0000-0000-0000-0000000000a1', 'aa:bb:cc:00:11:22', 'AA:BB:CC:00:11:22', '',
   '[{"attribute":"Session-Timeout","value":"1800","op":":="},{"attribute":"Framed-IP-Address","value":"10.20.0.50","op":":="},{"attribute":"Mikrotik-Rate-Limit","value":"20M/20M","op":":="}]',
   '00000000-0000-0000-0000-000000000002', 'h', 'ipoe'),
  ('00000000-0000-0000-0000-0000000000a1', 'aabbcc001133', 'aabbcc001133', 'senha-mac', '[]',
   '00000000-0000-0000-0000-000000000003', 'h', 'pppoe'),
  -- Outro ISP (sem NAS aqui): a MAC dele não vale para este NAS.
  ('00000000-0000-0000-0000-0000000000a2', 'aa:bb:cc:00:11:77', 'AA:BB:CC:00:11:77', '', '[]',
   '00000000-0000-0000-0000-000000000004', 'h', 'ipoe');
SQLEOF

# ---- FreeRADIUS com o raddb deste repositório (mesmos passos do Dockerfile) ----
cp -a "$RADDB_ORIG" "$T/raddb"
( cd "$T/raddb"
  rm -f sites-enabled/* mods-enabled/eap mods-enabled/ntlm_auth mods-enabled/files \
        mods-enabled/detail mods-enabled/detail.log mods-enabled/radutmp mods-enabled/sradutmp \
        mods-enabled/unix mods-enabled/passwd mods-enabled/digest mods-enabled/soh \
        mods-enabled/dynamic_clients mods-enabled/totp mods-enabled/replicate
  sed -i 's/^\(\s*auth\s*=\s*\)no/\1yes/' radiusd.conf
  sed -i 's/^\(\s*proxy_requests\s*=\s*\)yes/\1no/' radiusd.conf
  sed -i 's/^\(\s*\$INCLUDE proxy.conf\)/#\1/' radiusd.conf
  cp "$AQUI/raddb/clients.conf" clients.conf
  cp "$AQUI/raddb/mods-enabled/sql" mods-enabled/sql
  cp "$AQUI/raddb/mods-config/orion-queries.conf" mods-config/orion-queries.conf
  cp "$AQUI/raddb/sites-available/orion" sites-available/orion
  cp "$AQUI/raddb/sites-available/dynamic-clients" sites-available/dynamic-clients
  ln -sf ../sites-available/orion sites-enabled/orion
  ln -sf ../sites-available/dynamic-clients sites-enabled/dynamic-clients
  # Só para a prova: portas altas e sem trocar de usuário.
  AUTH=$((PGPORT + 1)); ACCT=$((PGPORT + 2))
  sed -i "s/port = 1812/port = $AUTH/; s/port = 1813/port = $ACCT/" sites-available/orion
  sed -i 's/^\(\s*\)user = .*/\1#user/; s/^\(\s*\)group = .*/\1#group/' radiusd.conf
)
AUTH=$((PGPORT + 1)); ACCT=$((PGPORT + 2))
chmod -R a+rX "$T/raddb"
DB_HOST=127.0.0.1 DB_PORT=$PGPORT DB_USER=postgres DB_PASSWORD=x DB_NAME=freeradius \
  freeradius -d "$T/raddb" -X >"$T/radius.log" 2>&1 &
echo $! >"$T/radius.pid"
for _ in $(seq 1 50); do grep -q "Ready to process requests" "$T/radius.log" && break; sleep 0.2; done
grep -q "Ready to process requests" "$T/radius.log" || { tail -40 "$T/radius.log"; echo "FreeRADIUS não subiu" >&2; exit 1; }

N=0; FALHAS=0
# caso <nome> <auth|acct> <esperado: texto que deve aparecer na resposta> <atributos...>
caso() {
  local nome="$1" tipo="$2" esperado="$3"; shift 3
  local porta=$AUTH; [ "$tipo" = acct ] && porta=$ACCT
  local saida; saida="$(printf '%s\n' "$@" | radclient -x -r 1 -t 3 "127.0.0.1:$porta" "$tipo" testing123 2>&1 || true)"
  N=$((N + 1))
  local ok=1 e
  IFS='|' read -ra partes <<<"$esperado"
  for e in "${partes[@]}"; do
    if [ "${e#!}" != "$e" ]; then grep -q -- "${e#!}" <<<"$saida" && ok=0
    else grep -q -- "$e" <<<"$saida" || ok=0; fi
  done
  if [ $ok = 1 ]; then echo "ok   $nome"; else FALHAS=$((FALHAS + 1)); echo "FALHA $nome"; echo "$saida" | sed 's/^/      /'; fi
}

PPP=('Service-Type = Framed-User' 'Framed-Protocol = PPP' 'NAS-Port-Type = Ethernet')
DHCP=('NAS-Identifier = "mk"' 'NAS-Port-Type = Ethernet' 'Called-Station-Id = "dhcp-clientes"')

caso "PPPoE PAP com a senha certa"             auth 'Access-Accept|Mikrotik-Rate-Limit = "10M/10M"|Framed-Pool = "pool-pppoe"' 'User-Name = "cliente1"' 'User-Password = "senha1"' "${PPP[@]}"
caso "PPPoE PAP com a senha errada"            auth 'Access-Reject' 'User-Name = "cliente1"' 'User-Password = "errada"' "${PPP[@]}"
caso "PPPoE CHAP"                              auth 'Access-Accept' 'User-Name = "cliente1"' 'CHAP-Password = "senha1"' "${PPP[@]}"
caso "PPPoE usuário inexistente"               auth 'Access-Reject' 'User-Name = "ninguem"' 'User-Password = "x"' "${PPP[@]}"
caso "IPoE: pedido do DHCP com MAC conhecida"  auth 'Access-Accept|Session-Timeout = 1800|Framed-IP-Address = 10.20.0.50|Mikrotik-Rate-Limit = "20M/20M"|!Framed-Pool|!Mikrotik-Group' 'User-Name = "AA:BB:CC:00:11:22"' 'User-Password = ""' "${DHCP[@]}"
caso "IPoE: MAC em outro formato"              auth 'Access-Accept|Framed-IP-Address = 10.20.0.50' 'User-Name = "aa-bb-cc-00-11-22"' 'User-Password = ""' "${DHCP[@]}"
caso "IPoE: MAC sem atributo de senha"         auth 'Access-Accept' 'User-Name = "AA:BB:CC:00:11:22"' "${DHCP[@]}"
caso "IPoE: MAC desconhecida"                  auth 'Access-Reject' 'User-Name = "AA:BB:CC:00:11:99"' 'User-Password = ""' "${DHCP[@]}"
caso "IPoE: MAC de outro ISP"                  auth 'Access-Reject' 'User-Name = "AA:BB:CC:00:11:77"' 'User-Password = ""' "${DHCP[@]}"
caso "MAC IPoE num pedido PPPoE (senha vazia)" auth 'Access-Reject' 'User-Name = "AA:BB:CC:00:11:22"' 'User-Password = ""' "${PPP[@]}"
caso "MAC IPoE num pedido PPPoE CHAP"          auth 'Access-Reject' 'User-Name = "AA:BB:CC:00:11:22"' 'CHAP-Password = ""' "${PPP[@]}"
caso "MAC IPoE num login do roteador"          auth 'Access-Reject' 'User-Name = "AA:BB:CC:00:11:22"' 'User-Password = ""' 'Service-Type = Login-User'
caso "MAC IPoE com senha qualquer"             auth 'Access-Reject' 'User-Name = "AA:BB:CC:00:11:22"' 'User-Password = "abc"' 'NAS-Port-Type = Ethernet'
caso "PPPoE cujo usuário parece uma MAC"       auth 'Access-Accept' 'User-Name = "aabbcc001133"' 'User-Password = "senha-mac"' "${PPP[@]}"
caso "DHCP com usuário PPPoE em forma de MAC"  auth 'Access-Reject' 'User-Name = "aabbcc001133"' 'User-Password = ""' "${DHCP[@]}"
caso "Accounting do lease IPoE"                acct 'Accounting-Response' 'Acct-Status-Type = Start' 'Acct-Session-Id = "d1"' 'User-Name = "AA:BB:CC:00:11:22"' 'Framed-IP-Address = 10.20.0.50' "${DHCP[@]}"
caso "Accounting de uma sessão PPPoE"          acct 'Accounting-Response' 'Acct-Status-Type = Start' 'Acct-Session-Id = "p1"' 'User-Name = "cliente1"' 'Framed-IP-Address = 100.64.0.2' "${PPP[@]}"

confere() { N=$((N + 1)); if [ "$(SQL -c "$2")" = "$3" ]; then echo "ok   $1"; else FALHAS=$((FALHAS + 1)); echo "FALHA $1: $(SQL -c "$2")"; fi; }
confere "sessão IPoE ligada à conexão da MAC"   "SELECT connection_id FROM orion.sessions WHERE username = 'AA:BB:CC:00:11:22'" "00000000-0000-0000-0000-000000000002"
confere "sessão PPPoE ligada à conexão"         "SELECT connection_id FROM orion.sessions WHERE username = 'cliente1'" "00000000-0000-0000-0000-000000000001"
confere "log: aceites da MAC ligados à conexão" "SELECT count(*) FROM orion.auth_log WHERE resultado = 'Access-Accept' AND connection_id = '00000000-0000-0000-0000-000000000002'" "3"
confere "log: recusas registradas"              "SELECT count(*) > 0 FROM orion.auth_log WHERE resultado = 'Access-Reject'" "t"

if [ $FALHAS -gt 0 ]; then echo "FALHOU: $FALHAS de $N casos"; tail -5 "$T/radius.log"; exit 1; fi
echo "OK: $N casos"
