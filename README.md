# TelemtProxy

Два независимых установщика Telemt для чистого Ubuntu 24.04 VPS: WEB + MTProto и облегчённый вариант только MTProto.

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

Также можно передать домен параметром:

```bash
sudo bash /tmp/telemtproxy-install.sh proxy.example.org
```

**Важно:** скачивайте установщик в файл, а не запускайте `curl | bash`: внутри `deploy.sh` находятся архивированные ресурсы заглушки, которые скрипт читает из собственного файла.


## Быстрая установка только MTProto

Для VPS, где WEB-прокси не нужен, используйте отдельный установщик `deploy-mtproto.sh`. Он не меняет и не вызывает `deploy.sh`.

Создайте DNS A-запись выбранного поддомена на IP нового VPS, затем выполните:

~~~bash
curl -fsSLo /tmp/telemt-mtproto.sh https://raw.githubusercontent.com/Daniil-GR/TelemtProxy/main/deploy-mtproto.sh
sudo bash /tmp/telemt-mtproto.sh
~~~

При запуске скрипт спросит домен **для Telegram-ссылки**, например `lt.vetka.rest`. Можно сразу передать его параметром: `sudo bash /tmp/telemt-mtproto.sh lt.vetka.rest`.

Настройки этого режима:

- **Только обычный MTProto:** публичный TCP-порт 443. Nginx, Certbot и WEB-listener не настраиваются.
- **Пользователь:** всегда `hello`, а секрет генерируется **заново для каждого VPS** (32 HEX-символа).
- **FakeTLS/SNI:** всегда `www.booking.com`, включён режим `ee`.
- **Адрес для Telegram-ссылок:** введённый поддомен, через `[general.links].public_host`.
- **Версия Telemt:** последний стабильный релиз через MEKOPR; дополнительно ставится SYN FIX v3 на 443.
- **Спонсорский канал:** `ad_tag` по умолчанию пуст. При необходимости добавьте тег после регистрации в @MTProxybot.
- **Ссылка:** сохранена в `/root/telemt-mtproto-link.txt` с доступом для root.

Финальная ссылка будет иметь вид `tg://proxy?server=ПОДДОМЕН&port=443&secret=ee...`. Не используйте промежуточные ссылки, которые выводит MEKOPR до замены его первоначальной конфигурации; используйте блок `READY` в конце работы.

Проверка после установки:

~~~bash
systemctl is-active telemt
ss -lntp | grep ':443'
sudo cat /root/telemt-mtproto-link.txt
~~~

Установщик предназначен для **чистого VPS**: он не перезаписывает действующие конфигурации Telemt/MEKOPR и не занимает чужой порт 443. Для Floating IP DNS A-запись должна указывать на адрес интерфейса VPS либо на определяемый внешний IPv4.

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
