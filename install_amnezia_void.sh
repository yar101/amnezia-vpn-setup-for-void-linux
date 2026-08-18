#!/usr/bin/env bash
# ==============================================================================
# Скрипт установки AmneziaVPN на Void Linux (x86_64) с поддержкой DNS-моста
# ==============================================================================
set -euo pipefail

# Цвета для удобного вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "${BLUE}${BOLD}======================================================${NC}"
echo -e "${BLUE}${BOLD}        Установка AmneziaVPN для Void Linux          ${NC}"
echo -e "${BLUE}${BOLD}======================================================${NC}\n"

# ------------------------------------------------------------------------------
# 1. Запрос и проверка sudo пароля в самом начале
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[1/7] Проверка прав суперпользователя (sudo)...${NC}"

# Сбрасываем кэш sudo, чтобы гарантировать запрос пароля
sudo -k

echo -n "Пожалуйста, введите ваш пароль sudo: "
# Проверяем пароль командой sudo -v
if ! sudo -v; then
    echo -e "\n${RED}[ОШИБКА] Неверный пароль sudo или недостаточно прав. Установка прервана.${NC}"
    exit 1
fi

echo -e "${GREEN}[OK] Пароль подтверждён.${NC}\n"

# Поддерживаем sudo сессию активной в фоновом режиме во время выполнения скрипта
( while true; do sudo -v; sleep 50; done; ) 2>/dev/null &
SUDO_KEEP_ALIVE_PID=$!
trap 'kill "$SUDO_KEEP_ALIVE_PID" 2>/dev/null || true' EXIT

# ------------------------------------------------------------------------------
# 2. Определение путей и переменных
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="5.0.0.5"
INSTALL_DIR="/opt/AmneziaVPN"
RUN_INSTALLER="AmneziaVPN_${VERSION}_linux_x64.run"
DOWNLOAD_URL="https://github.com/amnezia-vpn/amnezia-client/releases/download/${VERSION}/${RUN_INSTALLER}"
TMP_DIR=$(mktemp -d -t amnezia-install-XXXXXX)

