#!/bin/bash
set -e

LOGO_URL="https://raw.githubusercontent.com/ProNodeRunner/Logo/main/Logo"
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
NODE_DIR="light-node"
MERKLE_DIR="risc0-merkle-service"
INSTALL_DIR=$(pwd)

show_logo() {
    clear
    echo -e "${ORANGE}"
    curl -sSf "$LOGO_URL" 2>/dev/null || echo "=== LAYEREDGE NODE MANAGER ==="
    echo -e "${NC}"
    echo -e "${ORANGE}====================== LayerEdge Node ======================${NC}\n"
}

show_menu() {
    echo -e "${ORANGE}1. Установить ноду"
    echo -e "2. Показать статус"
    echo -e "3. Показать логи"
    echo -e "4. Перезапустить сервисы"
    echo -e "5. Удалить ноду"
    echo -e "6. Выход${NC}"
}

install_dependencies() {
    echo -e "${ORANGE}[1/8] Обновление системы...${NC}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -yq
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -yq

    echo -e "${ORANGE}[2/8] Установка базовых зависимостей...${NC}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq \
        git curl build-essential libssl-dev pkg-config
}

install_go() {
    echo -e "${ORANGE}[3/8] Установка Go 1.23...${NC}"
    
    # Удаление старых версий
    sudo rm -rf /usr/local/go
    sudo rm -rf /usr/lib/go-*

    # Скачивание и установка нужной версии
    GO_VERSION="1.23.1"
    ARCH="linux-amd64"
    curl -OL https://go.dev/dl/go${GO_VERSION}.${ARCH}.tar.gz
    sudo tar -C /usr/local -xzf go${GO_VERSION}.${ARCH}.tar.gz
    rm go${GO_VERSION}.${ARCH}.tar.gz

    # Настройка PATH
    echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go_custom.sh
    source /etc/profile.d/go_custom.sh

    # Исправление go.mod
    sed -i 's/^go 1\.23\.[0-9]*/go 1.23/' $NODE_DIR/go.mod

    # Проверка установки
    if ! go version | grep -q "go$GO_VERSION"; then
        echo -e "${RED}Ошибка установки Go!${NC}"
        exit 1
    fi
}

install_rust() {
    echo -e "${ORANGE}[4/8] Установка Rust...${NC}"
    
    # Принудительное удаление системных версий Rust
    sudo apt-get remove -yq rustc cargo 2>/dev/null || true
    rm -rf ~/.cargo ~/.rustup

    # Установка через rustup с игнорированием существующих путей
    export RUSTUP_INIT_SKIP_PATH_CHECK=yes
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

    # Обновление окружения
    source "$HOME/.cargo/env"
    export PATH="$HOME/.cargo/bin:$PATH"

    # Установка конкретной версии
    rustup install 1.81.0
    rustup default 1.81.0

    # Проверка установки
    if ! cargo --version | grep -q "1.81.0"; then
        echo -e "${RED}Ошибка: Не удалось установить Rust 1.81.0!${NC}"
        exit 1
    fi
}

install_risc0() {
    echo -e "${ORANGE}[5/8] Установка Risc0...${NC}"
    curl -L https://risczero.com/install | bash
    source "$HOME/.cargo/env"
    export PATH="$HOME/.risc0/bin:$PATH"
    rzup install --force
}

clone_repo() {
    echo -e "${ORANGE}[6/8] Клонирование репозитория...${NC}"
    [ ! -d "$NODE_DIR" ] && git clone https://github.com/Layer-Edge/light-node.git
    cd "$NODE_DIR" || exit 1
}

setup_env() {
    echo -e "${ORANGE}[7/8] Настройка окружения...${NC}"
    read -p "${ORANGE}Введите приватный ключ кошелька: ${NC}" PRIVATE_KEY
    cat > .env <<EOL
GRPC_URL=34.31.74.109:9090
CONTRACT_ADDR=cosmos1ufs3tlq4umljk0qfe8k5ya0x6hpavn897u2cnf9k0en9jr7qarqqt56709
ZK_PROVER_URL=http://127.0.0.1:3001
API_REQUEST_TIMEOUT=100
POINTS_API=http://127.0.0.1:8080
PRIVATE_KEY='$PRIVATE_KEY'
EOL
}

build_services() {
    echo -e "${ORANGE}[8/8] Сборка сервисов...${NC}"
    cd "$MERKLE_DIR" && cargo build --release
    cd .. && go build -o layeredge-node
}

setup_systemd() {
    echo -e "${ORANGE}Настройка systemd сервисов...${NC}"
    sudo tee /etc/systemd/system/merkle.service >/dev/null <<EOL
[Unit]
Description=LayerEdge Merkle Service
After=network.target

[Service]
User=$(whoami)
WorkingDirectory=$INSTALL_DIR/$NODE_DIR/$MERKLE_DIR
ExecStart=$(which cargo) run --release
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOL

    sudo tee /etc/systemd/system/layeredge-node.service >/dev/null <<EOL
[Unit]
Description=LayerEdge Light Node
After=merkle.service

[Service]
User=$(whoami)
WorkingDirectory=$INSTALL_DIR/$NODE_DIR
ExecStart=$INSTALL_DIR/$NODE_DIR/layeredge-node
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    sudo systemctl enable merkle.service layeredge-node.service
    sudo systemctl start merkle.service layeredge-node.service
}

show_status() {
    echo -e "\n${ORANGE}=== Статус сервисов ===${NC}"
    systemctl status merkle.service layeredge-node.service --no-pager
}

show_logs() {
    echo -e "\n${ORANGE}=== Логи Merkle ===${NC}"
    journalctl -u merkle.service -n 10 --no-pager
    
    echo -e "\n${ORANGE}=== Логи Node ===${NC}"
    journalctl -u layeredge-node.service -n 10 --no-pager
}

delete_node() {
    echo -e "${RED}Удаление ноды...${NC}"
    sudo systemctl stop merkle.service layeredge-node.service
    sudo systemctl disable merkle.service layeredge-node.service
    sudo rm -f /etc/systemd/system/{merkle,layeredge-node}.service
    sudo rm -rf "$INSTALL_DIR/$NODE_DIR"
    echo -e "${GREEN}Нода успешно удалена!${NC}"
}

install_node() {
    install_dependencies
    install_go
    install_rust
    install_risc0
    clone_repo
    setup_env
    build_services
    setup_systemd
}

main() {
    while true; do
        show_logo
        show_menu
        read -p "Выберите действие: " choice

        case $choice in
            1) install_node ;;
            2) show_status ;;
            3) show_logs ;;
            4) sudo systemctl restart merkle.service layeredge-node.service ;;
            5) delete_node ;;
            6) exit 0 ;;
            *) echo -e "${RED}Неверный выбор!${NC}" ;;
        esac

        read -p $'\nНажмите Enter чтобы продолжить...'
    done
}

main
