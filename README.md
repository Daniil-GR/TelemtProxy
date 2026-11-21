# TelemtProxy

Установка Telemt на чистый Ubuntu 24.04 VPS: WEB + MTProto, только MTProto и MTProto для Gcore Edge Proxy.

Основной `deploy.sh` устанавливает WEB + MTProto, MEKOPR, Nginx и сертификат Let's Encrypt, а также создаёт игровую заглушку. Отдельный `deploy-mtproto.sh` устанавливает только MTProto/FakeTLS, без WEB-режима и веб-сервера.

## Установка WEB + MTProto

Предварительно создайте DNS A-запись выбранного домена на IPv4 вашего нового VPS. Разрешите входящие TCP-порты 80 (сертификат), 443 (WEB-прокси) и 9443 (MTProto).

```bash
curl -fsSLo /tmp/telemtproxy-install.sh https://raw.githubusercontent.com/Daniil-GR/TelemtProxy/main/deploy.sh
sudo bash /tmp/telemtproxy-install.sh
```

При запуске появится приглашение:

```text
Введите домен WEB-прокси (например, web.example.org):
```

Также можно передать домен и параметры `hello`/`ad_tag` сразу:

```bash
sudo bash /tmp/telemtproxy-install.sh \
  --domain web.example.org \
  --hello-secret '0123456789abcdef0123456789abcdef' \
  --ad-tag 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
```

HEX-строки здесь **примеры, а не действительные секреты**. Поддерживается `--hello` как синоним `--hello-secret`. Оба значения должны состоять ровно из 32 HEX-символов (без `dd`/`ee`). Если `--hello-secret` не задан, будет автоматически создан новый секрет; без `--ad-tag` спонсорский тег останется пустым. Для WEB и MTProto используется общий пользователь `hello` и общий `ad_tag` в конфигурации Telemt.

В режиме прямого подключения MTProto-ссылка будет использовать домен и порт `9443`, WEB — домен и порт `443`. В режиме `--cdn` обычный MTProto по-прежнему использует IP исходного VPS на `9443`, поскольку HTTPS CDN не обязан проксировать обычный TCP MTProto.

**Безопасность:** секреты из аргументов команды могут попасть в историю shell и отображаться в списке процессов. Не публикуйте команды с настоящими секретами; при необходимости удаляйте их из истории.

**Важно:** скачивайте установщик в файл, а не запускайте `curl | bash`: внутри `deploy.sh` находятся архивированные ресурсы заглушки, которые скрипт читает из собственного файла.


## Быстрая установка только MTProto

Для VPS, где WEB-прокси не нужен, используйте отдельный установщик `deploy-mtproto.sh`. Он не меняет и не вызывает `deploy.sh`.

Создайте DNS A-запись выбранного поддомена на IP нового VPS, затем выполните:

~~~bash
curl -fsSLo /tmp/telemt-mtproto.sh https://raw.githubusercontent.com/Daniil-GR/TelemtProxy/main/deploy-mtproto.sh
sudo bash /tmp/telemt-mtproto.sh
~~~

При запуске скрипт спросит домен **для Telegram-ссылки**, например `lt.vetka.rest`. Можно сразу передать его параметром: `sudo bash /tmp/telemt-mtproto.sh lt.vetka.rest`.

Можно также передать все параметры сразу:

```bash
sudo bash /tmp/telemt-mtproto.sh lt.vetka.rest \
  --hello-secret '0123456789abcdef0123456789abcdef' \
  --ad-tag 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
```

Допустимы `--hello` вместо `--hello-secret` и `--domain lt.vetka.rest` вместо позиционного домена. Значения HEX выше — **только примеры**, не готовые секреты. Если один из двух флагов не задан, установщик запросит только отсутствующее значение; по Enter будет использовано значение по умолчанию.

**Безопасность:** секрет, переданный непосредственно через флаг, сохраняется в истории shell и может быть виден другим локальным пользователям через список процессов. Для приватной настройки лучше использовать интерактивный скрытый ввод. Не размещайте команды с действующими секретами в общедоступных логах и чатах.

Затем появятся два **скрытых поля ввода**:

```text
Секрет hello (32 HEX, Enter = создать новый):
ad_tag (32 HEX, Enter = без тега):
```

