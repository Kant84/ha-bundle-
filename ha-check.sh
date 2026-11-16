#!/bin/bash
# Здоров = PostgreSQL отвечает. Проверка роли ЗДЕСЬ НЕ НУЖНА:
# backup всегда в recovery, и при жёсткой проверке роли он никогда не возьмёт VIP
# (реальный баг v3: failover блокировался вечным FAULT).
pg_isready -q -h 127.0.0.1 -p 5432 || exit 1
exit 0
