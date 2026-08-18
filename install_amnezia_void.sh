#!/usr/bin/env bash
# ==============================================================================
# Скрипт установки AmneziaVPN на Void Linux (glibc x86_64) с DNS-мостом и runit
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
# 1. Проверка окружения и архитектуры
# ------------------------------------------------------------------------------
ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" ]]; then
    echo -e "${RED}[ОШИБКА] Официальный клиент AmneziaVPN поддерживает только архитектуру x86_64. Обнаружено: ${ARCH}${NC}"
    exit 1
fi

if ! command -v xbps-install >/dev/null 2>&1; then
    echo -e "${RED}[ОШИБКА] Пакетный менеджер xbps-install не найден. Данный скрипт предназначен для Void Linux.${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. Аутентификация sudo и фоновый keep-alive
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[1/7] Проверка прав суперпользователя (sudo)...${NC}"

if [[ $EUID -ne 0 ]]; then
    if ! sudo -v; then
        echo -e "\n${RED}[ОШИБКА] Неверный пароль sudo или недостаточно прав. Установка прервана.${NC}"
        exit 1
    fi

    # Поддерживаем sudo сессию активной в фоновом режиме во время выполнения скрипта
    ( while true; do sudo -v; sleep 50; done; ) 2>/dev/null &
    SUDO_KEEP_ALIVE_PID=$!
else
    SUDO_KEEP_ALIVE_PID=""
fi

TMP_DIR=$(mktemp -d -t amnezia-install-XXXXXX)

cleanup() {
    rm -rf "$TMP_DIR"
    if [[ -n "${SUDO_KEEP_ALIVE_PID:-}" ]]; then
        kill "$SUDO_KEEP_ALIVE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

echo -e "${GREEN}[OK] Права суперпользователя подтверждены.${NC}\n"

# ------------------------------------------------------------------------------
# 3. Переменные и пути
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:-${AMNEZIA_VERSION:-5.0.0.5}}"
INSTALL_DIR="/opt/AmneziaVPN"
RUN_INSTALLER="AmneziaVPN_${VERSION}_linux_x64.run"
DOWNLOAD_URL="https://github.com/amnezia-vpn/amnezia-client/releases/download/${VERSION}/${RUN_INSTALLER}"

# ------------------------------------------------------------------------------
# 4. Установка системных зависимостей через xbps
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[2/7] Установка необходимых системных зависимостей через xbps...${NC}"