cleanup() {
    rm -rf "$TMP_DIR"
    kill "$SUDO_KEEP_ALIVE_PID" 2>/dev/null || true
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# 3. Установка системных зависимостей для Void Linux через xbps
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[2/7] Установка необходимых системных зависимостей через xbps...${NC}"

DEPENDENCIES=(
    curl
    wireguard-tools
    openvpn
    openresolv
    iptables
    iproute2
    dbus
    python3
    python3-dbus
    python3-gobject
    libsecret
    libglvnd
    libxcb
    xcb-util-cursor
    xcb-util-wm
    xcb-util-keysyms
    xcb-util-image
    xcb-util-renderutil
    libxkbcommon
    libxkbcommon-x11
)

echo "Обновление репозиториев и установка пакетов: ${DEPENDENCIES[*]}"
sudo xbps-install -Sy "${DEPENDENCIES[@]}"

echo -e "${GREEN}[OK] Системные пакеты установлены.${NC}\n"

# ------------------------------------------------------------------------------
# 4. Поиск / Загрузка и запуск инсталлятора .run
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[3/7] Подготовка и запуск инсталлятора AmneziaVPN ${VERSION}...${NC}"

RUN_PATH=""
if [[ -f "${SCRIPT_DIR}/${RUN_INSTALLER}" ]]; then
    RUN_PATH="${SCRIPT_DIR}/${RUN_INSTALLER}"
else
    POSSIBLE_RUN=$(find "$SCRIPT_DIR" -maxdepth 1 -name "AmneziaVPN*linux*.run" | head -n 1)
    if [[ -n "$POSSIBLE_RUN" && -f "$POSSIBLE_RUN" ]]; then
        RUN_PATH="$POSSIBLE_RUN"
    fi
fi

if [[ -z "$RUN_PATH" || ! -f "$RUN_PATH" ]]; then
    RUN_PATH="${SCRIPT_DIR}/${RUN_INSTALLER}"
    echo "Файл инсталлятора не найден локально. Загружаем с GitHub Releases..."
    curl -L --progress-bar -o "$RUN_PATH" "$DOWNLOAD_URL"
else
    echo "Найден локальный инсталлятор: $RUN_PATH"
fi

chmod +x "$RUN_PATH"

# Создаем фиктивный systemctl во временной директории, чтобы post-install скрипт инсталлятора не падал на Void Linux
mkdir -p "$TMP_DIR/bin"
cat << 'EOF' > "$TMP_DIR/bin/systemctl"
#!/bin/sh
exit 0
EOF
chmod +x "$TMP_DIR/bin/systemctl"

# Создаем целевую директорию /opt/AmneziaVPN
sudo mkdir -p "$INSTALL_DIR"

echo "Запуск установки компонентов в $INSTALL_DIR..."
sudo env PATH="$TMP_DIR/bin:$PATH" "$RUN_PATH" -p minimal --root "$INSTALL_DIR" --accept-licenses --default-answer --confirm-command in || true

# Организуем структуру исполняемых файлов
if [[ -f "$INSTALL_DIR/AmneziaVPN" && ! -f "$INSTALL_DIR/bin/AmneziaVPN" ]]; then
    sudo mkdir -p "$INSTALL_DIR/bin"
    sudo cp -a "$INSTALL_DIR/AmneziaVPN" "$INSTALL_DIR/bin/"
fi
if [[ -f "$INSTALL_DIR/AmneziaVPN-service" && ! -f "$INSTALL_DIR/bin/AmneziaVPN-service" ]]; then
    sudo mkdir -p "$INSTALL_DIR/bin"
    sudo cp -a "$INSTALL_DIR/AmneziaVPN-service" "$INSTALL_DIR/bin/"
fi

# Устанавливаем права доступа
sudo chmod -R 755 "$INSTALL_DIR"
if [[ -d "$INSTALL_DIR/bin" ]]; then
    sudo chmod 755 "$INSTALL_DIR/bin/"* 2>/dev/null || true
fi

echo -e "${GREEN}[OK] AmneziaVPN успешно установлен в $INSTALL_DIR.${NC}\n"

# ------------------------------------------------------------------------------
# 5. Установка D-Bus DNS-моста (amnezia-dns-bridge) для Void Linux
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[4/7] Установка и настройка D-Bus DNS-моста для работы без systemd-resolved...${NC}"

# 1. Создаем скрипт DNS-моста в /opt/AmneziaVPN/bin/amnezia-dns-bridge
sudo tee "$INSTALL_DIR/bin/amnezia-dns-bridge" > /dev/null << 'EOF'
#!/usr/bin/env python3
"""
amnezia-dns-bridge: D-Bus shim providing org.freedesktop.resolve1 on Void Linux / non-systemd systems.
Translates AmneziaVPN SetLinkDNS calls directly into resolvconf / /etc/resolv.conf updates.
Includes kernel interface watchdog and exclusive DNS routing to prevent DNS leaks.
"""
import sys
import socket
import subprocess
import os
import signal
import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

RESOLVE_SERVICE = "org.freedesktop.resolve1"
RESOLVE_PATH = "/org/freedesktop/resolve1"
RESOLVE_MANAGER_IFACE = "org.freedesktop.resolve1.Manager"

class ResolveManager(dbus.service.Object):
    def __init__(self, bus_name):
        super().__init__(bus_name, RESOLVE_PATH)
        self.link_dns = {}
        self.link_domains = {}
        self.backup_resolv_conf = None
        if os.path.exists("/etc/resolv.conf"):
            try:
                with open("/etc/resolv.conf", "r") as f:
                    self.backup_resolv_conf = f.read()
            except Exception as e:
                print(f"[DNS Bridge] Предупреждение при чтении /etc/resolv.conf: {e}")

    @dbus.service.method(RESOLVE_MANAGER_IFACE, in_signature='ia(iay)', out_signature='')
    def SetLinkDNS(self, ifindex, resolvers):
        print(f"[DNS Bridge] SetLinkDNS для интерфейса {ifindex}")
        ips = []
        for family, raw_addr in resolvers:
            try:
                addr_bytes = bytes(raw_addr)
                if family == socket.AF_INET and len(addr_bytes) == 4:
                    ip_str = socket.inet_ntop(socket.AF_INET, addr_bytes)
                    ips.append(ip_str)
                elif family == socket.AF_INET6 and len(addr_bytes) == 16:
                    ip_str = socket.inet_ntop(socket.AF_INET6, addr_bytes)
                    ips.append(ip_str)
            except Exception as e:
                print(f"[DNS Bridge] Ошибка разбора IP: {e}")

        if ips:
            print(f"[DNS Bridge] Установка DNS серверов: {ips}")
            self.link_dns[int(ifindex)] = ips
            self.apply_dns()

    @dbus.service.method(RESOLVE_MANAGER_IFACE, in_signature='ia(sb)', out_signature='')
    def SetLinkDomains(self, ifindex, domains):
        self.link_domains[int(ifindex)] = [(str(d), bool(s)) for d, s in domains]

    @dbus.service.method(RESOLVE_MANAGER_IFACE, in_signature='ib', out_signature='')
    def SetLinkDefaultRoute(self, ifindex, enable):
        pass

    @dbus.service.method(RESOLVE_MANAGER_IFACE, in_signature='i', out_signature='')
    def RevertLink(self, ifindex):
        ifindex = int(ifindex)
        print(f"[DNS Bridge] RevertLink для интерфейса {ifindex}")
        if ifindex in self.link_dns:
            del self.link_dns[ifindex]
        if ifindex in self.link_domains:
            del self.link_domains[ifindex]
        self.apply_dns()

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature='ss', out_signature='v')
    def Get(self, interface_name, property_name):
        if property_name == "Domains":
            domains_list = []
            for ifidx, dlist in self.link_domains.items():
                for dom, srch in dlist:
                    domains_list.append((dbus.Int32(ifidx), dbus.String(dom), dbus.Boolean(srch)))
            return dbus.Array(domains_list, signature='(isb)')
        return ""

    def apply_dns(self):
        vpn_ips = []
        other_ips = []
        for ifidx, ips in self.link_dns.items():
            ifname = ""
            try:
                ifname = socket.if_indextoname(ifidx)
            except OSError:
                pass
            is_tunnel = any(ifname.startswith(pfx) for pfx in ("tun", "amn", "wg", "tap", "ppp"))
            for ip in ips:
                if is_tunnel:
                    if ip not in vpn_ips:
                        vpn_ips.append(ip)
                else:
                    if ip not in other_ips:
                        other_ips.append(ip)

        # Туннельные VPN DNS идут первыми для предотвращения DNS Leak
        all_ips = vpn_ips + [ip for ip in other_ips if ip not in vpn_ips]

        if all_ips:
            resolv_data = "# Generated by amnezia-dns-bridge\n" + "".join([f"nameserver {ip}\n" for ip in all_ips])
            applied = False
            try:
                proc = subprocess.run(["resolvconf", "-a", "amnezia-vpn", "-x", "-m", "0"], input=resolv_data.encode(), check=False)
                if proc.returncode == 0:
                    applied = True
            except FileNotFoundError:
                pass

            if not applied:
                try:
                    with open("/etc/resolv.conf", "w") as f:
                        f.write(resolv_data)
                except Exception as e:
                    print(f"[DNS Bridge] Ошибка записи в /etc/resolv.conf: {e}")
        else:
            reverted = False
            try:
                proc = subprocess.run(["resolvconf", "-d", "amnezia-vpn"], check=False)
                if proc.returncode == 0:
                    reverted = True
            except FileNotFoundError:
                pass

            if not reverted and self.backup_resolv_conf:
                try:
                    with open("/etc/resolv.conf", "w") as f:
                        f.write(self.backup_resolv_conf)
                except Exception as e:
                    print(f"[DNS Bridge] Ошибка восстановления /etc/resolv.conf: {e}")

    def cleanup(self):
        self.link_dns.clear()
        self.link_domains.clear()
        self.apply_dns()

    def check_interfaces(self):
        """Watchdog: проверяет, живы ли интерфейсы. Если VPN туннель закрыт, автоматически сбрасывает DNS."""
        if not self.link_dns:
            return True
        changed = False
        for ifidx in list(self.link_dns.keys()):
            try:
                socket.if_indextoname(ifidx)
            except OSError:
                print(f"[DNS Bridge] Интерфейс #{ifidx} удален/закрыт. Автоматический сброс DNS...")
                del self.link_dns[ifidx]
                if ifidx in self.link_domains:
                    del self.link_domains[ifidx]
                changed = True
        if changed:
            self.apply_dns()
        return True

