#!/bin/bash
set -euo pipefail

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

check_dependencies() {
    echo -e "${ORANGE}[1/9] Обновление системы...${NC}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -yq
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -yq

    echo -e "${ORANGE}[2/9] Установка базовых зависимостей...${NC}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq \
        git curl build-essential libssl-dev pkg-config tar
}

install_go() {
    echo -e "${ORANGE}[3/9] Установка Go 1.23.1...${NC}"
    sudo rm -rf /usr/local/go
    local GO_VERSION="1.23.1"
    curl -OL https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz
    sudo tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz
    rm go${GO_VERSION}.linux-amd64.tar.gz
    echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go_custom.sh
    source /etc/profile.d/go_custom.sh
}

install_rust() {
    echo -e "${ORANGE}[4/9] Установка Rust...${NC}"
    sudo apt-get remove -yq rustc cargo 2>/dev/null || true
    rm -rf ~/.cargo ~/.rustup
    export RUSTUP_INIT_SKIP_PATH_CHECK=yes
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
    rustup install 1.81.0
    rustup default 1.81.0
}

install_risc0() {
    echo -e "${ORANGE}[5/9] Установка Risc0...${NC}"
    curl -L https://risczero.com/install | bash
    source "$HOME/.cargo/env"
    export PATH="$HOME/.risc0/bin:$PATH"
    rzup install --force
}

setup_project() {
    echo -e "${ORANGE}[6/9] Клонирование репозитория...${NC}"
    [ ! -d "$NODE_DIR" ] && git clone https://github.com/Layer-Edge/light-node.git
    cd "$NODE_DIR" || exit 1

    echo -e "${ORANGE}[7/9] Настройка окружения...${NC}"
    read -p "${ORANGE}Введите приватный ключ кошелька: ${NC}" PRIVATE_KEY
    sed -i "s|PRIVATE_KEY='.*'|PRIVATE_KEY='$PRIVATE_KEY'|" .env
}

build_services() {
    echo -e "${ORANGE}[8/9] Сборка сервисов...${NC}"
    
    # Обновление Go модулей
    ( cd "$INSTALL_DIR/$NODE_DIR" && go mod tidy -v )

    # Сборка Merkle
    ( cd "$MERKLE_DIR" && cargo build --release )

    # Сборка Node
    ( cd "$INSTALL_DIR/$NODE_DIR" && go build -v -o layeredge-node )
}

setup_systemd() {
    echo -e "${ORANGE}[9/9] Настройка systemd...${NC}"
    
    # Merkle Service
    sudo tee /etc/systemd/system/merkle.service >/dev/null <<EOL
[Unit]
Description=LayerEdge Merkle Service
After=network.target

[Service]
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR/$NODE_DIR/$MERKLE_DIR
ExecStart=$(which cargo) run --release
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOL

    # Node Service
    sudo tee /etc/systemd/system/layeredge-node.service >/dev/null <<EOL
[Unit]
Description=LayerEdge Light Node
After=merkle.service

[Service]
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR/$NODE_DIR
ExecStart=$INSTALL_DIR/$NODE_DIR/layeredge-node
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    sudo systemctl enable merkle.service layeredge-node.service
    sudo systemctl restart merkle.service layeredge-node.service
    sleep 5
    systemctl status merkle.service layeredge-node.service --no-pager
}

show_menu() {
    echo -e "${ORANGE}1. Установить ноду"
    echo -e "2. Показать статус"
    echo -e "3. Показать логи"
    echo -e "4. Перезапустить сервисы"
    echo -e "5. Удалить ноду"
    echo -e "6. Выход${NC}"
}

main() {
    while true; do
        show_logo
        show_menu
        read -p "Выберите действие: " choice

        case $choice in
            1)
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
            5)
                sudo systemctl stop merkle.service layeredge-node.service
                sudo systemctl disable merkle.service layeredge-node.service
                sudo rm -f /etc/systemd/system/{merkle,layeredge-node}.service
                sudo rm -rf "$INSTALL_DIR/$NODE_DIR"
                ;;
            6) exit 0 ;;
            *) echo -e "${RED}Неверный выбор!${NC}" ;;
        esac

        read -p $'\nНажмите Enter чтобы продолжить...'
    done
}

main
