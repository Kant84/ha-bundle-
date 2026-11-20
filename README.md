# HA Bundle v4 — Active/Passive кластер на keepalived + PostgreSQL 16

Пара Ubuntu-серверов с единым виртуальным IP (VIP), PostgreSQL-репликацией и
аппаратным STONITH через BliKVM. Боевой failover ≈ 20 секунд, без split-brain.

![Архитектура](ha-cluster-architecture.png)

## 1. Состав и адреса

| Устройство            | IP              | Роль |
|-----------------------|-----------------|------|
| itconnect (mobile)    | 192.168.88.43   | нода A: keepalived prio 150, PostgreSQL PRIMARY/REPLICA, слот приложения `/opt/app` |
| itconnect1 (mobile1)  | 192.168.88.45   | нода B: keepalived prio 100 (nopreempt), PostgreSQL REPLICA/PRIMARY, слот приложения |
| **VIP**               | **192.168.88.50** | единый адрес сервиса (живёт на текущем мастере; роли плавают после failover) |
| BliKVM №1             | 192.168.88.44   | KVM-консоль + питание **ноды B** (itconnect1) |
| BliKVM №2             | 192.168.88.42   | KVM-консоль + питание **ноды A** (itconnect) |
| QNAP NAS (опционально)| по сети         | слой бэкапов: NFS `/mnt/backup-db`, см. раздел 8 |

STONITH перекрёстный: каждая нода через свой BliKVM физически выключает соседа
при получении роли мастера. Питание и консоль управляются по сети независимо от
состояния самой ноды — это последняя линия защиты от split-brain.

## 2. Репозиторий → серверы (какой файл куда)

| Файл репозитория         | Путь на сервере | Куда ставить |
|--------------------------|-----------------|--------------|
| `keepalived.conf.master` | `/etc/keepalived/keepalived.conf` | только .43 |
| `keepalived.conf.backup` | `/etc/keepalived/keepalived.conf` | только .45 |
| `ha.env.itconnect`       | `/etc/ha/ha.env` | только .43 |
| `ha.env.itconnect1`      | `/etc/ha/ha.env` | только .45 |
| `ha-check.sh`            | `/etc/ha/ha-check.sh` | обе, `chmod +x` |
| `ha-link.sh`             | `/etc/ha/ha-link.sh`  | обе, `chmod +x` |
| `become-master.sh`       | `/etc/ha/become-master.sh` | обе, `chmod +x` |
| `become-backup.sh`       | `/etc/ha/become-backup.sh` | обе, `chmod +x` |
| `reintegrate.sh`         | `/etc/ha/reintegrate.sh`   | обе, `chmod +x` |
| `backup-nas.sh`          | `/etc/ha/backup-nas.sh` + cron | обе (раздел 8) |

⚠️ **Файлы на серверы — только через `scp`/ssh-перенаправление. Вставка
многострочного текста через веб-консоль BliKVM ("Paste text") теряет символы
и строки** — так уже получены битые конфиги. Для локальной консоли включите
поддержку мыши, длинные вставки разбивайте на короткие куски.

## 3. Архитектура (как это работает)

1. Клиенты ходят только на VIP `192.168.88.50`.
2. keepalived (VRRP, **unicast**) держит VIP на мастере. Обе ноды в состоянии
   BACKUP + `nopreempt`: VIP не отбирается у живого мастера более приоритетной
   нодой. Трекинг двойной:
   - `chk_pg` — локальный PostgreSQL отвечает (`pg_isready`);
   - `chk_link` — карта `eno1` поднята И шлюз пингуется (изолированная нода
     VIP не берёт).
3. PostgreSQL 16: streaming-репликация always-on через слот `ha_slot`.
   primary ровно один (проверка ниже).
4. `notify_master` → `become-master.sh`: STONITH соседа через BliKVM +
   подъём приложения из `/opt/app` (docker compose).
5. `notify_backup` → `become-backup.sh`: остановка приложения.

## 4. Ежедневная проверка (2 минуты, с любой ноды)

