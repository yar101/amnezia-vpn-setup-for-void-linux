#!/usr/bin/env bash
# ==============================================================================
# Скрипт удаления AmneziaVPN и DNS-моста с Void Linux
# ==============================================================================
set -euo pipefail

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
fi

echo -e "${YELLOW}[1/4] Остановка и отключение служб runit...${NC}"
sudo rm -f /var/service/AmneziaVPN /var/service/amnezia-dns-bridge 2>/dev/null || true
sudo sv down AmneziaVPN amnezia-dns-bridge 2>/dev/null || true
sudo rm -rf /etc/sv/AmneziaVPN /etc/sv/amnezia-dns-bridge 2>/dev/null || true

echo -e "${YELLOW}[2/4] Сброс сетевых настроек и DNS...${NC}"
if command -v resolvconf >/dev/null 2>&1; then
    sudo resolvconf -d amnezia-vpn 2>/dev/null || true
    sudo resolvconf -u 2>/dev/null || true
fi

echo -e "${YELLOW}[3/4] Удаление файлов приложения, симлинков и D-Bus конфигурации...${NC}"
sudo rm -rf /opt/AmneziaVPN
sudo rm -f /usr/local/bin/AmneziaVPN /usr/local/bin/AmneziaVPN-service /usr/local/bin/amnezia-dns-bridge
sudo rm -f /usr/bin/AmneziaVPN 2>/dev/null || true
sudo rm -f /usr/share/applications/AmneziaVPN.desktop
sudo rm -f /usr/share/pixmaps/AmneziaVPN.png
sudo rm -f /etc/dbus-1/system.d/org.freedesktop.resolve1.conf

# Перезагружаем D-Bus
sudo pkill -HUP -x dbus-daemon 2>/dev/null || true

echo -e "${YELLOW}[4/4] Очистка директорий логов (по желанию)...${NC}"
read -rp "Удалить логи из /var/log/AmneziaVPN и /var/log/amnezia-dns-bridge? (y/N): " choice
if [[ "$choice" =~ ^[Yy]$ ]]; then
    sudo rm -rf /var/log/AmneziaVPN /var/log/amnezia-dns-bridge
    echo "Логи удалены."
fi

echo -e "\n${GREEN}${BOLD}[OK] AmneziaVPN и сопутствующие компоненты успешно удалены из системы.${NC}\n"
