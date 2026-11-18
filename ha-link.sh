#!/bin/bash
# Двойная проверка линка: карта поднята + шлюз отвечает.
# Изолированная нода (свой линк/сегмент мёртв) НЕ возьмёт VIP.
source /etc/ha/ha.env
ip link show "$HA_IFACE" | grep -q "state UP" || exit 1
GW=$(ip route show default | awk '/default/ {print $3; exit}')
[ -n "$GW" ] || exit 1
ping -c1 -W1 "$GW" >/dev/null 2>&1 || exit 1
exit 0
