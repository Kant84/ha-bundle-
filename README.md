# ha-bundle v4 — отказоустойчивая пара серверов

Актив-пассивный кластер из двух машин: единый виртуальный IP (VRRP/keepalived),
PostgreSQL 16 streaming replication, автоматический промоут при отказе,
аппаратный STONITH через BliKVM (защита от split-brain). Слот под приложение (Docker Compose).

**Проверено в бою:** убийство питания мастера → сервис восстановлен на второй ноде за ~20 секунд с теми же данными.

```
                    клиенты (приложение/мобильные)
                            │
                            ▼
                    VIP: 192.168.88.50  ←─ единственный адрес для клиентов
                            │
        ┌───────────────────┴───────────────────┐
        │                                       │
   itconnect (MASTER)                     itconnect1 (BACKUP)
   192.168.88.43                           192.168.88.45
   PostgreSQL PRIMARY                      PostgreSQL REPLICA (always-on)
   keepalived prio 150                   keepalived prio 100 (nopreempt)
   приложение в /opt/app                  приложение остановлено
        │                                       │
   BliKVM №1 (.44)                        BliKVM №2 (.42)
   ─ управляет itconnect1:                ─ управляет itconnect:
     STONITH убивает .45                   STONITH убивает .43
```

Роли MASTER/BACKUP после первого failover поменялись местами (мастером стал itconnect) —
это нормально: `nopreempt` не даёт VIP прыгать обратно. Операционно роли равнозначны.

---

## 0. Требования

| Что | Минимум |
|---|---|
| Серверы | 2 машины, Ubuntu 22.04/24.04, одна L2-сеть (офис) |
| Сеть | Статические IP у обеих нод; VIP свободен в подсети |
| BliKVM | По одному на каждый сервер (консоль + управление питанием) — иначе STONITH не работает |
| Доступ | sudo на обеих нодах |

> ⚠️ VRID (77) должен быть уникален в сегменте. Узнать, кто уже шлёт VRRP:
> `sudo tcpdump -ni eno1 vrrp -c 5` — если виден чужой vrid (напр. 51 от Mikrotik) — поменяйте `virtual_router_id` в обоих конфигах на уникальный.

---

## 1. Установка с Git

На **КАЖДОЙ** ноде:

```bash
sudo apt update && sudo apt install -y git
cd /root && git clone https://github.com/Kant84/ha-bundle-.git
cd ha-bundle-
ls
```

**Ожидаемый вывод:**
```
become-backup.sh  become-master.sh  ha-check.sh
ha.env.itconnect  ha.env.itconnect1
keepalived.conf.backup  keepalived.conf.master
pg-primary.sh  pg-replica.sh  reintegrate.sh  README.md
```

### Пакеты (обе ноды)

```bash
sudo apt install -y keepalived postgresql-16 docker.io docker-compose-v2
```

> Ubuntu 24.04: пакет называется `docker-compose-v2` (даёт `docker compose`).
> Проверка: `docker compose version` → `Docker Compose version v2.x`.

**Ожидаемые маркеры:**
```bash
id postgres          # uid=110(postgres) ...
systemctl status postgresql --no-pager | head -3   # active
```

---

## 2. Настройка ha.env (обе ноды, РАЗНЫЕ файлы)

На каждой ноде свой файл — значения указывают на **соседа**:

```bash
sudo mkdir -p /etc/ha /opt/app

# на itconnect (192.168.88.43):
sudo cp ~/ha-bundle-/ha.env.itconnect /etc/ha/ha.env

# на itconnect1 (192.168.88.45):
sudo cp ~/ha-bundle-/ha.env.itconnect1 /etc/ha/ha.env
```

Отредактируй на каждой ноде: `sudo nano /etc/ha/ha.env`

| Параметр | itconnect (.43) | itconnect1 (.45) | Что это |
|---|---|---|---|
| `PEER_IP` | 192.168.88.45 | 192.168.88.43 | IP соседа (ping-проверка смерти) |
| `BLIKVM_IP` | 192.168.88.44 | 192.168.88.42 | BliKVM, управляющий **соседом** |
| `BLIKVM_PEER_MAC` | 40:b0:34:f5:6f:f0 | 18:60:24:fa:47:22 | MAC соседа (для magic-пакета) |
| `PG_REPL_PASS` | одинаковый на обеих | одинаковый | пароль репликации |

