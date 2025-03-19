#!/bin/bash
set -euo pipefail

# Конфигурация
LOGO_URL="https://raw.githubusercontent.com/ProNodeRunner/Logo/main/Logo"
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
NODE_DIR="light-node"
MERKLE_DIR="risc0-merkle-service"
INSTALL_DIR=$(pwd)
SERVICE_USER=$(whoami)

show_logo() {
    clear
    echo -e "${ORANGE}"
    curl -sSf "$LOGO_URL" 2>/dev/null || echo "=== LAYEREDGE NODE MANAGER ==="
    echo -e "${NC}"
    echo -e "${ORANGE}====================== LayerEdge Node ======================${NC}\n"
}

check_disk_space() {
    echo -e "${ORANGE}[1/10] Проверка свободного места...${NC}"
    local required=1000 # Минимум 1GB
    local available=$(df -m . | awk 'NR==2 {print $4}')
    
    if [ "$available" -lt "$required" ]; then
        echo -e "${RED}ОШИБКА: Недостаточно места! Нужно: ${required}MB, есть: ${available}MB${NC}"
        exit 1
    fi
}

check_dependencies() {
    echo -e "${ORANGE}[2/10] Обновление системы...${NC}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -yq
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -yq

    echo -e "${ORANGE}[3/10] Установка базовых пакетов...${NC}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq \
        git curl build-essential libssl-dev pkg-config tar

    echo -e "${ORANGE}[4/10] Очистка пакетов...${NC}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -yq
}

install_go() {
    echo -e "${ORANGE}[5/10] Установка Go 1.23.1...${NC}"
    local TEMP_DIR=$(mktemp -d)
    chmod 777 "$TEMP_DIR"
    cd "$TEMP_DIR" || exit 1

    # Удаление старых версий
    sudo rm -rf /usr/local/go /usr/lib/go-*

    # Скачивание
    GO_VERSION="1.23.1"
    ARCH="linux-amd64"
    if ! curl -OL --fail "https://go.dev/dl/go${GO_VERSION}.${ARCH}.tar.gz"; then
        echo -e "${RED}ОШИБКА: Не удалось скачать Go!${NC}"
        exit 1
    fi

    # Установка
    sudo tar -C /usr/local -xzf "go${GO_VERSION}.${ARCH}.tar.gz" || {
        echo -e "${RED}ОШИБКА: Не удалось распаковать Go!${NC}"
        exit 1
    }

    # Настройка окружения
    echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go_custom.sh
    source /etc/profile.d/go_custom.sh

    # Проверка
    if ! go version | grep -q "go$GO_VERSION"; then
        echo -e "${RED}ОШИБКА: Неправильная версия Go!${NC}"
        exit 1
    fi

    # Очистка
    rm -f "go${GO_VERSION}.${ARCH}.tar.gz"
    cd - >/dev/null || exit 1
}

install_rust() {
    echo -e "${ORANGE}[6/10] Установка Rust...${NC}"
    sudo apt-get remove -yq rustc cargo 2>/dev/null || true
    rm -rf ~/.cargo ~/.rustup

    export RUSTUP_INIT_SKIP_PATH_CHECK=yes
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"

    # Установка версии
    rustup install 1.81.0
    rustup default 1.81.0

    # Проверка
    if ! cargo --version | grep -q "1.81.0"; then
        echo -e "${RED}ОШИБКА: Неправильная версия Rust!${NC}"
        exit 1
    fi
}

install_risc0() {
    echo -e "${ORANGE}[7/10] Установка Risc0...${NC}"
    curl -L https://risczero.com/install | bash
    source "$HOME/.cargo/env"
    export PATH="$HOME/.risc0/bin:$PATH"
    rzup install --force

    if ! rzup --version; then
        echo -e "${RED}ОШИБКА: Не удалось установить Risc0!${NC}"
        exit 1
    fi
}

