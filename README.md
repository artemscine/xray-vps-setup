# xray-vps-setup
VLESS со своим доменом. А что еще нужно для счастья?

В данном варианте VLESS слушает на 443 и принимает все запросы, делая запрос на локальный Caddy только для сертификатов. В таком варианте задержка будет меньше, чем в варианте с Caddy/NGINX перед VLESS, где происходит множество лишних запросов.

## Скрипт

- Установит Marzneshin + Marznode (или только ноду). Для маскировки используется [Confluence](https://github.com/Jolymmiles/confluence-marzban-home)
- Настроит VLESS Reality (TCP/443), опционально XHTTP (TCP/8443) и Hysteria2 (UDP/8443)
- Поднимет Caddy для selfsteal
- Создаст админа панели и зарегистрирует локальную ноду (в полной установке)
- По желанию настроит безопасность сервера:
- - UFW (SSH, 80, 443, при необходимости 8443 и gRPC)
- - Пользователя для SSH, запретив вход от рута
- - SSH-ключ, запретив вход по паролю

## Установка

```bash
bash <(wget -qO- https://raw.githubusercontent.com/artemscine/xray-vps-setup/refs/heads/main/vps-setup.sh)
```

Режимы установки:
- **1** — Полная установка (Marzneshin + Marznode + Caddy)
- **2** — Только нода (Marznode для удалённой панели и Caddy для selfsteal)

После установки скрипт выводит:
- Ссылку на панель и данные для входа (режим 1)
- Данные для добавления ноды во внешнюю панель (режим 2)
- Reality Public Key / Short ID, а также параметры XHTTP/Hysteria2 (если включены)

## Удаление

```bash
bash <(wget -qO- https://raw.githubusercontent.com/artemscine/xray-vps-setup/refs/heads/main/uninstall.sh)
```
