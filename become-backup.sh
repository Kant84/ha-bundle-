#!/bin/bash
source /etc/ha/ha.env
# Не трогаем приложение при первом переходе в BACKUP (старте keepalived) —
# notify_backup вызывается и при старте службы.
STATE_FILE=/run/ha-was-master
if [ -f "$STATE_FILE" ]; then
    logger -t ha "node LOST master role, stopping app"
    if [ -f $APP_DIR/docker-compose.yml ]; then
        cd $APP_DIR && /usr/bin/docker compose stop 2>/dev/null || true
    fi
    rm -f "$STATE_FILE"
else
    logger -t ha "node is BACKUP (initial start), app left as-is"
fi