**При переносе на новый VPS:** используй тот же поддомен, прежние `hello` и `ad_tag`, обнови A-запись на новый IP. Пока сохраняются порт 443 и SNI `www.booking.com`, ранее выданная ссылка `tg://proxy` останется такой же. Новый VPS должен принимать входящие соединения на 443. Одинаковый секрет на нескольких серверах повышает последствия его утечки; держи его в защищённом хранилище. Статистику и отображение канала в @MTProxybot после смены адреса рекомендуется проверить отдельно.

Настройки этого режима:

- **Только обычный MTProto:** публичный TCP-порт 443. Nginx, Certbot и WEB-listener не настраиваются.
- **Пользователь:** всегда `hello`. При установке можно **ввести прежний секрет** (32 HEX-символа) либо оставить поле пустым, чтобы создать новый. Префиксы `dd` и `ee` не вводить.
- **FakeTLS/SNI:** всегда `www.booking.com`, включён режим `ee`.
- **Адрес для Telegram-ссылок:** введённый поддомен, через `[general.links].public_host`.
- **Версия Telemt:** последний стабильный релиз через MEKOPR; дополнительно ставится SYN FIX v3 на 443.
- **Спонсорский канал:** во время установки можно ввести существующий `ad_tag` (32 HEX-символа от @MTProxybot) или оставить поле пустым. Он сразу сохранится в `[general]`, поэтому вручную редактировать конфиг не нужно.
- **Ссылка:** сохранена в `/root/telemt-mtproto-link.txt` с доступом для root.

Финальная ссылка будет иметь вид `tg://proxy?server=ПОДДОМЕН&port=443&secret=ee...`. Не используйте промежуточные ссылки, которые выводит MEKOPR до замены его первоначальной конфигурации; используйте блок `READY` в конце работы.

Проверка после установки:

~~~bash
systemctl is-active telemt
ss -lntp | grep ':443'
sudo cat /root/telemt-mtproto-link.txt
~~~

Установщик предназначен для **чистого VPS**: он не перезаписывает действующие конфигурации Telemt/MEKOPR и не занимает чужой порт 443. Для Floating IP DNS A-запись должна указывать на адрес интерфейса VPS либо на определяемый внешний IPv4.

## MTProto для Edge Proxy (Gcore)

Используется тот же `deploy-mtproto.sh`, с отдельным режимом `--edge-proxy`.
Запускайте **только на новом Ubuntu 24.04 VPS**. Существующий Telemt установщик
не перезаписывает. WEB/CDN и обычный MTProto продолжают использовать прежние команды.

```bash
curl -fsSLo /tmp/telemt-mtproto.sh https://raw.githubusercontent.com/Daniil-GR/TelemtProxy/main/deploy-mtproto.sh
sudo bash /tmp/telemt-mtproto.sh --edge-proxy edge.example.org
```

Вместо `edge.example.org` укажите будущий клиентский поддомен. Домен можно не
передавать — установщик спросит его. Предварительная A-запись на IP VPS не нужна:
домен позже будет указывать на **Edge IP Gcore**. Для секрета `hello` нажмите Enter,
чтобы создать новый; новый `ad_tag` вводится скрыто или оставляется пустым. Старые
секреты/теги не копируются. Ссылка сохраняется в `/root/telemt-mtproto-link.txt`.

Что настраивает режим:

- Telemt MTProto FakeTLS на **443/TCP**, SNI **www.booking.com**, без Nginx,
  Certbot, WEB-listener и собственного сертификата.
- Приём **PROXY protocol V1/V2**, с доверием только официальным IPv4-сетям Gcore,
  чтобы Telemt видел адреса клиентов. Начальный `max_connections` — 16384.
- Собственную цепочку iptables и ipset: TCP 443 допускается только от Gcore.
  SSH, основной IP, маршруты и остальные порты не меняются; общий firewall не очищается.
- Список сетей из `https://api.gcore.com/cdn/public-net-list`. API-ключ не нужен.
  По документации Gcore Edge использует те же исходящие серверы, что и CDN.
- Кеш сетей для загрузки VPS, отдельный firewall-сервис и обновление каждые
  10 минут. Без изменения списка Telemt не перезапускается. При изменении списка
  выполняется короткий перезапуск; при ошибке применения восстанавливаются
  предыдущие конфигурация и firewall. При недоступности API сохраняется старый список.
- SYN FIX для прямых клиентов **не устанавливается** (`-no-fix`): тысячи клиентов
  приходят с нескольких адресов Gcore, и лимиты по исходному IP мешают соединениям.
  Не включайте такие ограничения для Gcore позднее без исключений.