setup_project() {
    echo -e "${ORANGE}[8/10] Настройка проекта...${NC}"
    
    # Клонирование репозитория с проверкой
    if [ ! -d "$NODE_DIR" ]; then
        git clone https://github.com/Layer-Edge/light-node.git || {
            echo -e "${RED}Ошибка клонирования репозитория!${NC}"
            exit 1
        }
    fi

    cd "$NODE_DIR" || exit 1

    # Ввод приватного ключа с валидацией
    while :; do
        read -p "${ORANGE}Введите приватный ключ кошелька (формат 0x...): ${NC}" PRIVATE_KEY
        if [[ "$PRIVATE_KEY" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
            break
        else
            echo -e "${RED}Неверный формат ключа! Должно быть 64 hex-символа после 0x${NC}"
        fi
    done

    # Создание .env файла без кавычек
    cat > .env <<EOL
GRPC_URL=34.31.74.109:9090
CONTRACT_ADDR=cosmos1ufs3tlq4umljk0qfe8k5ya0x6hpavn897u2cnf9k0en9jr7qarqqt56709
ZK_PROVER_URL=http://127.0.0.1:3001
API_REQUEST_TIMEOUT=100
POINTS_API=http://127.0.0.1:8080
PRIVATE_KEY=$PRIVATE_KEY
EOL

    # Установка строгих прав
    chmod 600 .env
    chown "${SERVICE_USER}:${SERVICE_USER}" .env || {
        echo -e "${RED}Ошибка установки прав на .env файл!${NC}"
        exit 1
    }
}

build_services() {
    echo -e "${ORANGE}[9/10] Сборка сервисов...${NC}"
    
    # Обновление Go модулей
    echo -e "${ORANGE}Обновление зависимостей Go...${NC}"
    if ! (cd "$INSTALL_DIR/$NODE_DIR" && go mod tidy -v); then
        echo -e "${RED}Ошибка обновления Go модулей!${NC}"
        exit 1
    fi

    # Сборка Merkle-сервиса
    echo -e "${ORANGE}Компиляция Merkle-сервиса...${NC}"
    if ! (cd "$MERKLE_DIR" && cargo build --release); then
        echo -e "${RED}Ошибка сборки Merkle-сервиса!${NC}"
        exit 1
    fi

    # Сборка ноды
    echo -e "${ORANGE}Компиляция Light Node...${NC}"
    if ! (cd "$INSTALL_DIR/$NODE_DIR" && go build -v -o layeredge-node); then
        echo -e "${RED}Ошибка сборки Light Node!${NC}"
        exit 1
    fi
}

setup_systemd() {
    echo -e "${ORANGE}[10/10] Настройка сервисов...${NC}"
    
    # Конфигурация Merkle Service
    echo -e "${ORANGE}Создание сервиса Merkle...${NC}"
    sudo tee /etc/systemd/system/merkle.service >/dev/null <<EOL
[Unit]
Description=LayerEdge Merkle Service
After=network.target

[Service]
Type=exec
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR/$NODE_DIR/$MERKLE_DIR
ExecStart=$(which cargo) run --release
Restart=on-failure
RestartSec=10s
Environment="RUST_LOG=info"

[Install]
WantedBy=multi-user.target
EOL

    # Конфигурация Node Service
    echo -e "${ORANGE}Создание сервиса Light Node...${NC}"
    sudo tee /etc/systemd/system/layeredge-node.service >/dev/null <<EOL
[Unit]
Description=LayerEdge Light Node
Requires=merkle.service
After=merkle.service

[Service]
Type=exec
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR/$NODE_DIR
ExecStart=$INSTALL_DIR/$NODE_DIR/layeredge-node
EnvironmentFile=$INSTALL_DIR/$NODE_DIR/.env
Restart=on-failure
RestartSec=30s
TimeoutStartSec=600

# Логирование
StandardOutput=journal
StandardError=journal
SyslogIdentifier=layeredge-node

[Install]
WantedBy=multi-user.target
EOL

    # Применение изменений
    sudo systemctl daemon-reload

    # Запуск сервисов с проверками
    echo -e "${ORANGE}Запуск Merkle-сервиса...${NC}"
    sudo systemctl enable --now merkle.service || {
        echo -e "${RED}Ошибка запуска Merkle-сервиса!${NC}"
        journalctl -u merkle.service -n 50 --no-pager
        exit 1
    }

    echo -e "${ORANGE}Проверка доступности Merkle-сервиса...${NC}"
    local max_retries=10
    for ((i=1; i<=max_retries; i++)); do
        if curl -sSf http://127.0.0.1:3001 >/dev/null; then
            echo -e "${GREEN}Merkle-сервис доступен!${NC}"
            break
        else
            echo -e "${ORANGE}Попытка $i/$max_retries: Сервис не отвечает...${NC}"
            sleep 15
        fi
        if [ $i -eq $max_retries ]; then
            echo -e "${RED}Merkle-сервис не запустился!${NC}"
            journalctl -u merkle.service -n 100 --no-pager
            exit 1
        fi
    done

    echo -e "${ORANGE}Запуск Light Node...${NC}"
    sudo systemctl enable --now layeredge-node.service || {
        echo -e "${RED}Ошибка запуска Light Node!${NC}"
        journalctl -u layeredge-node.service -n 50 --no-pager
        exit 1
    }

    # Финальная проверка
    echo -e "${ORANGE}Проверка статуса ноды...${NC}"
    if systemctl is-active --quiet layeredge-node.service; then
        echo -e "${GREEN}Нода успешно запущена!${NC}"
        echo -e "${ORANGE}Для просмотра логов используйте: journalctl -u layeredge-node.service -f${NC}"
    else
        echo -e "${RED}Нода не запустилась! Последние логи:${NC}"
        journalctl -u layeredge-node.service -n 50 --no-pager
        exit 1
    fi
}

show_menu() {
    echo -e "${ORANGE}1. Установить ноду"
    echo -e "2. Показать статус"
    echo -e "3. Показать логи"
    echo -e "4. Перезапустить сервисы"
    echo -e "5. Удалить ноду"
    echo -e "6. Выход${NC}"
}

delete_node() {
    echo -e "${RED}Удаление ноды...${NC}"
    sudo systemctl stop merkle.service layeredge-node.service
    sudo systemctl disable merkle.service layeredge-node.service
    sudo rm -f /etc/systemd/system/{merkle,layeredge-node}.service
    sudo rm -rf "$INSTALL_DIR/$NODE_DIR"
    echo -e "${GREEN}Нода успешно удалена!${NC}"
}

main() {
    while true; do
        show_logo
        show_menu
        read -p "Выберите действие: " choice

        case $choice in
            1)
                check_disk_space
                check_dependencies
                install_go
                install_rust
                install_risc0
                setup_project
                build_services
                setup_systemd
                ;;
            2) systemctl status merkle.service layeredge-node.service --no-pager ;;
            3)
                journalctl -u merkle.service -n 20 --no-pager
                journalctl -u layeredge-node.service -n 20 --no-pager
                ;;
            4) sudo systemctl restart merkle.service layeredge-node.service ;;
            5) delete_node ;;
            6) exit 0 ;;
            *) echo -e "${RED}Неверный выбор!${NC}" ;;
        esac

        read -p $'\nНажмите Enter чтобы продолжить...'
    done
}

main