```bash
ip a | grep 192.168.88.50                                # VIP есть ровно на одной ноде
sudo -u postgres psql -tAc "select pg_is_in_recovery()"  # мастер: f | реплика: t
sudo -u postgres psql -tAc "select count(*) from pg_stat_replication"  # мастер: 1
ssh -i /root/.ssh/blikvm_stonith root@192.168.88.44 "echo STONITH_OK"    # STONITH .44
ssh -i /root/.ssh/blikvm_stonith root@192.168.88.42 "echo STONITH_OK"    # STONITH .42
ls -la /root/.ssh/ | grep -cE 'id_ed25519|id_rsa'        # ожидается >= 2 (ключи BliKVM)
docker ps --format '{{.Names}}\t{{.Status}}'            # контейнеры — на ноде с VIP
```

## 5. Failover

Происходит автоматически, когда текущий мастер перестаёт слать VRRP-анонсы
(падение ноды, postgres, линка). Резерв берёт VIP за ~3–6 секунд, шлёт STONITH,
поднимает приложение. **Боевой тест (только в окне обслуживания):**

```bash
# с любой ноды: через BliKVM отключить питание ТЕКУЩЕГО мастера
ssh -i /root/.ssh/blikvm_stonith root@$( [ "$(hostname)" = "mobile" ] && echo 192.168.88.42 || echo 192.168.88.44 ) "poweroff"
ping 192.168.88.50     # пауза ~10–20 сек, затем ответы
# данные на новом мастере целы; старый мастер потом вернуть через reintegrate.sh
```

## 6. Реинтеграция (вернуть ноду в строй)

На отремонтированной ноде (она станет репликой текущего мастера):

```bash
sudo bash /etc/ha/reintegrate.sh
```

Скрипт останавливает postgres, при необходимости создаёт слот `ha_slot` на
мастере, **пересоздаёт данные с нуля через `pg_basebackup`** (локальные данные
ноды уничтожаются!), прописывает `primary_conninfo` со слотом и стартует
реплику. Маркеры успеха: `t` и строка `Готово`.

Почему не `pg_rewind`: кластер собран без data-checksums и раньше — без
`wal_log_hints`, а rewind требует их **до** расхождения. Копия при объёме БД
в десятки МБ занимает секунды, поэтому basebackup — надёжнее.

## 7. Первичное развёртывание (если ноды чистые)

1. Установить Ubuntu Server, сеть eno1, hostname mobile / mobile1, пароль nfc.
2. На ОБЕИХ нодах, строго по очереди:

```bash
mkdir -p /etc/ha
# файлы из раздела 2 (каждый: chmod +x для *.sh)
# PostgreSQL 16: установить, настроить по вспомогательным файлам
#   pg_hba.conf: host replication replicator <peer>/32 scram-sha-256
#                host postgres     replicator <peer>/32 scram-sha-256  (для reintegrate/rewind)
#                host all          nfc        192.168.88.0/24 scram-sha-256
# postgresql.conf/auto.conf: listen_addresses='localhost,<свой IP>'  (только с РЕСТАРТОМ)
#                            wal_log_hints=on                        (только с РЕСТАРТОМ)
#   роль: CREATE ROLE replicator LOGIN REPLICATION PASSWORD '***';
#   пароль одинаковый на обеих нодах (= PG_REPL_PASS в ha.env)
# слот на будущем мастере: SELECT pg_create_physical_replication_slot('ha_slot');
# реплику на второй ноде поднять через reintegrate.sh
# ssh-ключи: ssh-keygen; ssh-copy-id root@<BliKVM своего соседа> (см. deploy.md)
sudo systemctl restart keepalived   # на каждой ноде после раскладки её конфига
```

3. Применить unicast-переход на работающей паре — **только синхронно** (одной
   командой, peer первым), иначе ноды перестанут слышать друг друга:

```bash
ssh nfc@<peer> "echo nfc | sudo -S systemctl reload keepalived" && echo nfc | sudo -S systemctl reload keepalived
```

## 8. Бэкапы на NAS (QNAP)

Поверх HA-кластера — файл-сервер с RAID 1 (2×8 ТБ), NFS (SMB выключен),
фиксированный IP, монтирование `_netdev`:

```bash
# /etc/fstab на обеих нодах:
# <nas-ip>:/backup-db  /mnt/backup-db  nfs  defaults,_netdev  0 0
sudo mkdir -p /mnt/backup-db && sudo mount -a
```

Cron (на обеих; скрипт сам делает дамп только на primary):

```bash
echo '30 3 * * * root /etc/ha/backup-nas.sh >> /var/log/backup-nas.log 2>&1' | sudo tee /etc/cron.d/backup-nas
```

Правило: NAS — второй экземпляр данных, но в одном офисе; для катастрофической
защиты периодически копировать дамп наружу (облако).

## 9. Известные грабли (проверено ночью инцидента)

1. `ha-check.sh` не должен проверять `pg_is_in_recovery()` — реплика в вечном
   FAULT и failover не случается никогда (баг v3, исправлено в v4).
2. `listen_addresses`/`wal_log_hints` применяются **только рестартом**
   postgres. Параметр прописан, но не применён = обратная репликация молча
   не работает.
3. `pg_basebackup -R` не сохраняет пароль в `primary_conninfo` — реплика не
   коннектится; reintegrate.sh дописывает.
4. Слот `ha_slot` живёт на текущем primary; после смены мастера его надо
   пересоздавать (reintegrate.sh делает сам).
5. BliKVM "Paste text" портит многострочные вставки — конфиги только scp/ssh.
6. Unicast-VRRP: обе ноды должны перейти синхронно, иначе элекция сорвётся.
7. `keepalived.conf`: обе ноды `state BACKUP`, иначе `nopreempt` не работает.
8. Приоритеты в файлах не перепутать: `.43`=150 (master-файл), `.45`=100.

## 11. Хроника инцидентов (18–20 ноября 2026) и их лечение

Каждый пункт: симптом → как нашли → корневая причина → лечение → контроль.
Раздел писан по реальным ночным инцидентам, все пункты проверены боевыми тестами.

### 11.1 Вечный FAULT реплики (баг v3)

- **Симптом:** мастер убит, backup не берёт VIP никогда; в журнале
  `VRRP_Script(chk_pg) failed`.
- **Диагностика:** `cat /etc/ha/ha-check.sh` на сервере — файл отличался от
  репозитория.
- **Причина:** старая версия `ha-check.sh` проверяла `pg_is_in_recovery()`.
  Реплика ВСЕГДА в recovery → скрипт всегда возвращает 1 → keepalived держит
  ноду в FAULT. Исправление существовало в репозитории, но на серверы не было
  задеплоено.
- **Лечение:** `ha-check.sh` v4 — только `pg_isready` (жив = здоров).
- **Контроль:** на backup-ноде `/etc/ha/ha-check.sh; echo $?` → `0`.

### 11.2 Рассинхрон VRRP: VIP исчез везде

- **Симптом:** после правки конфигов `ip a | grep 88.50` пусто на ОБЕИХ нодах,
  сервис недоступен.
- **Диагностика:** журналы keepalived: ноды не видят чужих анонсов.
- **Причина:** одна нода переведена на `unicast_peer`, вторая осталась на
  multicast → ноды физически не слышат друг друга. Усугублялось: веб-вставка
  конфига через консоль BliKVM теряла строки (блок `chk_link` пропал,
  `keepalived -t` ругался «unknown keyword», но файл всё равно был установлен
  цепочкой `&&`).
- **Лечение:** обе ноды на unicast; переход — СИНХРОННЫМ reload одной командой
  (peer первым), иначе окно рассинхрона; перед установкой файла — обязательная
  проверка (`grep -c`, `keepalived -t`).
- **Контроль:** `sudo tcpdump -i eno1 -nn vrrp -c 4` — только пары
  `.43 ↔ .45`, никакого `224.0.0.18`.

### 11.3 «STONITH» через WOL — не работал по построению

- **Симптом:** при промоуте в логе `STONITH: poweroff peer...`, а нода пир
  продолжает работать.
