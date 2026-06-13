# xray-vps-setup
VLESS со своим доменом. А что еще нужно для счастья?  

В данном варианте VLESS слушает на 443 и принимает все запросы, делая запрос на локальный Angie(форк nginx) только для сертификатов. В таком варианте задержка будет меньше, чем в варианте с Caddy/NGINX перед VLESS, где происходит множество лишних запросов. 
## Скрипт

- Установит Xray/Marzban на ваш выбор. Для маскировки страницы используется [Confluence](https://github.com/Jolymmiles/confluence-marzban-home)
- На ваше усмотрение настроит:
- - Создаст пользователя для подключения, запретив вход от рута, добавит ему ключ для SSH и запретит вход по паролю. Вместе с этим шагом настраивается iptables (IPv4 и IPv6), запрещая все подключения, кроме SSH, 80 и 443.
- - Настроит WARP для ру-сайтов.  
```bash
tmux
bash <(wget -qO- https://raw.githubusercontent.com/Akiyamov/xray-vps-setup/refs/heads/main/vps-setup.sh)
```

## Добавляем подписку и поддержку Mihomo

```
bash <(wget -qO- https://github.com/legiz-ru/marz-sub/raw/main/marz-sub.sh)
```
После этого сделайте `docker compose -f /opt/xray-vps-setup/docker-compose.yml down && docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d` 


## Ручная установка

Описана [здесь](https://github.com/Akiyamov/xray-vps-setup/blob/main/install_in_docker.md).  

## Почему не <strike>nginx</strike>caddy, haproxy, 3x-ui, x-ui, sing-box...

<strike>Caddy</strike> Angie сам получит сертификаты, поэтому нам не придется их получать через `acme.sh` или `certbot`.  
3X-ui мерзотная панель.  
Sing-box не очень.  
XHTTP позже, а больше не надо. Уже точно. 

## Связь
Issues, PR ну или мой [тг](https://t.me/Akiyamov).
