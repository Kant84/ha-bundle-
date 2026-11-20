#!/bin/bash
# Вызывается keepalived при переходе в MASTER. Делает три вещи:
#   1. STONITH: выключает пир через его ОС по SSH (аппаратного ATX у HP-нод нет,
#      WOL выключать не умеет — он только для включения).
#   2. Не промоутит, пока пир пингуется (защита от split-brain).
#   3. Промоутит postgres и поднимает приложение.
source /etc/ha/ha.env

logger -t ha "STONITH: poweroff peer $PEER_IP via SSH (key /root/.ssh/stonith_off_key)"
ssh -i /root/.ssh/stonith_off_key -o ConnectTimeout=3 -o BatchMode=yes \
    nfc@$PEER_IP "echo nfc | sudo -S poweroff" 2>/dev/null || \
logger -t ha "WARN: SSH poweroff to $PEER_IP failed (host may be already dead)"

# ЗАЩИТА ОТ SPLIT-BRAIN: не промоутим, пока пир жив
sleep 5
if ping -c 2 -W 2 $PEER_IP >/dev/null 2>&1; then
    logger -t ha "FATAL: peer $PEER_IP still alive after STONITH. REFUSING to promote."
    exit 1   # keepalived уведёт ноду в FAULT, VIP не поднимется
fi

if sudo -u postgres psql -tAc "select pg_is_in_recovery()" | grep -q t; then
    logger -t ha "promoting postgres"
    sudo -u postgres pg_ctlcluster 16 main promote
fi

logger -t ha "node is now MASTER, VIP should be here"
cd "$APP_DIR" && docker compose up -d