- **Диагностика:** чтение `become-master.sh`: «STONITH» слал magic packet (WOL).
- **Причина:** WOL умеет только ВКЛЮЧАТЬ машину, выключить работающую не может.
  Аппаратной альтернативы нет: у HP-нод нет подключённого ATX-провода к BliKVM,
  кнопку питания через BliKVM нажать нельзя (`POST /api/v1/atx/power
  {"action":"off"}` отвечает `ok`, но ничего не выключает).
- **Лечение (v5):** STONITH = SSH к пиру ключом `/root/.ssh/stonith_off_key`
  (root→nfc) с командой `sudo poweroff`. Плюс существующий ping-guard: пир
  пингуется → промоут запрещён (защита от split-brain на случай, если выключение
  не сработало). WOL сохранён только для включения нод после обслуживания.
- **Контроль:** боевой тест: `sudo ssh -i /root/.ssh/stonith_off_key
  nfc@<peer> "echo nfc | sudo -S poweroff"` → пир гаснет; ping-guard:
  `ping -c2 <peer>` после «неудачного» STONITH блокирует промоут.

### 11.4 pg_rewind неприменим на этом кластере

- **Симптом:** `reintegrate.sh` (старая, на pg_rewind) падает с
  `target server needs to use either data checksums or "wal_log_hints = on"`.
- **Причина:** кластер инициализирован без data-checksums, `wal_log_hints`
  был выключен (и должен быть включён ДО расхождения, задним числом не лечится).
- **Лечение:** reintegrate.sh v4+ переписан на `pg_basebackup` (полная копия за
  секунды — БД десятки МБ). Заодно включён `wal_log_hints=on` (см. 11.5).
- **Контроль:** `sudo bash /etc/ha/reintegrate.sh` → 100% → `t` → `Готово`.

### 11.5 «Прописано ≠ работает»: listen_addresses и wal_log_hints

- **Симптом:** реплика стримит в одну сторону; в обратную — `Connection
  refused` по LAN-IP мастера, хотя «всё настроено».
- **Причина:** параметры применяются ТОЛЬКО рестартом postgres. Значение было
  прописано в `postgresql.auto.conf` неделями ранее, но postgres с тех пор не
  перезапускался → слушал только `localhost`. Та же история с `wal_log_hints`.
- **Лечение:** после изменения таких параметров — обязательно
  `systemctl restart postgresql` и сверка `ss -ltn | grep 5432` (должен быть
  виден `192.168.88.<свой IP>:5432`).
- **Контроль:** с пира: `pg_isready -h 192.168.88.<peer>` → accepting connections.

### 11.6 pg_basebackup -R не сохраняет пароль; ALTER SYSTEM на мёртвом кластере

- **Симптом:** после reintegrate реплика не коннектится: в логе postgres
  `FATAL: password authentication failed for user "replicator"`. Второй
  вариант: скрипт падает после basebackup на `ALTER SYSTEM` (postgres остановлен)
  и БД не стартует вообще.
- **Причина:** (а) `-R` пишет `primary_conninfo` без пароля; (б) `ALTER SYSTEM`
  требует работающего сервера, а в сценарии reintegrate он остановлен; под
  `set -e` скрипт умирал до `systemctl start`.
- **Лечение (v5.1):** `primary_conninfo` дописывается напрямую в
  `postgresql.auto.conf` (`sed` удаляет старую строку, `tee -a` добавляет
  полную — последняя строка побеждает).
- **Контроль:** после reintegrate: `select status from pg_stat_wal_receiver` →
  `streaming`; на мастере `select count(*) from pg_stat_replication` → `1`.

### 11.7 Слот репликации живёт на текущем primary

- **Симптом:** walreceiver: `replication slot "ha_slot" does not exist` после
  смены мастера.
- **Причина:** физический слот существует на primary, куда писалась реплика;
  после failover он остаётся на старом месте, а не «переезжает».
- **Лечение:** reintegrate.sh сам создаёт слот на текущем мастере, если его нет
  (`pg_create_physical_replication_slot('ha_slot')`).
- **Контроль:** на мастере `select slot_name from pg_replication_slots` →
  `ha_slot` есть; `pg_stat_replication.state` → `streaming`.

### 11.8 listen_addresses «кочует» вместе с репликой

- **Симптом:** reintegrate проходит на ноде X, а потом обратный reintegrate
  падает с Connection refused на уже леченную настройку.