DEPENDENCIES=(
    curl
    procps-ng
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

# Проверка статуса D-Bus в runit
if [[ ! -e /var/service/dbus ]]; then
    echo -e "${YELLOW}[ВНИМАНИЕ] Служба dbus не включена в /var/service/. Активируем...${NC}"
    if [[ -d /etc/sv/dbus ]]; then
        sudo ln -sf /etc/sv/dbus /var/service/
        sleep 1
    fi
fi

echo -e "${GREEN}[OK] Системные пакеты установлены и D-Bus проверен.${NC}\n"

# ------------------------------------------------------------------------------
# 5. Поиск / Загрузка и запуск инсталлятора .run
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

# Проверяем успешность установки
AMN_BIN="$INSTALL_DIR/AmneziaVPN"
AMN_SVC_BIN="$INSTALL_DIR/AmneziaVPN-service"

if [[ -f "$INSTALL_DIR/bin/AmneziaVPN" ]]; then
    AMN_BIN="$INSTALL_DIR/bin/AmneziaVPN"
fi
if [[ -f "$INSTALL_DIR/bin/AmneziaVPN-service" ]]; then
    AMN_SVC_BIN="$INSTALL_DIR/bin/AmneziaVPN-service"
fi

# Организуем структуру bin директории при необходимости
sudo mkdir -p "$INSTALL_DIR/bin"
if [[ -f "$INSTALL_DIR/AmneziaVPN" && ! -f "$INSTALL_DIR/bin/AmneziaVPN" ]]; then
    sudo cp -a "$INSTALL_DIR/AmneziaVPN" "$INSTALL_DIR/bin/"
    AMN_BIN="$INSTALL_DIR/bin/AmneziaVPN"
fi
if [[ -f "$INSTALL_DIR/AmneziaVPN-service" && ! -f "$INSTALL_DIR/bin/AmneziaVPN-service" ]]; then
    sudo cp -a "$INSTALL_DIR/AmneziaVPN-service" "$INSTALL_DIR/bin/"
    AMN_SVC_BIN="$INSTALL_DIR/bin/AmneziaVPN-service"
fi

if [[ ! -f "$AMN_BIN" || ! -f "$AMN_SVC_BIN" ]]; then
    echo -e "${RED}[ОШИБКА] Бинарные файлы AmneziaVPN не найдены в $INSTALL_DIR после установки!${NC}"
    exit 1
fi

sudo chmod -R 755 "$INSTALL_DIR"
sudo chmod 755 "$INSTALL_DIR/bin/"* 2>/dev/null || true

echo -e "${GREEN}[OK] AmneziaVPN успешно установлен в $INSTALL_DIR.${NC}\n"

# ------------------------------------------------------------------------------
# 6. Установка D-Bus DNS-моста (amnezia-dns-bridge) и конфигурации D-Bus
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[4/7] Установка D-Bus DNS-моста и настройка D-Bus политики...${NC}"

# Копируем python-скрипт DNS-моста
sudo cp "$SCRIPT_DIR/src/amnezia-dns-bridge.py" "$INSTALL_DIR/bin/amnezia-dns-bridge"
sudo chmod 755 "$INSTALL_DIR/bin/amnezia-dns-bridge"

# Устанавливаем D-Bus политику безопасности
sudo mkdir -p /etc/dbus-1/system.d
sudo cp "$SCRIPT_DIR/conf/org.freedesktop.resolve1.conf" /etc/dbus-1/system.d/org.freedesktop.resolve1.conf
sudo chmod 644 /etc/dbus-1/system.d/org.freedesktop.resolve1.conf

# Перезагружаем конфигурацию системной шины D-Bus
sudo pkill -HUP -x dbus-daemon 2>/dev/null || true

echo -e "${GREEN}[OK] DNS-мост установлен и D-Bus сконфигурирован.${NC}\n"

# ------------------------------------------------------------------------------
# 7. Интеграция с системой (ярлыки, иконки, симлинки)
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[5/7] Интеграция с системой (ярлыки, симлинки, иконка)...${NC}"

# Симлинки в /usr/local/bin
sudo ln -sf "$AMN_BIN" /usr/local/bin/AmneziaVPN
sudo ln -sf "$AMN_SVC_BIN" /usr/local/bin/AmneziaVPN-service
sudo ln -sf "$INSTALL_DIR/bin/amnezia-dns-bridge" /usr/local/bin/amnezia-dns-bridge

# Установка иконки
sudo mkdir -p /usr/share/pixmaps
if [[ -f "$SCRIPT_DIR/assets/AmneziaVPN.png" ]]; then
    sudo cp "$SCRIPT_DIR/assets/AmneziaVPN.png" /usr/share/pixmaps/AmneziaVPN.png
elif [[ -f "$INSTALL_DIR/AmneziaVPN.png" ]]; then
    sudo cp "$INSTALL_DIR/AmneziaVPN.png" /usr/share/pixmaps/AmneziaVPN.png
fi
sudo chmod 644 /usr/share/pixmaps/AmneziaVPN.png 2>/dev/null || true

# Установка .desktop файла
sudo mkdir -p /usr/share/applications
sudo cp "$SCRIPT_DIR/conf/AmneziaVPN.desktop" /usr/share/applications/AmneziaVPN.desktop
sudo chmod 644 /usr/share/applications/AmneziaVPN.desktop

# Загрузка модуля ядра tun
sudo modprobe tun 2>/dev/null || true

echo -e "${GREEN}[OK] Системная интеграция завершена.${NC}\n"

# ------------------------------------------------------------------------------
# 8. Создание и активация сервисов Runit
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[6/7] Настройка сервисов runit (/etc/sv/AmneziaVPN и /etc/sv/amnezia-dns-bridge)...${NC}"

# Сервис 1: amnezia-dns-bridge
sudo mkdir -p /etc/sv/amnezia-dns-bridge/log
sudo cp "$SCRIPT_DIR/services/amnezia-dns-bridge/run" /etc/sv/amnezia-dns-bridge/run
sudo cp "$SCRIPT_DIR/services/amnezia-dns-bridge/log/run" /etc/sv/amnezia-dns-bridge/log/run
sudo chmod 755 /etc/sv/amnezia-dns-bridge/run /etc/sv/amnezia-dns-bridge/log/run
sudo mkdir -p /var/log/amnezia-dns-bridge

# Сервис 2: AmneziaVPN
sudo mkdir -p /etc/sv/AmneziaVPN/log
sudo cp "$SCRIPT_DIR/services/AmneziaVPN/run" /etc/sv/AmneziaVPN/run
sudo cp "$SCRIPT_DIR/services/AmneziaVPN/log/run" /etc/sv/AmneziaVPN/log/run
sudo chmod 755 /etc/sv/AmneziaVPN/run /etc/sv/AmneziaVPN/log/run
sudo mkdir -p /var/log/AmneziaVPN

# Активация служб в /var/service
echo -e "${YELLOW}[7/7] Автоматическая активация и запуск служб в /var/service/...${NC}"
if [[ ! -e /var/service/amnezia-dns-bridge ]]; then
    sudo ln -sf /etc/sv/amnezia-dns-bridge /var/service/
fi
if [[ ! -e /var/service/AmneziaVPN ]]; then
    sudo ln -sf /etc/sv/AmneziaVPN /var/service/
fi

echo -e "${GREEN}[OK] Сервисы runit настроены и запущены.${NC}\n"

# ------------------------------------------------------------------------------
# 9. Финал: Инструкции по использованию
# ------------------------------------------------------------------------------
echo -e "${BLUE}${BOLD}======================================================${NC}"
echo -e "${GREEN}${BOLD}       Установка AmneziaVPN успешно завершена!       ${NC}"
echo -e "${BLUE}${BOLD}======================================================${NC}\n"

echo -e "${GREEN}✓ Службы AmneziaVPN и amnezia-dns-bridge автоматически запущены.${NC}\n"

echo -e "1) ${BOLD}Проверить статус запущенных служб:${NC}"
echo -e "   ${BLUE}sudo sv status amnezia-dns-bridge AmneziaVPN${NC}\n"

echo -e "2) ${BOLD}Запустить графический интерфейс AmneziaVPN:${NC}"
echo -e "   ${BLUE}AmneziaVPN${NC}\n"

echo -e "3) ${BOLD}Управление службами:${NC}"
echo -e "   Остановить:   ${YELLOW}sudo sv down AmneziaVPN amnezia-dns-bridge${NC}"
echo -e "   Запустить:    ${YELLOW}sudo sv up AmneziaVPN amnezia-dns-bridge${NC}"
echo -e "   Логи службы:  ${YELLOW}tail -f /var/log/AmneziaVPN/current${NC}\n"