IP BliKVM смотри на его OLED-экранчике или: `sudo arp-scan --localnet | grep -i raspberry`.

**Как понять, какой BliKVM чей** (без видео), с любой ноды:
```bash
for ip in <IP_BliKVM_1> <IP_BliKVM_2>; do
  echo "== $ip =="; ssh root@$ip "hostname; grep -rh 'MAC=' /data/work 2>/dev/null | sort -u"
done
```
MAC из вывода = MAC управляемой этим BliKVM машины.

---

## 3. STONITH: ключи для аппаратного выключения соседа

На **обеих** нодах:

```bash
sudo ssh-keygen -t ed25519 -f /root/.ssh/blikvm_stonith -N ""
sudo cat /root/.ssh/blikvm_stonith.pub
```

Публичный ключ **каждой** ноды → в `~/.ssh/authorized_keys` **чужого** BliKVM:

```bash
# на itconnect1: ключ → BliKVM itconnect (.42)
sudo cat /root/.ssh/blikvm_stonith.pub | ssh root@192.168.88.42 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
# на itconnect: ключ → BliKVM itconnect1 (.44)
sudo cat /root/.ssh/blikvm_stonith.pub | ssh root@192.168.88.44 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

Проверка (обязательно без пароля):

```bash
# на itconnect1:
sudo ssh -i /root/.ssh/blikvm_stonith -o BatchMode=yes -o StrictHostKeyChecking=no root@192.168.88.42 "echo STONITH_OK"
# на itconnect:
sudo ssh -i /root/.ssh/blikvm_stonith -o BatchMode=yes -o StrictHostKeyChecking=no root@192.168.88.44 "echo STONITH_OK"
```

**Ожидаемый вывод (обе команды):** `STONITH_OK`

---

## 4. PostgreSQL: мастер → реплика

Сначала мастер, потом реплика.

### 4.1 На будущем мастере (itconnect1, .45) при первичной установке:

```bash
sudo bash ~/ha-bundle-/pg-primary.sh
```

**Ожидаемый вывод:**
```
 pg_is_in_recovery
-------------------
 f
(1 row)
pg-primary: готово. ...
```
(скрипт идемпотентен — повторный запуск не портит конфиг)

### 4.2 На будущей реплике (itconnect, .43):

```bash
sudo bash ~/ha-bundle-/pg-replica.sh
```

**Ожидаемый вывод:** прогресс `pg_basebackup` до 100%, затем:
```
 pg_is_in_recovery
-------------------
 t
(1 row)
REPLICA готова, источник: 192.168.88.45
```

### 4.3 Проверка репликации (на мастере)

```bash
sudo -u postgres psql -c "select client_addr, state from pg_stat_replication;"
sudo -u postgres psql -c "select slot_name, active from pg_replication_slots;"
```

**Ожидаемый вывод:**
```
  client_addr  |   state
---------------+-----------
 192.168.88.43 | streaming        ← IP реплики

 slot_name | active
-----------+--------
 ha_slot   | t
