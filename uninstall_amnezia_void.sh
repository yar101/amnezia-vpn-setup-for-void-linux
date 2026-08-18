#!/usr/bin/env bash
# ==============================================================================
# Скрипт удаления AmneziaVPN и DNS-моста с Void Linux
# ==============================================================================
set -euo pipefail

# Флаг автоматического подтверждения
AUTO_CONFIRM=false
for arg in "$@"; do
    case "$arg" in
        -y|--yes)
            AUTO_CONFIRM=true
            ;;
        *)
            ;;
    esac
done

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BLUE}${BOLD}======================================================${NC}"
echo -e "${BLUE}${BOLD}        Удаление AmneziaVPN для Void Linux           ${NC}"
echo -e "${BLUE}${BOLD}======================================================${NC}\n"

# Проверка sudo прав
if [[ $EUID -ne 0 ]]; then
    if ! sudo -v; then
        echo -e "\n${RED}[ОШИБКА] Требуются права суперпользователя (sudo) для удаления.${NC}"
        exit 1
    fi
    SUDO="sudo"
else
    SUDO=""
fi

echo -e "${YELLOW}[1/4] Остановка и отключение служб runit...${NC}"
# 1. Принудительно останавливаем службы перед удалением симлинков
$SUDO sv -w 5 force-stop /var/service/AmneziaVPN 2>/dev/null || true
$SUDO sv -w 5 force-stop /var/service/amnezia-dns-bridge 2>/dev/null || true
# 2. Удаляем симлинки автозапуска
$SUDO rm -f /var/service/AmneziaVPN /var/service/amnezia-dns-bridge 2>/dev/null || true
# 3. Гарантируем завершение фоновых процессов
$SUDO pkill -x AmneziaVPN-service 2>/dev/null || true
$SUDO pkill -x AmneziaVPN 2>/dev/null || true
for pid in $(pgrep -f "^/usr/bin/python3 .*amnezia-dns-bridge" 2>/dev/null || true); do
    if [[ -n "$pid" && "$pid" != "$$" ]]; then
        $SUDO kill -TERM "$pid" 2>/dev/null || true
    fi
done
sleep 0.5
for pid in $(pgrep -f "^/usr/bin/python3 .*amnezia-dns-bridge" 2>/dev/null || true); do
    if [[ -n "$pid" && "$pid" != "$$" ]]; then
        $SUDO kill -9 "$pid" 2>/dev/null || true
    fi
done
# 4. Удаляем каталоги определений служб
$SUDO rm -rf /etc/sv/AmneziaVPN /etc/sv/amnezia-dns-bridge 2>/dev/null || true

echo -e "${YELLOW}[2/4] Сброс сетевых настроек и DNS...${NC}"
if command -v resolvconf >/dev/null 2>&1; then
    $SUDO resolvconf -f -d amnezia-vpn 2>/dev/null || true
    $SUDO resolvconf -u 2>/dev/null || true
fi

echo -e "${YELLOW}[3/4] Удаление файлов приложения, симлинков и D-Bus конфигурации...${NC}"
$SUDO rm -rf /opt/AmneziaVPN
$SUDO rm -f /usr/local/bin/AmneziaVPN /usr/local/bin/AmneziaVPN-service /usr/local/bin/amnezia-dns-bridge
$SUDO rm -f /usr/bin/AmneziaVPN 2>/dev/null || true
$SUDO rm -f /usr/share/applications/AmneziaVPN.desktop
$SUDO rm -f /usr/share/pixmaps/AmneziaVPN.png
$SUDO rm -f /etc/dbus-1/system.d/org.freedesktop.resolve1.conf

# Перезагружаем D-Bus конфигурацию
$SUDO dbus-send --system --type=method_call --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ReloadConfig 2>/dev/null || true
$SUDO pkill -HUP -x dbus-daemon 2>/dev/null || true

if command -v update-desktop-database >/dev/null 2>&1; then
    $SUDO update-desktop-database /usr/share/applications 2>/dev/null || true
fi

echo -e "${YELLOW}[4/4] Очистка директорий логов (по желанию)...${NC}"
if [[ "$AUTO_CONFIRM" == "true" ]]; then
    $SUDO rm -rf /var/log/AmneziaVPN /var/log/amnezia-dns-bridge
    echo "Логи удалены."
else
    stty sane 2>/dev/null || true
    read -rp "Удалить логи из /var/log/AmneziaVPN и /var/log/amnezia-dns-bridge? (y/N): " choice </dev/tty || choice="n"
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        $SUDO rm -rf /var/log/AmneziaVPN /var/log/amnezia-dns-bridge
        echo "Логи удалены."
    fi
fi

echo -e "\n${GREEN}${BOLD}[OK] AmneziaVPN и сопутствующие компоненты успешно удалены из системы.${NC}\n"