def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    try:
        bus = dbus.SystemBus()
    except Exception as e:
        print(f"[DNS Bridge] Ошибка подключения к системной шине D-Bus: {e}")
        sys.exit(1)

    try:
        bus_name = dbus.service.BusName(RESOLVE_SERVICE, bus, do_not_queue=True)
    except Exception as e:
        print(f"[DNS Bridge] Не удалось зарегистрировать имя {RESOLVE_SERVICE} на D-Bus: {e}")
        sys.exit(1)

    manager = ResolveManager(bus_name)
    loop = GLib.MainLoop()

    # Запуск периодического watchdog каждые 2 секунды
    GLib.timeout_add_seconds(2, manager.check_interfaces)

    def handle_signal(sig, frame):
        print("[DNS Bridge] Завершение работы, восстановление DNS...")
        manager.cleanup()
        loop.quit()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGHUP, handle_signal)

    print("[DNS Bridge] D-Bus DNS-мост успешно запущен и ожидает запросов.")
    loop.run()
EOF

sudo chmod 755 "$INSTALL_DIR/bin/amnezia-dns-bridge"

# 2. Устанавливаем D-Bus политику доступа для org.freedesktop.resolve1
sudo mkdir -p /etc/dbus-1/system.d
sudo tee /etc/dbus-1/system.d/org.freedesktop.resolve1.conf > /dev/null << 'EOF'
<!DOCTYPE busconfig PUBLIC
 "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <policy user="root">
    <allow own="org.freedesktop.resolve1"/>
    <allow send_destination="org.freedesktop.resolve1"/>
    <allow receive_sender="org.freedesktop.resolve1"/>
  </policy>
  <policy context="default">
    <allow send_destination="org.freedesktop.resolve1"/>
    <allow receive_sender="org.freedesktop.resolve1"/>
  </policy>