```

---

## 5. Скрипты HA + keepalived

На **обеих** нодах:

```bash
sudo cp ~/ha-bundle-/ha-check.sh ~/ha-bundle-/become-master.sh ~/ha-bundle-/become-backup.sh /etc/ha/
sudo chmod +x /etc/ha/*.sh
bash -n /etc/ha/ha-check.sh && bash -n /etc/ha/become-master.sh && bash -n /etc/ha/become-backup.sh && echo SYNTAX_OK
```
**Ожидаемо:** `SYNTAX_OK`

keepalived по роли:

```bash
# на itconnect1 (master-роль, prio 150):
sudo cp ~/ha-bundle-/keepalived.conf.master /etc/keepalived/keepalived.conf
# на itconnect (backup-роль, prio 100):
sudo cp ~/ha-bundle-/keepalived.conf.backup /etc/keepalived/keepalived.conf

# на обеих:
sudo systemctl enable --now keepalived
```

### Проверка VIP

```bash
# на мастере:
ip a | grep 192.168.88.50
journalctl -u keepalived --no-pager | grep -i entering | tail -3
```
**Ожидаемо на мастере:**
```
    inet 192.168.88.50/24 scope global secondary eno1
(VI_1) Entering MASTER STATE
```
**Ожидаемо на backup:** `Entering BACKUP STATE`, VIP в `ip a` отсутствует.

---

## 6. Слот приложения

Положи `docker-compose.yml` своего backend в `/opt/app` **на обеих** нодах.
Требования к приложению: слушать `0.0.0.0`, подключаться к БД на `127.0.0.1`.
keepalived сам поднимет его на мастере (`become-master.sh`) и остановит на backup.

---

## 7. ТЕСТИРОВАНИЕ (обязательный блок)

Перед каждым тестом: `ping 192.168.88.50` с третьей машины (ноутбук) — терминал рядом.

### Тест 1. Софт-сбой: падение PostgreSQL на мастере

```bash
# на мастере:
sudo systemctl stop postgresql
```
**Ожидаемо:** через ~6 сек `journalctl -u keepalived` на мастере: `(VI_1) Entering FAULT STATE`,
VIP исчезает на мастере, через ~10–15 сек появляется на backup; `pg_is_in_recovery()` на backup → `f` (авто-промоут).
**Восстановление после теста:**
```bash
# на бывшем мастере — сначала реинтеграция (он теперь "отставший"):
sudo bash ~/ha-bundle-/reintegrate.sh   # ожидаем: t + streaming в pg_stat_replication
# VIP останется на новом мастере (nopreempt) — это нормально
```

### Тест 2. ЖЁСТКИЙ ОТКАЗ: выключение питания мастера через BliKVM

Цель: проверить весь боевой цикл — STONITH, промоут, переезд VIP за секунды.

**Подготовка:**
1. Записать тестовые данные на мастере, чтобы проверить их сохранность:
```bash
# на мастере:
sudo -u postgres psql -c "create table if not exists ha_test(v text);"
sudo -u postgres psql -c "insert into ha_test values ('FAILOVER_TEST_' || now());"
sudo -u postgres psql -c "select * from ha_test order by 1 desc limit 3;"
```
2. На ноутбуке: `ping 192.168.88.50 -t`
3. Открыть веб-морду **BliKVM мастера** (если мастер = itconnect, то BliKVM .44)

**Удар:**
4. В веб-морде BliKVM → жёстко выключить питание сервера (Power → OFF).
   Машина мгновенно мёртва — никакого штатного завершения.

**Наблюдение (на ноутбуке):** ping прервётся на ~10–20 секунд → вернётся.

**Проверка на выжившей ноде (сразу после возврата ping):**

```bash
ip a | grep 192.168.88.50
```
**Ожидаемо:** `inet 192.168.88.50/24 ...` ← **VIP переехал**

```bash
sudo -u postgres psql -c "select pg_is_in_recovery();"
```
**Ожидаемо:** `f` ← реплика промоутилась, данные уехали

```bash
sudo -u postgres psql -c "select * from ha_test order by 1 desc limit 3;"
```
**Ожидаемо:** строка `FAILOVER_TEST_...` с временем до убийства ← **данные не потеряны**

```bash
journalctl -t ha -n 20 --no-pager
```
**Ожидаемо (последовательность):**
```
STONITH: poweroff peer via BliKVM ... (peer=...)
promoting postgres
node is now MASTER, VIP should be here
```

```bash
journalctl -u keepalived --no-pager | grep -i entering | tail -4
```
**Ожидаемо:** `BACKUP STATE` → `MASTER STATE`

**Все пять пунктов = failover работает.** ✅

### Тест 3. Возврат убитой ноды (реинтеграция)

⚠ **НЕ включай убитую ноду просто так** — на ней старый PRIMARY, включение = split-brain.

1. Включи питание через BliKVM (Power → ON), дай загрузиться (~1–2 мин)
2. На восстановленной ноде:
```bash
sudo bash ~/ha-bundle-/reintegrate.sh
```
**Ожидаемый вывод:**
```
pg_rewind: connected to server
pg_rewind: servers diverged at WAL location ...
pg_rewind: Done!
 pg_is_in_recovery
-------------------
 t
Готово. Нода — реплика ...
```
3. На мастере:
```bash
sudo -u postgres psql -c "select client_addr, state from pg_stat_replication;"
```
**Ожидаемо:** `192.168.88.X | streaming` — нода вернулась как реплика

4. Восстановленная нода остаётся BACKUP (VIP не отбирает — nopreempt). VIP живёт там, где был поднят после отказа. Это штатно.

### Тест 4. Сеть (опционально): выдернуть кабель мастера

Эмулирует обрыв линка: поведение = как Тест 2, но STONITH пройдёт через ping-проверку
(пир не отвечает → промоут разрешён). Вернуть кабель → на «старом» мастере: `bash reintegrate.sh`.

---

## 8. Если что-то пошло не так

| Симптом | Причина | Лечение |
|---|---|---|
| `No VIP specified` в журнале | Кривой конфиг (скобки/CRLF) | `cat -A /etc/keepalived/keepalived.conf`, исправить, restart |
| Обе ноды BACKUP, VIP ни у кого | Остался «фантомный мастер» со сломанным конфигом, nopreempt молчит | Починить конфиг на обеих, `systemctl restart keepalived` на обеих |
| Реплика не стартует: `max_wal_senders ... lower setting` | Реплика требует ≥ значения мастера | `sudo sed -i 's/^max_wal_senders = .*/max_wal_senders = 10/' /etc/postgresql/16/main/postgresql.conf` + restart |
| `FATAL: no pg_hba.conf entry for replication` | Нет строки репликации для пира | добавить `host replication replicator <PEER_IP>/32 scram-sha-256` на мастере, reload |
| После failover обе ноды `f` (два PRIMARY) | **split-brain!** Бывший мастер включили до rewind | Немедленно `sudo systemctl stop postgresql` на той, что должна быть репликой → `reintegrate.sh` |
| `pg_rewind: command not found` | Нет в PATH | полный путь: `/usr/lib/postgresql/16/bin/pg_rewind` (в скрипте уже) |
| VIP не переезжает при убийстве питания | backup в FAULT | проверить `sudo /etc/ha/ha-check.sh; echo $?` → должно быть 0 (pg_isready) |