- **Причина:** `pg_basebackup` копирует `postgresql.auto.conf` ДОНОРА целиком —
  включая `listen_addresses` с IP донора. Каждая пересборка реплики приносит
  «чужой» IP слушания.
- **Лечение:** процедура возврата ноды дополнена шагом: после reintegrate на
  ВОЗВРАЩАЕМОЙ ноде проверить и выставить свой IP:
  `ALTER SYSTEM SET listen_addresses = 'localhost,<свой IP>';` +
  `systemctl restart postgresql` + `ss -ltn | grep 5432`.
- **Контроль:** `pg_isready -h <свой IP>` → accepting connections.

### 11.9 Удалённое включение ноды: WOL

- **Симптом:** нода выключена, magic packet с другого сервера не будит.
- **Что выяснили:** рабочий рецепт — `wol.sh` (BliKVM управляющего устройства):
  кнопка ▶ в веб-интерфейсе. Пакеты, посланные с сервера `.45`, в одном из
  тестов не дошли (зафиксировано; причина не установлена — используем BliKVM
  как источник WOL). BIOS HP обязан иметь: **S5 Maximum Power Savings =
  Disabled** (он обесточивает NIC в выключенном состоянии), **Wake On LAN =
  Boot to Hard Drive** (Advanced → Built-In Device Options), **After Power Loss
  = Power On** (Advanced → Boot Options — авто-включение после сбоя электричества),
  **Startup Delay = 10 сек** (окно для входа в BIOS по сети).
- **Вход в BIOS удалённо без ловли тайминга:** машина загружается в UEFI →
  `sudo systemctl reboot --firmware-setup` — следующая загрузка сразу в BIOS
  Setup. (Макросы BliKVM с серией F9/Esc через «Макросы» — запасной вариант.)

### 11.10 Права и доступы, без которых реинтеграция не работает

- pg_hba на КАЖДОЙ ноде (пригодится при любой смене мастера):
  `host replication replicator <peer>/32 scram-sha-256` (стриминг) И
  `host postgres replicator <peer>/32 scram-sha-256` (pg_basebackup/pg_rewind
  ходят в базу postgres).
- Роль: `CREATE ROLE replicator LOGIN REPLICATION PASSWORD '...';` — пароль
  одинаковый на обеих нодах (= `PG_REPL_PASS` в ha.env).
- Для pg_rewind-подобных операций: `GRANT pg_read_server_files` (на кластере без
  checksums всё равно не спасает — см. 11.4).
- Ключи: `stonith_off_key` (root→nfc, оба направления) — STONITH v5;
  `blikvm_stonith` (root→root на BliKVM) — проверка/сервис.
- Скрипт `reboot.sh` на BliKVM — SSH-based (dropbear-ключ к nfc@хост): работает
  только на ВКЛЮЧЕННОЙ машине; `exit 1` на выключенной — норма, не ошибка.

## 10. Changelog
- **v5.1 (2026-11-20)**: добавлен раздел 11 «Хроника инцидентов и лечение» 
  (9 разборов: FAULT v3, рассинхрон VRRP, WOL-STONITH, pg_rewind, 
  listen_addresses/wal_log_hints без рестарта, пароль в primary_conninfo, слот 
  ha_slot, «чужой» listen_addresses после basebackup, WOL/BIOS-процедуры).
- **v4 (2026-11-19)**: unicast VRRP вместо multicast; новый `chk_link`
  (`ha-link.sh`); `ha-check.sh` без проверки роли (фикс вечного FAULT);
  `reintegrate.sh` переведён на `pg_basebackup`; добавлен `backup-nas.sh`;
  требование `wal_log_hints=on` и LAN в `listen_addresses`; pg_hba дополнен
  строками `host postgres replicator <peer>/32`; README переписан.
- **v3**: текущая боевое ядро (keepalived+STONITH+PG-репликация), баг с
  `pg_is_in_recovery` в `ha-check.sh` исправлен только в репозитории, не на
  серверах.
- **v2**: добавлен STONITH через BliKVM.
- **v1**: keepalived + ручной failover.
