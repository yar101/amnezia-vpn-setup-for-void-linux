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
    SUDO="sudo"
else
    SUDO_KEEP_ALIVE_PID=""
    SUDO=""
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
INSTALL_DIR="/opt/AmneziaVPN"
DEFAULT_VERSION="5.0.0.5"

# Определение версии (параметр, переменная окружения или запрос latest)
REQ_VERSION="${1:-${AMNEZIA_VERSION:-}}"
if [[ -z "$REQ_VERSION" || "$REQ_VERSION" == "latest" ]]; then
    echo "Определение последней стабильной версии AmneziaVPN с GitHub..."
    LATEST_TAG=$(curl -s --connect-timeout 4 https://api.github.com/repos/amnezia-vpn/amnezia-client/releases/latest 2>/dev/null | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
    if [[ -n "$LATEST_TAG" ]]; then
        VERSION="$LATEST_TAG"
    else
        VERSION="$DEFAULT_VERSION"
    fi
else
    VERSION="$REQ_VERSION"
fi

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
$SUDO xbps-install -Sy "${DEPENDENCIES[@]}"

# Проверка статуса D-Bus в runit
if [[ ! -e /var/service/dbus ]]; then
    echo -e "${YELLOW}[ВНИМАНИЕ] Служба dbus не включена в /var/service/. Активируем...${NC}"
    if [[ -d /etc/sv/dbus ]]; then
        $SUDO ln -sf /etc/sv/dbus /var/service/
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
elif [[ -z "$REQ_VERSION" || "$REQ_VERSION" == "latest" ]]; then
    # Ищем любой подходящий локальный инсталлятор только если не была явно запрошена конкретная версия
    POSSIBLE_RUN=$(find "$SCRIPT_DIR" -maxdepth 1 -name "AmneziaVPN*linux*.run" | head -n 1)
    if [[ -n "$POSSIBLE_RUN" && -f "$POSSIBLE_RUN" ]]; then
        RUN_PATH="$POSSIBLE_RUN"
    fi
fi

if [[ -z "$RUN_PATH" || ! -f "$RUN_PATH" ]]; then
    RUN_PATH="${SCRIPT_DIR}/${RUN_INSTALLER}"
    echo "Файл инсталлятора не найден локально. Загружаем с GitHub Releases..."
    if ! curl -fL --progress-bar -o "$RUN_PATH" "$DOWNLOAD_URL"; then
        echo -e "${RED}[ОШИБКА] Не удалось скачать инсталлятор с $DOWNLOAD_URL. Проверьте версию и сетевое подключение.${NC}"
        rm -f "$RUN_PATH"
        exit 1
    fi
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
$SUDO mkdir -p "$INSTALL_DIR"

echo "Запуск установки компонентов в $INSTALL_DIR..."
$SUDO env PATH="$TMP_DIR/bin:$PATH" "$RUN_PATH" -p minimal --root "$INSTALL_DIR" --accept-licenses --default-answer --confirm-command in || true

# Проверяем успешность установки и определяем актуальные пути к бинарникам
AMN_BIN=""
AMN_SVC_BIN=""

if [[ -f "$INSTALL_DIR/bin/AmneziaVPN" ]]; then
    AMN_BIN="$INSTALL_DIR/bin/AmneziaVPN"
elif [[ -f "$INSTALL_DIR/AmneziaVPN" ]]; then
    AMN_BIN="$INSTALL_DIR/AmneziaVPN"
fi

if [[ -f "$INSTALL_DIR/bin/AmneziaVPN-service" ]]; then
    AMN_SVC_BIN="$INSTALL_DIR/bin/AmneziaVPN-service"
elif [[ -f "$INSTALL_DIR/AmneziaVPN-service" ]]; then
    AMN_SVC_BIN="$INSTALL_DIR/AmneziaVPN-service"
fi

if [[ -z "$AMN_BIN" || -z "$AMN_SVC_BIN" ]]; then
    echo -e "${RED}[ОШИБКА] Бинарные файлы AmneziaVPN не найдены в $INSTALL_DIR после установки!${NC}"
    exit 1
fi

$SUDO mkdir -p "$INSTALL_DIR/bin"
$SUDO chmod -R u+rwX,go+rX "$INSTALL_DIR"
$SUDO chmod 755 "$AMN_BIN" "$AMN_SVC_BIN" 2>/dev/null || true

echo -e "${GREEN}[OK] AmneziaVPN успешно установлен в $INSTALL_DIR.${NC}\n"

# ------------------------------------------------------------------------------
# 6. Установка D-Bus DNS-моста (amnezia-dns-bridge) и конфигурации D-Bus
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[4/7] Установка D-Bus DNS-моста и настройка D-Bus политики...${NC}"

# Копируем python-скрипт DNS-моста
$SUDO cp "$SCRIPT_DIR/src/amnezia-dns-bridge.py" "$INSTALL_DIR/bin/amnezia-dns-bridge"
$SUDO chmod 755 "$INSTALL_DIR/bin/amnezia-dns-bridge"

# Устанавливаем D-Bus политику безопасности
$SUDO mkdir -p /etc/dbus-1/system.d
$SUDO cp "$SCRIPT_DIR/conf/org.freedesktop.resolve1.conf" /etc/dbus-1/system.d/org.freedesktop.resolve1.conf
$SUDO chmod 644 /etc/dbus-1/system.d/org.freedesktop.resolve1.conf

# Перезагружаем конфигурацию системной шины D-Bus
$SUDO dbus-send --system --type=method_call --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ReloadConfig 2>/dev/null || true
$SUDO pkill -HUP -x dbus-daemon 2>/dev/null || true

echo -e "${GREEN}[OK] DNS-мост установлен и D-Bus сконфигурирован.${NC}\n"

# ------------------------------------------------------------------------------
# 7. Интеграция с системой (ярлыки, иконки, симлинки)
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[5/7] Интеграция с системой (ярлыки, симлинки, иконка)...${NC}"

# Симлинки в /usr/local/bin
$SUDO ln -sf "$AMN_BIN" /usr/local/bin/AmneziaVPN
$SUDO ln -sf "$AMN_SVC_BIN" /usr/local/bin/AmneziaVPN-service
$SUDO ln -sf "$INSTALL_DIR/bin/amnezia-dns-bridge" /usr/local/bin/amnezia-dns-bridge

# Установка иконки
$SUDO mkdir -p /usr/share/pixmaps
if [[ -f "$SCRIPT_DIR/assets/AmneziaVPN.png" ]]; then
    $SUDO cp "$SCRIPT_DIR/assets/AmneziaVPN.png" /usr/share/pixmaps/AmneziaVPN.png
elif [[ -f "$INSTALL_DIR/AmneziaVPN.png" ]]; then
    $SUDO cp "$INSTALL_DIR/AmneziaVPN.png" /usr/share/pixmaps/AmneziaVPN.png
fi
$SUDO chmod 644 /usr/share/pixmaps/AmneziaVPN.png 2>/dev/null || true

# Установка .desktop файла
$SUDO mkdir -p /usr/share/applications
$SUDO cp "$SCRIPT_DIR/conf/AmneziaVPN.desktop" /usr/share/applications/AmneziaVPN.desktop
$SUDO chmod 644 /usr/share/applications/AmneziaVPN.desktop

if command -v update-desktop-database >/dev/null 2>&1; then
    $SUDO update-desktop-database /usr/share/applications 2>/dev/null || true
fi

# Загрузка модуля ядра tun
$SUDO modprobe tun 2>/dev/null || true

echo -e "${GREEN}[OK] Системная интеграция завершена.${NC}\n"

# ------------------------------------------------------------------------------
# 8. Создание и активация сервисов Runit
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[6/7] Настройка сервисов runit (/etc/sv/AmneziaVPN и /etc/sv/amnezia-dns-bridge)...${NC}"

# Сервис 1: amnezia-dns-bridge
$SUDO mkdir -p /etc/sv/amnezia-dns-bridge/log
$SUDO cp "$SCRIPT_DIR/services/amnezia-dns-bridge/run" /etc/sv/amnezia-dns-bridge/run
$SUDO cp "$SCRIPT_DIR/services/amnezia-dns-bridge/log/run" /etc/sv/amnezia-dns-bridge/log/run
$SUDO chmod 755 /etc/sv/amnezia-dns-bridge/run /etc/sv/amnezia-dns-bridge/log/run
$SUDO mkdir -p /var/log/amnezia-dns-bridge

# Сервис 2: AmneziaVPN
$SUDO mkdir -p /etc/sv/AmneziaVPN/log
$SUDO cp "$SCRIPT_DIR/services/AmneziaVPN/run" /etc/sv/AmneziaVPN/run
$SUDO cp "$SCRIPT_DIR/services/AmneziaVPN/log/run" /etc/sv/AmneziaVPN/log/run
$SUDO chmod 755 /etc/sv/AmneziaVPN/run /etc/sv/AmneziaVPN/log/run
$SUDO mkdir -p /var/log/AmneziaVPN

# Активация служб в /var/service
echo -e "${YELLOW}[7/7] Автоматическая активация и запуск служб в /var/service/...${NC}"
if [[ ! -e /var/service/amnezia-dns-bridge ]]; then
    $SUDO ln -sf /etc/sv/amnezia-dns-bridge /var/service/
fi
if [[ ! -e /var/service/AmneziaVPN ]]; then
    $SUDO ln -sf /etc/sv/AmneziaVPN /var/service/
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
