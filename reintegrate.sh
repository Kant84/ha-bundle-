#!/bin/bash
# Возврат отремонтированной ноды в строй как реплики текущего мастера (PEER_IP).
set -e
source /etc/ha/ha.env
PGVER=16
PGDATA=/var/lib/postgresql/$PGVER/main
REWIND=/usr/lib/postgresql/$PGVER/bin/pg_rewind

systemctl stop postgresql

# rewind соединяется с мастером; pg_hba мастера должен разрешать репликацию с нас
export PGPASSWORD=$PG_REPL_PASS
sudo -E -u postgres $REWIND --target-pgdata=$PGDATA \
    --source-server="host=$PEER_IP port=5432 user=replicator dbname=postgres" -R -P

# pg_rewind -R пишет primary_conninfo с user из source-server — выставляем явно
sudo -u postgres psql -c "ALTER SYSTEM SET primary_conninfo = 'host=$PEER_IP port=5432 user=replicator password=$PG_REPL_PASS application_name=$(hostname)';" 2>/dev/null || true

systemctl start postgresql
sleep 5
sudo -u postgres psql -c "select pg_is_in_recovery();"   # ожидаем: t
echo "Готово. Нода — реплика $PEER_IP. Убедись, что keepalived-priority этой ноды НИЗКИЙ."