---

## 9. Памятка по граблям (все выловлены на практике)

1. **VRID уникален** в сегменте (51 — дефолт Mikrotik; у нас 77). Проверка: `sudo tcpdump -ni eno1 vrrp -c 5`
2. **`nopreempt` работает только при `state BACKUP` на обеих**
3. **`auth_pass` ≤ 8 символов**
4. **`listen_addresses = '*'`** — переживает смену ролей; доступ всё равно режет pg_hba
5. **Health-check только `pg_isready`** — проверка роли убивает failover (backup всегда в recovery → вечный FAULT)
6. **`max_wal_senders = 10`** ≥ дефолта апстрима, иначе реплика не стартует
7. **`notify_backup` вызывается и при старте keepalived** — guard через `/run/ha-was-master` (в скрипте)
8. **Никогда не `systemctl start postgresql` на бывшем мастере до `pg_rewind`** — split-brain
9. `pg_rewind -R` пишет `primary_conninfo` с user из `--source-server` — reintegrate.sh переписывает его правильно (replicator + пароль)

---

## 10. Быстрая сверка здоровья (ежедневно)

```bash
# на любой ноде:
ip a | grep 192.168.88.50          # где VIP — тот и мастер
sudo -u postgres psql -c "select pg_is_in_recovery();"   # мастер: f, реплика: t
sudo -u postgres psql -c "select client_addr, state from pg_stat_replication;"  # streaming
systemctl is-active keepalived postgresql                # active active
```
