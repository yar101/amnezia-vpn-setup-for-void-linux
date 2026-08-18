# AmneziaVPN Setup for Void Linux

<p align="center">
  <b><a href="README.md">English</a></b> | <b>Русский</b>
</p>

Установочный скрипт и сопутствующие компоненты для запуска официального десктопного клиента **AmneziaVPN** (Qt6 GUI + фоновая служба `AmneziaVPN-service`) на **Void Linux** (glibc x86_64, система инициализации `runit`, без `systemd` и `systemd-resolved`).

---

## Архитектура решения

Официальный клиент AmneziaVPN жестко ориентирован на дистрибутивы с `systemd` и `systemd-resolved`. Для его полноценной работы в Void Linux реализовано:

1. **Обход установщика:** Подмена `systemctl` фиктивной заглушкой на время выполнения официального `.run`-инсталлятора (Qt Installer Framework).
2. **D-Bus DNS-мост (`amnezia-dns-bridge`):**
   - Python-демон, реализующий интерфейс `org.freedesktop.resolve1` в системной шине D-Bus (`SetLinkDNS`, `SetLinkDNSEx`, `SetLinkDomains`, `RevertLink`, `RevertLinkDNS`).
   - Перехватывает вызовы AmneziaVPN и транслирует их в `openresolv` (`resolvconf -a amnezia-vpn -x -m 0`) в эксклюзивном режиме, предотвращая утечки DNS (DNS Leaks).
   - Передает поисковые домены (`search domains`) для корректного разрешения имен во внутренних сетях.
   - Поддержка протоколов и туннельных интерфейсов: **AmneziaWG (`awg*`)**, **WireGuard (`wg*`)**, **OpenVPN (`tun*`)**, `tap*`, `amn*`, `ppp*`, `vpn*`.
   - Встроенный **Watchdog ядра**: периодически отслеживает состояние сетевых интерфейсов и автоматически сбрасывает DNS при разрыве или закрытии VPN-соединения.
3. **Безопасность D-Bus:** Изолированная политика в `/etc/dbus-1/system.d/org.freedesktop.resolve1.conf` с доступом только для `root`.
4. **Службы Runit:** Создание и регистрация служб `AmneziaVPN` и `amnezia-dns-bridge` в `/etc/sv/` со встроенным потоковым логированием и ротацией через `svlogd`.
5. **Интеграция с рабочим окружением:** Создание симлинков в `/usr/local/bin`, регистрация `.desktop`-файла и установка иконки приложения.

---

## Структура репозитория

```text
.
├── install_amnezia_void.sh     # Скрипт автоматической установки
├── uninstall_amnezia_void.sh   # Скрипт полного удаления
├── assets/
│   └── AmneziaVPN.png          # Официальная иконка приложения
├── src/
│   └── amnezia-dns-bridge.py   # D-Bus DNS-мост (org.freedesktop.resolve1)
├── conf/
│   ├── org.freedesktop.resolve1.conf  # D-Bus политика безопасности
│   └── AmneziaVPN.desktop             # Ярлык приложения XDG
└── services/
    ├── AmneziaVPN/             # Runit-сервис AmneziaVPN-service (+ svlogd)
    │   ├── run
    │   └── log/run
    └── amnezia-dns-bridge/     # Runit-сервис DNS-моста (+ svlogd)
        ├── run
        └── log/run
```

---

## Системные зависимости

Скрипт автоматически устанавливает необходимые пакеты через `xbps-install`:

- **Сеть и утилиты:** `curl`, `wireguard-tools`, `openvpn`, `openresolv`, `iptables`, `iproute2`
- **DNS-мост и D-Bus:** `dbus`, `python3`, `python3-dbus`, `python3-gobject`, `procps-ng`
- **Графическое окружение и Qt6:** `libsecret`, `libglvnd`, `libxcb`, `xcb-util-cursor`, `xcb-util-wm`, `xcb-util-keysyms`, `xcb-util-image`, `xcb-util-renderutil`, `libxkbcommon`, `libxkbcommon-x11`
- **Ядро:** Модуль `tun` (`modprobe tun`)

---

## Установка

1. Склонируйте репозиторий:
   ```bash
   git clone https://github.com/yar101/amnezia-vpn-setup-for-void-linux.git
   cd amnezia-vpn-setup-for-void-linux
   ```

2. Сделайте скрипт исполняемым:
   ```bash
   chmod +x install_amnezia_void.sh uninstall_amnezia_void.sh
   ```

3. Запустите установку:
   ```bash
   ./install_amnezia_void.sh
   ```

   > [!NOTE]
   > Если файл `AmneziaVPN_*_linux_x64.run` не найден в каталоге, скрипт автоматически скачает официальный релиз с GitHub Releases.
   > Для установки конкретной версии можно передать её аргументом: `./install_amnezia_void.sh 5.0.0.5`

---

## Использование и управление службами (runit)

После завершения скрипта установки службы `AmneziaVPN` и `amnezia-dns-bridge` **автоматически активируются и запускаются**.

### 1. Проверка статуса служб
```bash
sudo sv status amnezia-dns-bridge AmneziaVPN
```

### 2. Запуск графического интерфейса
Запустите приложение через меню вашей среды или из терминала:
```bash
AmneziaVPN
```

### 3. Управление службами
- **Остановить:**
  ```bash
  sudo sv down AmneziaVPN amnezia-dns-bridge
  ```
- **Запустить:**
  ```bash
  sudo sv up AmneziaVPN amnezia-dns-bridge
  ```
- **Отключить автозапуск:**
  ```bash
  sudo rm /var/service/AmneziaVPN /var/service/amnezia-dns-bridge
  ```

---

## Логирование и диагностика

- **Логи сервиса VPN:**
  ```bash
  tail -f /var/log/AmneziaVPN/current
  ```
- **Логи DNS-моста:**
  ```bash
  tail -f /var/log/amnezia-dns-bridge/current
  ```
- **Просмотр текущих DNS записей openresolv:**
  ```bash
  resolvconf -l
  ```
- **Сброс DNS вручную (при необходимости):**
  ```bash
  sudo resolvconf -f -d amnezia-vpn && sudo resolvconf -u
  ```

---

## Устранение неполадок (Troubleshooting)

1. **GUI сообщает: «Служба AmneziaVPN не запущена» / Service connection failed:**
   - Проверьте статус службы runit:
     ```bash
     sudo sv status AmneziaVPN
     ```
   - Проверьте логи в `/var/log/AmneziaVPN/current`.

2. **Не резолвятся домены после подключения:**
   - Убедитесь, что служба `amnezia-dns-bridge` активна:
     ```bash
     sudo sv status amnezia-dns-bridge
     ```
   - Проверьте `/etc/resolv.conf` и вывод `resolvconf -l`. При активном туннеле должна присутствовать запись `nameserver` от `amnezia-vpn`.

3. **Конфликты с NetworkManager / dhcpcd:**
   - Пакет `openresolv` автоматически объединяет DNS от разных провайдеров. DNS от `amnezia-vpn` имеет флаг эксклюзивности (`-x`) и наивысший приоритет (`-m 0`), что предотвращает утечки через локальный DNS сетевого адаптера.

---

## Удаление

Для полного удаления AmneziaVPN, служб runit, DNS-моста и ярлыков выполните:
```bash
./uninstall_amnezia_void.sh
```

Для автоматического удаления без интерактивных запросов:
```bash
./uninstall_amnezia_void.sh -y
```
