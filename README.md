# xray-vps-setup
VLESS со своим доменом. А что еще нужно для счастья?

В данном варианте VLESS слушает на 443 и принимает все запросы, делая запрос на локальный Caddy только для сертификатов. В таком варианте задержка будет меньше, чем в варианте с Caddy/NGINX перед VLESS, где происходит множество лишних запросов.

## Скрипт

- Установит Marzneshin + Marznode. Для маскировки страницы используется [Confluence](https://github.com/Jolymmiles/confluence-marzban-home)
- На ваше усмотрение настроит:
- - UFW, запретив все подключения, кроме SSH, 80 и 443
- - Создаст пользователя для подключения, запретив вход от рута
- - Добавит этому пользователю ключ для SSH, запретив вход по паролю

## Установка

```bash
bash <(wget -qO- https://raw.githubusercontent.com/artemscine/xray-vps-setup/refs/heads/main/vps-setup.sh)
```

Режимы установки:
- **1** — Полная установка (Marzneshin + Marznode + Caddy)
- **2** — Только нода (Marznode для удалённой панели и Caddy для selfsteal)

## Удаление

```bash
bash <(wget -qO- https://raw.githubusercontent.com/artemscine/xray-vps-setup/refs/heads/main/uninstall.sh)
```
