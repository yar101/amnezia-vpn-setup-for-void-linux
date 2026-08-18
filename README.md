# AmneziaVPN Setup for Void Linux

Установочный скрипт и компоненты для запуска официального клиента **AmneziaVPN** (GUI + фоновая служба) на **Void Linux** (runit, без `systemd`).

---

## Архитектура решения

Официальный клиент AmneziaVPN рассчитан на дистрибутивы с `systemd` и `systemd-resolved`. Для полноценной работы в Void Linux реализовано:

1. **Обход установщика:** Подмена `systemctl` фиктивной заглушкой на время выполнения официального `.run`-инсталлятора.
2. **D-Bus DNS-мост (`amnezia-dns-bridge`):**
   - Python-демон, реализующий интерфейс `org.freedesktop.resolve1` в системной шине D-Bus (`SetLinkDNS`, `SetLinkDomains`, `RevertLink`).
   - Перехватывает вызовы AmneziaVPN и транслирует их в `openresolv` (`resolvconf -a amnezia-vpn -x -m 0`) в эксклюзивном режиме, предотвращая утечки DNS (DNS Leaks).
   - Встроенный **Watchdog ядра**: периодически отслеживает состояние сетевых интерфейсов и автоматически сбрасывает DNS при разрыве или закрытии VPN-соединения.
3. **Сервисы Runit:** Создание и регистрация служб `AmneziaVPN` и `amnezia-dns-bridge` в `/etc/sv/`.
4. **Интеграция с рабочим окружением:** Создание симлинков в `/usr/local/bin`, регистрация `.desktop`-файла и иконок.

---

## Системные зависимости

Скрипт автоматически устанавливает необходимые пакеты через `xbps-install`:

- **Сеть и протоколы:** `wireguard-tools`, `openvpn`, `openresolv`, `iptables`, `iproute2`
- **DNS-мост и D-Bus:** `dbus`, `python3`, `python3-dbus`, `python3-gobject`
- **Графическое окружение и Qt:** `libsecret`, `libglvnd`, `libxcb`, `xcb-util-cursor`, `xcb-util-wm`, `xcb-util-keysyms`, `xcb-util-image`, `xcb-util-renderutil`, `libxkbcommon`, `libxkbcommon-x11`
- **Ядро:** Модуль `tun` (`modprobe tun`)

---

## Установка

1. Склонируйте репозиторий:
   ```bash
   git clone git@github.com:yar101/amnezia-vpn-setup-for-void-linux.git
   cd amnezia-vpn-setup-for-void-linux
   ```

2. Сделайте скрипт исполняемым:
   ```bash
   chmod +x install_amnezia_void.sh
   ```

3. Запустите установку:
   ```bash
   ./install_amnezia_void.sh
   ```
   > Если файл `AmneziaVPN_*_linux_x64.run` не найден в каталоге, скрипт автоматически скачает официальный релиз с GitHub.

---

## Запуск и управление службами (runit)

### 1. Активация и запуск сервисов
```bash
sudo ln -s /etc/sv/amnezia-dns-bridge /var/service/
sudo ln -s /etc/sv/AmneziaVPN /var/service/
```

### 2. Проверка статуса
```bash
sudo sv status amnezia-dns-bridge AmneziaVPN
```

### 3. Запуск графического интерфейса
Запустите приложение через меню вашей среды или из терминала:
```bash
AmneziaVPN
```

### 4. Управление службами
- **Остановить:**
  ```bash
  sudo sv down AmneziaVPN amnezia-dns-bridge
  ```
- **Запустить:**
  ```bash
  sudo sv up AmneziaVPN amnezia-dns-bridge
  ```
- **Удалить из автозагрузки:**
  ```bash
  sudo rm /var/service/AmneziaVPN /var/service/amnezia-dns-bridge
  ```

---

## Полезная информация

- **Логи службы:**
  Логи демона VPN сохраняются в директорию `/var/log/AmneziaVPN/`.
- **Служба D-Bus:**
  Убедитесь, что системный сервис `dbus` включен и запущен (`sudo sv status dbus`).
- **Сброс DNS вручную (при необходимости):**
  ```bash
  sudo resolvconf -d amnezia-vpn && sudo resolvconf -u
  ```
