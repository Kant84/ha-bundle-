#!/bin/bash
# Суточный pg_dump -> NFS-шара NAS (слой бэкапов поверх HA-кластера).
# Требования: NAS развёрнут (RAID 1, NFS), смонтирован в /mnt/backup-db (fstab, _netdev).
# Подробности: раздел README "Бэкапы на NAS".
set -e
source /etc/ha/ha.env
TS=$(date +%Y%m%d_%H%M%S)
DST=/mnt/backup-db
KEEP_DAYS=30

# Дамп только с ноды, где postgres PRIMARY
if sudo -u postgres psql -tAc "select pg_is_in_recovery()" | grep -q f; then
  sudo -u postgres pg_dump -Fc -f "$DST/pg_dump_$TS.dump" postgres
  # Ротация: оставить KEEP_DAYS последних дампов
  ls -1t $DST/pg_dump_*.dump | tail -n +$((KEEP_DAYS+1)) | xargs -r rm -f
  echo "OK: $DST/pg_dump_$TS.dump"
else
  echo "SKIP: не primary, дамп делает мастер"
fi
