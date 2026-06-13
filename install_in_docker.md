<h1 align="center">VLESS + Reality Self Steal в Docker</h2>

### Что потребуется:

- VPS
- Свой домен

В статье будет рассмотрена установка как чистого Xray, так и Marzban.

## Настройка сервера

### Настройка SSH

На своем ПК, неважно, GNU/Linux или Windows. **На Windows используйте Powershell**. Открываем терминал и выполняем следующую команду:

```bash
ssh-keygen -t ed25519
```

После выполнения команды вам предложат изменить место хранения ключа и добавить пароль к нему. Менять локацию не надо, пароль же можете добавить ради безопасности.
Создав ключ, вам будет выведена локация публичной и приватной его части, нам нужно перекинуть публичную часть этого ключа на нашу VPS.  
На Linux:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub ваш_пользователь@ваша_vps
```

На Windows:

```powershell
ssh-copy-id -i $env:USERPROFILE\.ssh\id_ed25519.pub ваш_пользователь@ваша_vps
```

Если данная команда у вас не сработала на Windows, то нужно выполнить следующую:

```powershell
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh ваш_пользователь@ваша_vps "cat >> .ssh/authorized_keys"
```

**Далее все делается на VPS.**  
Для отключения входа по паролю создадим дополнительный файл конфигурации ssh. Редактируем с помощью nano или vim, что удобнее.:

```bash
nano /etc/ssh/sshd_config.d/00-disable-password.conf
```

После этого вставляем:

```
Port 22
PasswordAuthentication no
```

Если хотим поменять порт SSH, то меняем 22 на нужный нам.  
Сделав это можно перезапустить SSH.

```bash
sudo systemctl restart ssh
```

### Настройки iptables

Нам нужно оставить открытыми порты для SSH(не забыли, что поменяли секунду назад?), 80 и 443.
Для этого нужно выполнить следующие команды:

```bash
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp -m tcp --dport 443 -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -P INPUT DROP
iptables-save > /etc/network/iptables.rules
```

### Включение BBR

Достаточно выполнить следующие команды:

```bash
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p
```

## Создание прокси

### Установка Docker

Для установки нужно выполнить следующую команду:

```bash
curl -fsSL https://get.docker.com | sh
```

Если вы работаете не от админа, то выполните следующие команды, чтобы не писать `sudo` каждый раз:

```bash
sudo groupadd docker
sudo usermod -aG docker $USER
```

### Получение данных для прокси

В этой части будут описаны необходимые данные, а также способ их получения. Позже эти данные будут использованы в конфигурации.

- **VLESS_DOMAIN**: Ваш домен. Если используется punycode, то далее используется ТОЛЬКО на латинице.
- **XRAY_PBK+PIK**: `docker run --rm ghcr.io/xtls/xray-core x25519`
  Оба значения для нас важны, Public key = PBK, Password = PIK.
- **XRAY_SID**: ``
  Short id, а не генерируем его. Рудимент, который не особо нужен.

Следующие данные нужны только если вы будете устанавливать панель Marzban.

- **MARZBAN_USER**: `grep -E '^[a-z]{4,6}$' /usr/share/dict/words | shuf -n 1`  
  Пользователь панели
- **MARZBAN_PASS**: `tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo`  
  Пароль пользователя панели
- **MARZBAN_PATH**: `openssl rand -hex 8`  
  URL панели
- **MARZBAN_SUB_PATH**: `openssl rand -hex 8`  
  URL подписок

### Настройка прокси

Создадим папку `/opt/xray-vps-setup` командой `mkdir -p /opt/xray-vps-setup`.  
После этого переходим в папку и создаем в ней файл `docker-compose.yml`

<details>
  <summary>Marzban</summary>

```yaml
services:
  angie:
    image: docker.angie.software/angie:minimal
    container_name: angie
    restart: always
    network_mode: host
    volumes:
      - angie-data:/var/lib/angie
      - ./angie.conf:/etc/angie/angie.conf
      - ./index.html:/tmp/index.html
  marzban:
    image: gozargah/marzban:latest
    container_name: marzban
    restart: always
    env_file: ./marzban/.env
    network_mode: host
    volumes:
      - ./marzban/xray_config.json:/code/xray_config.json
      - ./marzban/xray-core:/var/lib/marzban/xray-core

