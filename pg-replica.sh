#!/bin/bash
# Сделать эту ноду репликой пира (PEER_IP из ha.env). Затирает локальный кластер!
set -e
source /etc/ha/ha.env
PGVER=16
systemctl stop postgresql
rm -rf /var/lib/postgresql/$PGVER/main
sudo -u postgres pg_basebackup -h $PEER_IP -U replicator -P -R -S ha_slot -X stream -D /var/lib/postgresql/$PGVER/main
systemctl start postgresql
sleep 5
sudo -u postgres psql -c "select pg_is_in_recovery();"   # ожидаем: t
echo "REPLICA готова, источник: $PEER_IP"