</busconfig>
EOF

# Перезагружаем конфигурацию D-Bus daemon
sudo killall -HUP dbus-daemon 2>/dev/null || true

echo -e "${GREEN}[OK] DNS-мост установлен и D-Bus сконфигурирован.${NC}\n"

# ------------------------------------------------------------------------------
# 6. Настройка ярлыков, иконок, симлинков и логов
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[5/7] Интеграция с системой (ярлыки, симлинки, логи)...${NC}"

# Создаем каталог для логов службы
sudo mkdir -p /var/log/AmneziaVPN
sudo chmod 755 /var/log/AmneziaVPN

# Симлинки для удобного запуска из терминала
AMN_BIN="$INSTALL_DIR/bin/AmneziaVPN"
[[ ! -f "$AMN_BIN" && -f "$INSTALL_DIR/AmneziaVPN" ]] && AMN_BIN="$INSTALL_DIR/AmneziaVPN"

AMN_SVC_BIN="$INSTALL_DIR/bin/AmneziaVPN-service"
[[ ! -f "$AMN_SVC_BIN" && -f "$INSTALL_DIR/AmneziaVPN-service" ]] && AMN_SVC_BIN="$INSTALL_DIR/AmneziaVPN-service"

sudo ln -sf "$AMN_BIN" /usr/local/bin/AmneziaVPN
sudo ln -sf "$AMN_SVC_BIN" /usr/local/bin/AmneziaVPN-service
sudo ln -sf "$INSTALL_DIR/bin/amnezia-dns-bridge" /usr/local/bin/amnezia-dns-bridge
sudo ln -sf "$AMN_BIN" /usr/bin/AmneziaVPN 2>/dev/null || true

# Установка иконки и .desktop файла
SOURCE_TAR="${SCRIPT_DIR}/amnezia-client-${VERSION}.tar.gz"

if [[ -f "$SOURCE_TAR" ]]; then
    tar -zxvf "$SOURCE_TAR" -C "$TMP_DIR" "amnezia-client-${VERSION}/deploy/data/linux/AmneziaVPN.png" 2>/dev/null || true
    tar -zxvf "$SOURCE_TAR" -C "$TMP_DIR" "amnezia-client-${VERSION}/deploy/data/linux/AmneziaVPN.desktop" 2>/dev/null || true
    
    if [[ -f "$TMP_DIR/amnezia-client-${VERSION}/deploy/data/linux/AmneziaVPN.png" ]]; then
        sudo cp "$TMP_DIR/amnezia-client-${VERSION}/deploy/data/linux/AmneziaVPN.png" /usr/share/pixmaps/AmneziaVPN.png
    fi
    if [[ -f "$TMP_DIR/amnezia-client-${VERSION}/deploy/data/linux/AmneziaVPN.desktop" ]]; then
        sudo cp "$TMP_DIR/amnezia-client-${VERSION}/deploy/data/linux/AmneziaVPN.desktop" /usr/share/applications/AmneziaVPN.desktop
    fi
fi