volumes:
  angie-data:
    driver: local
    external: false
    name: angie-data
```

</details>
<details>
  <summary>Xray</summary>

```yaml
services:
  angie:
    image: docker.angie.software/angie:minimal
    container_name: angie
    restart: always
    network_mode: host
    volumes:
      - angie-data:/var/lib/angie
      - ./angie.conf:/etc/angie/angie.conf
      - ./index.html:/tmp/index.html
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray
    restart: always
    network_mode: host
    user: root
    volumes:
      - ./xray:/etc/xray
    entrypoint: ["xray", "-config", "/etc/xray/config.json"]

volumes:
  angie-data:
    driver: local
    external: false
    name: angie-data
```

</details>
Создаем конфиг angie `/opt/xray-vps-setup/angie.conf` и меняем его следующим образом.

<details><summary>Marzban</summary>

```conf
user angie;
worker_processes auto;

error_log /var/log/angie/error.log notice;

events {
    worker_connections 1024;
}

http {
    log_format main '[$time_local] $proxy_protocol_addr "$http_referer" "$http_user_agent"';
    access_log /var/log/angie/access.log main;

    server {
        listen 80;
        listen [::]:80;
        return 301 https://$host$request_uri;
    }

    resolver 1.1.1.1;

    acme_client vless https://acme-v02.api.letsencrypt.org/directory;

    server {
        listen                  127.0.0.1:4123 ssl default_server;

        ssl_reject_handshake    on;

        ssl_protocols           TLSv1.2 TLSv1.3;

        ssl_session_timeout     1h;
        ssl_session_cache       shared:SSL:10m;
    }

    server {
        listen                     127.0.0.1:4123 ssl proxy_protocol;
        http2                      on;

        set_real_ip_from           127.0.0.1;
        real_ip_header             proxy_protocol;

        server_name                $VLESS_DOMAIN;

        acme vless;
        ssl_certificate $acme_cert_vless;
        ssl_certificate_key $acme_cert_key_vless;

        ssl_protocols              TLSv1.2 TLSv1.3;
        ssl_ciphers                TLS13_AES_128_GCM_SHA256:TLS13_AES_256_GCM_SHA384:TLS13_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;
        ssl_prefer_server_ciphers  on;

        ssl_stapling               on;
        ssl_stapling_verify        on;
        resolver                   1.1.1.1 valid=60s;
        resolver_timeout           2s;

        location ~* /($MARZBAN_PATH|statics|$MARZBAN_SUB_PATH|api|docs|redoc|openapi.json) {
            # (опционально) отказать клиенту Happ: он отдаёт xray API на localhost
            # без пароля, один скомпрометированный юзер = дамп/правка конфигов.
            if ($http_user_agent ~* "Happ") { return 403; }
            proxy_pass http://127.0.0.1:8000;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }

        location / {
            root /tmp;
            index index.html;
        }
    }
}

```

</details>
<details><summary>Чистый Xray</summary>

```conf
user angie;
worker_processes auto;

error_log /var/log/angie/error.log notice;

events {
    worker_connections 1024;
}

http {
    log_format main '[$time_local] $proxy_protocol_addr "$http_referer" "$http_user_agent"';
    access_log /var/log/angie/access.log main;

    server {
        listen 80;
        listen [::]:80;
        return 301 https://$host$request_uri;
    }

    resolver 1.1.1.1;

    acme_client vless https://acme-v02.api.letsencrypt.org/directory;

    server {
        listen                  127.0.0.1:4123 ssl default_server;

        ssl_reject_handshake    on;

        ssl_protocols           TLSv1.2 TLSv1.3;

        ssl_session_timeout     1h;
        ssl_session_cache       shared:SSL:10m;
    }

    server {
        listen                     127.0.0.1:4123 ssl proxy_protocol;
        http2                      on;

        set_real_ip_from           127.0.0.1;
        real_ip_header             proxy_protocol;

        server_name                $VLESS_DOMAIN;

        acme vless;
        ssl_certificate $acme_cert_vless;
        ssl_certificate_key $acme_cert_key_vless;

        ssl_protocols              TLSv1.2 TLSv1.3;
        ssl_ciphers                TLS13_AES_128_GCM_SHA256:TLS13_AES_256_GCM_SHA384:TLS13_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;
        ssl_prefer_server_ciphers  on;

        ssl_stapling               on;
        ssl_stapling_verify        on;
        resolver                   1.1.1.1 valid=60s;
        resolver_timeout           2s;

        location / {
            root /tmp;
            index index.html;
        }
    }
}
```

</details>

Настроив Angie требуется добавить страницу для маскировки. Скрипт `vps-setup.sh` (функция `write_decoy`) рандомизирует бренд, текст, палитру и год на каждом сервере, чтобы страницу нельзя было сфингерпринтить по байтам/цвету. Для ручной установки можно взять тот же шаблон и подставить один набор значений:

```bash
export DECOY_BRAND="Northwind"
export DECOY_TAGLINE="Sign in to continue"
export DECOY_TITLE="Sign in · $DECOY_BRAND"
export DECOY_NONCE=$(openssl rand -hex 16)
export DECOY_YEAR=$(date +%Y)
export DECOY_BG="#0d1117"; export DECOY_PANEL="#161b22"; export DECOY_BORDER="#30363d"
export DECOY_FG="#e6edf3"; export DECOY_MUTED="#8b949e"
export DECOY_ACCENT="#2f81f7"; export DECOY_ACCENT2="#1f6feb"
export DECOY_ACCENT_FG="#ffffff"; export DECOY_INPUT_BG="#0d1117"
wget -qO- https://raw.githubusercontent.com/Jackardios/xray-vps-setup/refs/heads/main/templates_for_script/decoy \
  | envsubst '$DECOY_BRAND $DECOY_TAGLINE $DECOY_TITLE $DECOY_NONCE $DECOY_YEAR $DECOY_BG $DECOY_PANEL $DECOY_BORDER $DECOY_FG $DECOY_MUTED $DECOY_ACCENT $DECOY_ACCENT2 $DECOY_ACCENT_FG $DECOY_INPUT_BG' \
  > /opt/xray-vps-setup/index.html
```

После этого надо создать файл конфигурации Xray, если вы ставите marzban, то он будет находится в `/opt/xray-vps-setup/marzban/xray_config.json`, если чистый xray, то `/opt/xray-vps-setup/xray/config.json`

```json
{
  "log": {
    "loglevel": "none"
  },
  "inbounds": [
    {
      "tag": "VLESS TCP VISION REALITY",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "XRAY_UUDI", // ПОМЕНЯТЬ НА СВОЕ
            "email": "default",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "xver": 1,
          "dest": "127.0.0.1:4123",
          "serverNames": [
            "VLESS_DOMAIN" // ПОМЕНЯТЬ НА СВОЕ
          ],
          "privateKey": "XRAY_PIK", // ПОМЕНЯТЬ НА СВОЕ
          "shortIds": [""]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "rules": [
      {
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "protocol": "bittorrent",
        "outboundTag": "block"
      }
    ],
    "domainStrategy": "IPIfNonMatch"
  },
  "dns": {
    "servers": ["1.1.1.1", "8.8.8.8"],
    "queryStrategy": "UseIPv4",
    "disableFallback": false,
    "tag": "dns-aux"
  }
}
```

Для Marzban необходимо также добавить `.env` файл. Создайте файл `/opt/xray-vps-setup/marzban/.env` и вставьте следующее:

```conf
SUDO_USERNAME = "xray_admin" # Хоть и важно поменять пароль, лучше поставить своего юзера
SUDO_PASSWORD = "$MARZBAN_PASS"
UVICORN_UDS = "/var/lib/marzban/marzban.socket"
DASHBOARD_PATH = "/$MARZBAN_PATH/"
XRAY_JSON = "xray_config.json"
XRAY_SUBSCRIPTION_URL_PREFIX = "https://$VLESS_DOMAIN"
XRAY_SUBSCRIPTION_PATH = "$MARZBAN_SUB_PATH"
SQLALCHEMY_DATABASE_URL = "sqlite:////var/lib/marzban/db.sqlite3"
CUSTOM_TEMPLATES_DIRECTORY="/var/lib/marzban/templates/"
SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"
```

## Настройка WARP

Для того, чтобы доабвить WARP для того, чтобы в Россию наш юзер ходил черзе него, то надо сделать следующее.  
Устанавливаем WARP:

```bash
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
apt update
apt install cloudflare-warp -y
```

Настроим WARP:

```bash
warp-cli registration new
warp-cli mode proxy
warp-cli proxy port 40000
warp-cli connect
```

Если на этом этапе ловим ошибку подключения, то не продолжайте, WARP не рабоатет.  
Установка `yq`:

```bash
wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq && chmod +x /usr/bin/yq
```

Далее с помощью `yq` мы установим в уже существующий кофниг WARP. В список доменов, помимо ру-сайтов, добавлены известные сервисы определения IP (`api.ipify.org`, `ifconfig.me`, `ipinfo.io`, `ip-api.com`, `ip.sb` и т.д.): так типовой зонд из соседнего приложения, нашедшего локальный SOCKS-прокси, увидит IP Cloudflare, а не вашего сервера (подробнее — в разделе «Защита клиента от localhost-утечки»).

```bash
yq eval '.outbounds += {"tag": "warp","protocol": "socks","settings": {"servers": [{"address": "127.0.0.1","port": 40000}]}}' -i $XRAY_CONFIG_WARP
yq eval '.routing.rules += {"outboundTag": "warp", "domain": ["geosite:category-ru", "regexp:.*\\.xn--[a-z0-9]+$", "regexp:.*\\.ru$", "regexp:.*\\.su$", "domain:api.ipify.org", "domain:api4.ipify.org", "domain:api6.ipify.org", "domain:api64.ipify.org", "domain:checkip.amazonaws.com", "domain:ifconfig.me", "domain:ifconfig.co", "domain:icanhazip.com", "domain:ident.me", "domain:ipinfo.io", "domain:api.myip.com", "domain:ip.seeip.org", "domain:ipecho.net", "domain:wgetip.com", "domain:ip-api.com", "domain:ip.sb", "domain:api.ip.sb", "domain:whatismyip.akamai.com", "domain:yandex.net", "domain:avito.st"]}' -i $XRAY_CONFIG_WARP

```

Заменяем $XRAY_CONFIG_WARP на `/opt/xray-vps-setup/marzban/xray_config.json` для marzban и на `/opt/xray-vps-setup/xray/config.json` для чистого xray. После этого перезапускаем все:

```bash
docker compose -f /opt/xray-vps-setup/docker-compose.yml down && docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d
```

## Split-IP: разделение входного и выходного IP

Если входной IP (на котором слушает Reality) совпадает с выходным, то утёкший выходной IP — это и есть точка входа. РКН коррелирует его с netflow провайдера (`два IP в одно время от одного NAT → один из них туннель`) и блокирует сервер. Полное решение — принимать Reality на одном (скрытом, ingress) IP, а выпускать трафик через другой (видимый, egress). Нужен **второй IPv4**, уже привязанный провайдером к серверу.

**1. Сеть.** egress-адрес должен быть системным дефолтом — в `systemd-networkd` он идёт **первым**:

```ini
[Match]
Name=eth0

[Network]
Address=EGRESS_IP/24   # первым → системный дефолт (исходящие сервера идут отсюда)
Address=INGRESS_IP/24
Gateway=EGRESS_GW
```

A-запись домена должна указывать на **ingress IP**; AAAA-запись лучше убрать (split — только IPv4).

**2. xray.** В инбаунде вместо `"listen": "0.0.0.0"` укажите ingress, а `direct`-аутбаунду добавьте `sendThrough` с egress:

```json
"inbounds": [
  { "listen": "INGRESS_IP", "port": 443, "...": "..." }
],
"outbounds": [
  {
    "protocol": "freedom",
    "tag": "direct",
    "sendThrough": "EGRESS_IP",
    "settings": { "domainStrategy": "UseIPv4" }
  },
  { "protocol": "blackhole", "tag": "block" }
]
```

WARP-аутбаунд (socks на `127.0.0.1`) трогать не нужно — он и так выходит через Cloudflare; `sendThrough` важен только для `direct`.

**3. iptables.** На ingress открыты только 80/443, SSH — только на egress (так ingress отвечает лишь Reality+ACME и не светит SSH):

```bash
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A INPUT -p tcp -d EGRESS_IP  -m tcp --dport 22  -j ACCEPT
iptables -A INPUT -p tcp -d INGRESS_IP -m tcp --dport 80  -j ACCEPT
iptables -A INPUT -p tcp -d INGRESS_IP -m tcp --dport 443 -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -P INPUT DROP
iptables-save > /etc/network/iptables.rules
```

После этого ходите по SSH **через egress IP**. Берите ingress и egress из **разных** подсетей — иначе бан подсети заберёт оба.

## Защита клиента от localhost-утечки

VPN-клиенты (v2rayNG, Hiddify, NekoBox и т.п.) поднимают на устройстве **локальный SOCKS-прокси без пароля** (обычно `127.0.0.1:10808`). Любое приложение-сосед (Яндекс, WB, Ozon, MAX, гос.приложения) может за секунды найти его, подключиться без авторизации, прогнать через него трафик и **узнать выходной IP сервера** → IP уходит в РКН → блок. Что делать:

- Включите на локальном SOCKS **авторизацию** (логин+пароль) и `udp:false`.
- Клиенты с поддержкой auth: **Husi**, SFA, saeeddev94/xray; Clash/mihomo в режиме TUN-only безопасен по умолчанию. **Не используйте Happ** (отдаёт xray API на localhost без пароля). sing-box — только **≥ 1.4.5** (CVE-2023-43644).
- Проверить устройство: [per-app-split-bypass-poc](https://github.com/runetfreedom/per-app-split-bypass-poc) — при включённой auth должно показать «VPN not found».

Готовый «hardened» клиентский конфиг xray (SOCKS с паролем + блок приватных IP/торрентов). Сгенерируйте свои `user`/`pass` (`tr -dc A-Za-z0-9 </dev/urandom | head -c 16; echo`) и подставьте `VLESS_DOMAIN`/`XRAY_UUID`/`XRAY_PBK`/`XRAY_SID`:

```json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "udp": false,
        "accounts": [ { "user": "СВОЙ_ЛОГИН", "pass": "СВОЙ_ПАРОЛЬ" } ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "default",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "VLESS_DOMAIN",
            "port": 443,
            "users": [ { "id": "XRAY_UUID", "encryption": "none", "flow": "xtls-rprx-vision" } ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "VLESS_DOMAIN",
          "fingerprint": "firefox",
          "publicKey": "XRAY_PBK",
          "shortId": "XRAY_SID",
          "spiderX": "/"
        }
      }
    },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "ip": ["geoip:private"], "outboundTag": "block" },
      { "protocol": "bittorrent", "outboundTag": "block" }
    ]
  }
}
```

## Заметки по обходу DPI

«Сибирский» DPI (июнь 2026) блокирует Reality только при одновременном совпадении трёх сигналов — достаточно разорвать любой:

- **Хостинг (Сигнал 1).** Избегайте Selectel, Yandex.Cloud, Hetzner, DigitalOcean, OVH; проверяйте подсеть через [dpi-checkers](https://github.com/hyperion-cs/dpi-checkers).
- **Фингерпринт (Сигнал 2).** В клиенте используйте `fp=firefox` (лояльный отпечаток), а не `chrome`/`safari`/`randomized`. Не меняйте его под деградацией — это эскалирует блок со 120 до 600 секунд.
- **Поведение (Сигнал 3).** Один SNI + Vision (без TCP-mux) — потенциально слабое место, которое гасится лояльным фингерпринтом.

#

Если вы хотите помочь что-то исправить, добавить и тд, то делайте PR или пишите в [ТГ](https://t.me/Akiyamov).
