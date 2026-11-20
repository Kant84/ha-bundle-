#!/bin/bash
# Возврат отремонтированной ноды в строй: пересоздание реплики с нуля через pg_basebackup.
# Работает всегда — в отличие от pg_rewind, которому нужны data checksums / wal_log_hints,
# включённые ДО расхождения. БД маленькая (десятки МБ), копия занимает секунды.
# ВНИМАНИЕ: локальные данные ноды УНИЧТОЖАЮТСЯ и заменяются копией мастера (PEER_IP).
set -e
source /etc/ha/ha.env
PGVER=16
PGDATA=/var/lib/postgresql/$PGVER/main

systemctl stop postgresql

export PGPASSWORD=$PG_REPL_PASS
# Слот ha_slot на мастере: создать, если отсутствует
sudo -E -u postgres psql -h $PEER_IP -U replicator -d postgres -tAc \
  "select 1 from pg_replication_slots where slot_name='ha_slot'" | grep -q 1 || \
sudo -E -u postgres psql -h $PEER_IP -U replicator -d postgres -c \
  "select pg_create_physical_replication_slot('ha_slot');"

rm -rf $PGDATA
sudo -E -u postgres pg_basebackup -h $PEER_IP -U replicator -D $PGDATA -P -R -X stream -S ha_slot

# -R пишет primary_conninfo БЕЗ пароля, а ALTER SYSTEM недоступен при остановленном
# postgres — дописываем полный primary_conninfo напрямую в postgresql.auto.conf
# (последняя строка с параметром побеждает).
CONF=$PGDATA/postgresql.auto.conf
sudo sed -i "/^primary_conninfo\s*=/d" "$CONF"
echo "primary_conninfo = 'host=$PEER_IP port=5432 user=replicator password=$PG_REPL_PASS application_name=$(hostname)'" | \
  sudo tee -a "$CONF" >/dev/null

systemctl start postgresql
sleep 8
sudo -u postgres psql -tAc "select pg_is_in_recovery();"   # ожидаем: t
echo "Готово. Нода — реплика $PEER_IP."
