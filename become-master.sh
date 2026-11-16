#!/bin/bash
source /etc/ha/ha.env
logger -t ha "STONITH: poweroff peer via BliKVM $BLIKVM_IP (peer=$PEER_IP)"
ssh -i /root/.ssh/blikvm_stonith -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
    root@$BLIKVM_IP "python3 -c \"import socket;m=bytes.fromhex('$(echo $BLIKVM_PEER_MAC | tr -d :)');s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1);s.sendto(b'\\xff'*6+m*16,('255.255.255.255',9))\"; sleep 8; python3 -c \"import socket;m=bytes.fromhex('$(echo $BLIKVM_PEER_MAC | tr -d :)');s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1);s.sendto(b'\\xff'*6+m*16,('255.255.255.255',9))\"" 2>/dev/null || true
# Защита от split-brain: не промоутим, пока пир жив
sleep 5
if ping -c 2 -W 2 $PEER_IP >/dev/null 2>&1; then
    logger -t ha "FATAL: peer $PEER_IP still alive after STONITH. REFUSING to promote."
    exit 1
fi
if sudo -u postgres psql -tAc "select pg_is_in_recovery()" | grep -q t; then
    logger -t ha "promoting postgres"
    sudo -u postgres pg_ctlcluster 16 main promote
    sleep 2
fi
if [ -f $APP_DIR/docker-compose.yml ]; then
    logger -t ha "starting app"
    cd $APP_DIR && /usr/bin/docker compose up -d
fi
touch /run/ha-was-master
logger -t ha "node is now MASTER, VIP should be here"