После установки в кабинете Gcore создайте Edge Proxy:

1. Origin — IPv4 **нового VPS**, который напечатает установщик.
2. Профиль **Generic TCP Server**, порт **443**, протокол **TCP**.
3. В Advanced включите **PROXY protocol V1** (V2 тоже поддерживается).
4. Дождитесь активации и направьте A-запись клиентского поддомена на выданный
   **Edge IP**. Это обычная A-запись, не CNAME HTTP CDN.
5. Откройте полученную `tg://proxy` ссылку и проверьте отправку сообщений и фото
   из РФ и другой сети. Открытый TCP-порт сам по себе не подтверждает передачу данных.

Прямое подключение к IP VPS:443 в этом режиме ожидаемо запрещено. Если на стороне
Gcore оставить PROXY protocol Off, Telegram работать не будет. Создание и оплата
ресурса Gcore, изменение DNS и регистрация спонсорства выполняются отдельно —
установщик этих действий не делает и не запрашивает API-ключи.

```bash
systemctl status telemt telemt-gcore-firewall.service telemt-gcore-refresh.timer
journalctl -u telemt-gcore-refresh.service -u telemt-gcore-firewall.service --since today
# Принудительно обновить официальный список:
sudo systemctl start telemt-gcore-refresh.service
```

Помощник закреплён контрольной суммой в установщике. Его файлы:
`/usr/local/lib/telemtproxy/gcore-edge.py`, `/etc/telemt/gcore-edge-cidrs.json`,
резервная копия новой конфигурации до включения Edge —
`/etc/telemt/telemt.toml.before-gcore` (только root).

Настройки и откат проверяются автоматическими тестами с подменой системных команд.
Реальный новый VPS и платный ресурс этим изменением не создавались; полный запуск
проверяется после установки и активации конкретного Edge Proxy.

