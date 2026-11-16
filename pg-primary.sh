#!/bin/bash
# Первичная настройка PostgreSQL 16 на ноде. Безопасен для повторного запуска (grep-гварды).
set -e
source /etc/ha/ha.env
PGVER=16
CONF=/etc/postgresql/$PGVER/main
# '*' — чтобы переживать смены ролей (репликация приходит по LAN с пира).
# Доступ режет pg_hba: только локально + реплика с PEER_IP.
grep -q "^listen_addresses" $CONF/postgresql.conf || echo "listen_addresses = '*'" >> $CONF/postgresql.conf
grep -q "^wal_level" $CONF/postgresql.conf || echo "wal_level = replica" >> $CONF/postgresql.conf
grep -q "^max_wal_senders" $CONF/postgresql.conf || echo "max_wal_senders = 10" >> $CONF/postgresql.conf
grep -q "^hot_standby" $CONF/postgresql.conf || echo "hot_standby = on" >> $CONF/postgresql.conf
grep -q "^wal_log_hints" $CONF/postgresql.conf || echo "wal_log_hints = on" >> $CONF/postgresql.conf
# репликация с пира (и с себя — на случай обратного failover)
grep -q "replication replicator $PEER_IP" $CONF/pg_hba.conf || \
    echo "host replication replicator $PEER_IP/32 scram-sha-256" >> $CONF/pg_hba.conf
# пользователь репликации (без DO-блока — простая двухшаговая проверка)
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='replicator'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE ROLE replicator LOGIN REPLICATION PASSWORD '$PG_REPL_PASS';"
sudo -u postgres psql -c "SELECT pg_create_physical_replication_slot('ha_slot') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='ha_slot');"
systemctl restart postgresql
sleep 3
sudo -u postgres psql -c "select pg_is_in_recovery();"   # ожидаем: f (или t, если нода уже была репликой)
echo "pg-primary: готово. Для превращения в реплику запусти pg-replica.sh на ДРУГОЙ ноде."
