# xray-vps-setup

VLESS со своим доменом. А что еще нужно для счастья?

В данном варианте VLESS слушает на 443 и принимате все запросы, делая запрос на локальный Caddy только для сертификатов. В таком варианте задержка будет меньше, чем в варианте с Caddy/NGINX перед VLESS, где происходит множество лишних запросов.

## Отличия от [оригинала](https://github.com/Akiyamov/xray-vps-setup)

### Xray конфигурация

- Добавлен второй inbound **XHTTP + TLS (Let's Encrypt)** на порту 2087 — Caddy терминирует TLS с реальным сертификатом, трафик неотличим от обычных HTTPS-запросов. Получается Reality на 443 + реальный TLS на 2087 для диверсификации если ТСПУ детектит Reality.
- Несколько shortId разной длины вместо одного (8, 4, 2 и 1 байт)
- Добавлено правило маршрутизации для блокировки трафика на приватные IP-адреса
- `dest` заменён на `target` (актуальный формат конфигурации)
- Добавлена минимальная версия клиента (`minClientVer: 1.8.0`) и ограничение расхождения времени (`maxTimeDiff`)
- QUIC добавлен в `destOverride` для sniffing
- Уровень логирования изменён с `none` на `warning`
- Fingerprint изменён с `chrome` на `random`
- Устанавливается последняя версия xray-core вместо встроенной в образ Marzban

### Безопасность

- IPv6 firewall (оригинал защищает только IPv4)
- SSH rate limiting
- Исправлена валидация SSH-ключей и создание пользователя

### Исправления

- Корректные коды ошибок и shebang
- Исправлена работа WARP (regexp, логика ошибок)

## Скрипт

- Установит Xray/Marzban на ваш выбор. Для маскировки страницы используется [Conflunce](https://github.com/Jolymmiles/confluence-marzban-home)
- На ваше усмотрение настроит:
- - Iptables, запретив все подключения, кроме SSH, 80 и 443.
- - Создаст пользователя для подключения, запретив вход от рута
- - Добавит этому пользователю ключ для SSH, запретив вход по паролю
- Настроит WARP для ру-сайтов.

```bash
tmux
bash <(wget -qO- https://raw.githubusercontent.com/Jackardios/xray-vps-setup/refs/heads/main/vps-setup.sh)
```

## Плейбук

[Ansible-galaxy](https://galaxy.ansible.com/ui/standalone/roles/Akiyamov/xray-vps-setup/install/)

```yaml
- name: Setup vps
  hosts: some_host
  roles:
    - Akiyamov.xray-vps-setup
  vars:
    domain: example.com # домен, уровень неважен
    setup_variant: marzban # marzban or xray
    setup_warp: false # true or false
    configure_security: true # true or false
    user_to_create: xray_user # если configure_security: true, то обязательно
    user_password: "xray_password" # если configure_security: true, то обязательно
    SSH_PORT: 22 # если configure_security: true, то обязательно
    ssh_public_key: "" # если configure_security: true, то обязательно
```

## Добавляем подписку и поддержку Mihomo

```
bash <(wget -qO- https://github.com/legiz-ru/marz-sub/raw/main/marz-sub.sh)
```

После этого сделайте `docker compose -f /opt/xray-vps-setup/docker-compose.yml down && docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d`

## Ручная установка

Описана [здесь](https://github.com/Jackardios/xray-vps-setup/blob/main/install_in_docker.md).

## XHTTP в Marzban

XHTTP Host Settings (port, security, sni) настраиваются автоматически через Marzban API после запуска. Если автоматическая настройка не удалась, настройте вручную в панели Marzban:

1. Перейдите в **Host Settings** для inbound `VLESS-XHTTP`
2. Установите **Port**: `2087`, **Security**: `tls`, **SNI**: ваш домен

Это необходимо потому, что Xray слушает XHTTP на внутреннем порту `8087` без TLS (TLS терминирует Caddy), а Marzban генерирует клиентские ссылки из конфига Xray. Host Settings переопределяют эти параметры.

## Почему не nginx, haproxy, 3x-ui, x-ui, sing-box...

Caddy сам получит сертификаты, поэтому нам не придется их получать через `acme.sh` или `certbot`.
3X-ui мерзотная панель.
Sing-box не очень.