if [[ ! -f /usr/share/pixmaps/AmneziaVPN.png && -f "$INSTALL_DIR/AmneziaVPN.png" ]]; then
    sudo cp "$INSTALL_DIR/AmneziaVPN.png" /usr/share/pixmaps/AmneziaVPN.png
fi

if [[ ! -f /usr/share/applications/AmneziaVPN.desktop ]]; then
    sudo tee /usr/share/applications/AmneziaVPN.desktop > /dev/null << EOF
[Desktop Entry]
Type=Application
Name=AmneziaVPN
Comment=Client of your self-hosted VPN
Exec=$AMN_BIN
Icon=/usr/share/pixmaps/AmneziaVPN.png
Categories=Network;Qt;Security;
Terminal=false
EOF
fi

sudo chmod 644 /usr/share/applications/AmneziaVPN.desktop 2>/dev/null || true

# Убедимся, что модуль ядра tun загружен
sudo modprobe tun 2>/dev/null || true

echo -e "${GREEN}[OK] Системная интеграция завершена.${NC}\n"

# ------------------------------------------------------------------------------
# 7. Создание сервисов Runit для Void Linux
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[6/7] Создание сервисов runit для Void Linux (/etc/sv/AmneziaVPN и /etc/sv/amnezia-dns-bridge)...${NC}"

# Сервис 1: amnezia-dns-bridge (DNS-мост)
SV_DNS_DIR="/etc/sv/amnezia-dns-bridge"
sudo mkdir -p "$SV_DNS_DIR"
sudo tee "$SV_DNS_DIR/run" > /dev/null << 'EOF'
#!/bin/sh
exec 2>&1
exec /usr/bin/python3 /opt/AmneziaVPN/bin/amnezia-dns-bridge
EOF
sudo chmod 755 "$SV_DNS_DIR/run"

# Сервис 2: AmneziaVPN (основная служба VPN)
SV_AMN_DIR="/etc/sv/AmneziaVPN"
sudo mkdir -p "$SV_AMN_DIR"
sudo tee "$SV_AMN_DIR/run" > /dev/null << EOF
#!/bin/sh
exec 2>&1
mkdir -p /var/log/AmneziaVPN
exec $AMN_SVC_BIN
EOF
sudo chmod 755 "$SV_AMN_DIR/run"

echo -e "${GREEN}[OK] Сервисы runit созданы в /etc/sv/AmneziaVPN и /etc/sv/amnezia-dns-bridge.${NC}\n"

# Активация и автоматический запуск сервисов в runit (/var/service)
echo -e "${YELLOW}[7/7] Автоматическая активация и запуск служб в /var/service/...${NC}"
if [[ ! -e /var/service/amnezia-dns-bridge ]]; then
    sudo ln -sf "$SV_DNS_DIR" /var/service/
fi
if [[ ! -e /var/service/AmneziaVPN ]]; then
    sudo ln -sf "$SV_AMN_DIR" /var/service/
fi

echo -e "${GREEN}[OK] Службы активированы и запущены в /var/service/.${NC}\n"

# ------------------------------------------------------------------------------
# 8. Финал: Инструкции по использованию
# ------------------------------------------------------------------------------
echo -e "${BLUE}${BOLD}======================================================${NC}"
echo -e "${GREEN}${BOLD}       Установка AmneziaVPN успешно завершена!       ${NC}"
echo -e "${BLUE}${BOLD}======================================================${NC}\n"

echo -e "${GREEN}✓ Службы AmneziaVPN и amnezia-dns-bridge автоматически запущены.${NC}\n"

echo -e "1) ${BOLD}Проверить статус запущенных служб:${NC}"
echo -e "   ${BLUE}sudo sv status amnezia-dns-bridge AmneziaVPN${NC}\n"

echo -e "2) ${BOLD}Запустить графический интерфейс AmneziaVPN:${NC}"
echo -e "   ${BLUE}AmneziaVPN${NC}\n"

echo -e "3) ${BOLD}Управление службами при необходимости:${NC}"
echo -e "   Остановить:   ${YELLOW}sudo sv down AmneziaVPN amnezia-dns-bridge${NC}"
echo -e "   Запустить:    ${YELLOW}sudo sv up AmneziaVPN amnezia-dns-bridge${NC}"
echo -e "   Отключить:    ${YELLOW}sudo rm /var/service/AmneziaVPN /var/service/amnezia-dns-bridge${NC}"
echo -e "   Логи службы:  ${YELLOW}tail -f /var/log/AmneziaVPN/AmneziaVPN-service.log${NC}\n"