Документация: [Gcore: настройка и список origin-адресов](https://github.com/G-Core/product-documentation/blob/main/edge-proxy/setup-and-configuration.mdx),
[Telemt: PROXY protocol](https://github.com/telemt/telemt/blob/main/src/config/types/server.rs).

## WEB через CDN

Обычный `deploy.sh` предназначен для прямого подключения: он сверяет IPv4 VPS
с DNS домена (локально и через два публичных резолвера), затем получает сертификат
через Certbot HTTP-01 на порту 80. При уже настроенном CNAME на CDN эта проверка
корректно остановит прямую установку. Nginx не выполняет такую сверку во время
работы: он принимает HTTPS и передаёт HTTP с исходным Host на `127.0.0.1:18080`.

CDN даёт две отдельные TLS-сессии: клиент → CDN и CDN → origin VPS. Сертификат,
выпущенный в панели CDN, защищает первую; он не устанавливается автоматически
на VPS. Для свежего VPS с уже настроенным CDN доступен явный режим:

```bash
sudo bash /tmp/telemtproxy-install.sh proxy.example.org --cdn \
  --origin-cert /secure/fullchain.pem --origin-key /secure/privkey.pem
```

Это файлы действующего сертификата origin из защищённой резервной копии или
выпущенного отдельно сертификата, а не API-ключи. Закрытый ключ должен принадлежать
root и иметь права 600. Установщик проверяет имя, доверенную цепочку, срок больше
суток и соответствие ключа сертификату **до установки пакетов**. В этом режиме
DNS обязан возвращать публичные IPv4, но не обязан совпадать с IP VPS. Сертификат
origin копируется в `/etc/telemtproxy/origin/`; Certbot HTTP-01 не вызывается.
Обновление этих импортированных файлов необходимо организовать отдельно:
продление сертификата CDN не продлевает сертификат VPS. При отсутствии файлов
скрипт остановится, не отключая проверку TLS и не создавая самоподписанный сертификат.
Обычный прямой режим сохраняется без изменений. Установку CDN-режима на реальном
чистом VPS ещё нужно проверить; автоматические тесты проверяют DNS-развилки.

В CDN требуется HTTPS origin на IP VPS:443, отключённое кеширование, сохранение
методов/путей/query/заголовков и достаточный таймаут для long polling. Клиентский
HTTP/2 нужен для `https-lanes`. CDN-ресурс создаётся и получает клиентский
сертификат в панели провайдера; данный установщик не управляет его API и DNS.

### Добавить второе CDN-имя одной командой на ноде

Сначала добавьте второе имя к ресурсу CDN, его CNAME и дождитесь сертификата CDN
для обоих имён. В Gcore включите **Forward Host header**, а для соединения с VPS
выберите **Custom SNI hostname** с прежним именем origin. Не оставляйте Dynamic SNI,
если сертификат VPS покрывает только прежнее имя.

Скачайте помощник на сервер с существующей стандартной установкой `deploy.sh`:

```bash
curl -fsSLo /tmp/telemtproxy-cdn-domain.py https://raw.githubusercontent.com/Daniil-GR/TelemtProxy/main/cdn-domain.py
sudo python3 /tmp/telemtproxy-cdn-domain.py proxy.example.org test.example.org
```

Без флага изменения не применяются: помощник проверяет конфигурацию и показывает
план. Для применения добавьте `--apply`:

```bash
sudo python3 /tmp/telemtproxy-cdn-domain.py proxy.example.org test.example.org --apply
```

Помощник добавляет отдельный WEB-vhost с прежними профилями/секретом и добавляет
имя в `server_name` Nginx. Старое имя, IP, ad_tag, сертификаты и DNS сохраняются.
Скрипт не устанавливает пакеты и не обновляет Telemt; Python 3.11+ без библиотек.
Он откажется от неизвестного формата или конфликтующей настройки имени.

**`--apply` перезапускает Telemt: существующие соединения могут кратко прерваться.**
До изменения сохраняются закрытые копии в `/var/backups/telemtproxy/` (каталог
700, файлы 600). После проверки `nginx -t` и локальной готовности выполняется
graceful reload Nginx. При ошибке применения восстанавливаются оба файла и сервисы;
при неудаче отката скрипт сообщает путь к копии. Внезапное выключение питания
потребует сверки файлов с закрытой копией и `operation.json`; отдельного watchdog нет.
Повторный запуск с уже настроенными именами ничего не меняет и не перезапускает.
Секреты и ссылки с секретом не печатаются. Итоговая локальная проверка сайта
не заменяет проверку передачи данных через новый адрес в совместимом Telegram.

Тесты помощника, отката и DNS-проверок (без реальных провайдеров и сервисов):

```bash
python3 -m unittest discover -s tests -v
```

## Проверка WEB-режима

```bash
systemctl is-active nginx telemt
nginx -t
ss -lntp | grep -E ':(443|9443|18080)\b'
curl -I https://YOUR_DOMAIN/
```

## Особенности WEB-режима

- Версия Telemt выбирается автоматически при новой установке (`-version latest`). Уже развёрнутые инстансы автоматически не обновляются.
- Новый секрет (32 HEX-символа) создаётся на VPS; не публикуйте его в GitHub.
- Разные VPS получают уникальные статические ресурсы (HTML/CSS/JS/SVG).
- Установщик предназначен **только для нового сервера** и не перезаписывает существующие установки Telemt/MEKOPR.
- Если сертификат не выпущен из-за DNS `NXDOMAIN`, исправьте DNS и завершайте частичную установку без повторного запуска полного развертывания.


## Wildcard DNS-01 для vetka.rest (Dynadot)

Цель — **уменьшить раскрытие имён отдельных WEB-поддоменов через Certificate Transparency (CT)**. Wildcard-сертификат НЕ скрывает IP, доступный через DNS. Ранее опубликованные CT-записи не исчезают. Сертификат `*.vetka.rest` подходит для `lt.vetka.rest` и `chicago.vetka.rest`, но не для `vetka.rest` или `a.b.vetka.rest`.

### Подготовка DNS-01

1. В Dynadot откройте **«Настройки DNS»** домена и убедитесь, что авторитативные NS используют **Dynadot DNS**. Если NS сторонние, API Dynadot не сможет менять рабочие DNS-записи. Не меняйте NS без необходимости.
2. В аккаунте Dynadot откройте **Tools → API**, создайте API Key и API Secret, ограничьте разрешённые IP адресом **одного доверенного сервера выпуска**.
3. На этой машине установите официальный `lego` версии **5.1+** (например, 5.6.0) из <https://github.com/go-acme/lego/releases>. Старые версии не содержат DNS-провайдер `dynadot`.
На Ubuntu 24.04 x86_64 `lego 5.6.0` можно установить из официального релиза с проверкой SHA-256:

~~~bash
cd /tmp
curl -fL --retry 3 -O \
  https://github.com/go-acme/lego/releases/download/v5.6.0/lego_v5.6.0_linux_amd64.tar.gz
curl -fL --retry 3 -O \
  https://github.com/go-acme/lego/releases/download/v5.6.0/lego_5.6.0_checksums.txt
grep 'lego_v5.6.0_linux_amd64.tar.gz' lego_5.6.0_checksums.txt | sha256sum -c -
tar -xzf lego_v5.6.0_linux_amd64.tar.gz lego
sudo install -m 755 lego /usr/local/bin/lego
lego --version
~~~

Для ARM64 выберите соответствующий архив из официального релиза и аналогично проверьте checksum.

4. На машине выпуска создайте защищённый файл с ключами:

~~~bash
sudo install -d -m 700 /etc/telemtproxy
sudo install -m 600 /dev/null /etc/telemtproxy/dynadot.env
sudo nano /etc/telemtproxy/dynadot.env
~~~

Содержимое (заменить значения на свои, **не отправлять их в чат или GitHub**):

~~~bash
DYNADOT_API_KEY='ВАШ_API_KEY'
DYNADOT_API_SECRET='ВАШ_API_SECRET'
~~~

Для DNS-01 заранее не нужно добавлять TXT: `lego` создаст и удалит временную `_acme-challenge.vetka.rest` через API Dynadot.

### Выпуск и продление wildcard

На доверенной машине:

~~~bash
curl -fsSLo /tmp/dns01-dynadot.sh \
  https://raw.githubusercontent.com/Daniil-GR/TelemtProxy/main/dns01-dynadot.sh

sudo bash /tmp/dns01-dynadot.sh issue --email admin@example.org
~~~

Адрес `admin@example.org` — пример, замените на свой. По завершении файлы находятся здесь:

~~~text
/var/lib/telemtproxy/lego-vetka/certificates/_.vetka.rest.crt
/var/lib/telemtproxy/lego-vetka/certificates/_.vetka.rest.key
~~~

Продление (исполняйте ежедневно через защищённый системный cron/systemd timer):

~~~bash
sudo bash /tmp/dns01-dynadot.sh renew --email admin@example.org
~~~

Пример ежедневного продления через systemd на машине выпуска (замените email на свой):

~~~bash
sudo install -m 700 /tmp/dns01-dynadot.sh /usr/local/sbin/telemtproxy-dns01-dynadot.sh

sudo tee /etc/systemd/system/telemtproxy-wildcard-renew.service >/dev/null <<'EOF'
[Unit]
Description=Renew vetka.rest wildcard certificate using Dynadot DNS-01

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/telemtproxy-dns01-dynadot.sh renew --email admin@example.org
EOF

sudo tee /etc/systemd/system/telemtproxy-wildcard-renew.timer >/dev/null <<'EOF'
[Unit]
Description=Check wildcard certificate renewal daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=2h
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now telemtproxy-wildcard-renew.timer
sudo systemctl list-timers telemtproxy-wildcard-renew.timer
~~~

Helper использует `lego renew --days 30`, то есть новая выдача выполняется только при приближении срока. При смене сертификата он перезагружает локальный Nginx. **Helper не копирует сертификаты на другие VPS** — организуйте безопасное обновление файлов на всех используемых серверах и reload Nginx самостоятельно. Одна копия приватного ключа на многих VPS расширяет последствия компрометации.

### Установка WEB + MTProto с уже выпущенным wildcard

Скопируйте сертификат и приватный ключ на чистый VPS в защищённый каталог, например:

~~~text
/etc/telemtproxy/wildcard/fullchain.pem
/etc/telemtproxy/wildcard/privkey.pem
~~~

Приватный ключ должен быть `root:root`, с правами `600`. Затем:

~~~bash
sudo bash /tmp/telemtproxy-install.sh \
  --domain lt.vetka.rest \
  --wildcard-cert /etc/telemtproxy/wildcard/fullchain.pem \
  --wildcard-key /etc/telemtproxy/wildcard/privkey.pem
~~~

При необходимости добавьте `--hello-secret` и `--ad-tag`. Установщик проверяет сертификат и приватный ключ, запрещает сертификаты с индивидуальными именами поддоменов в SAN и **не запрашивает HTTP-01 сертификат на каждый WEB-поддомен**. Это не меняет работу MTProto на TCP 9443.

**Продление:** установщик не продлевает переданные wildcard-файлы. Когда копируете обновлённую пару в те же пути, проверьте `nginx -t` и выполните `systemctl reload nginx`. Режимы `--wildcard-cert` и `--cdn` взаимоисключающие.

