#!/bin/bash
set -euxo pipefail

LOGO_URL="https://raw.githubusercontent.com/ProNodeRunner/Logo/main/Logo"
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
NODE_DIR="light-node"
MERKLE_DIR="risc0-merkle-service"
INSTALL_DIR=$(pwd)

show_logo() {
    echo -e "${ORANGE}"
    curl -sSf "$LOGO_URL" 2>/dev/null || echo "=== LAYEREDGE NODE MANAGER ==="
    echo -e "${NC}"
    echo -e "${ORANGE}====================== LayerEdge Node ======================${NC}\n"
}

step1_check_deps() {
    echo -e "${ORANGE}[1/9] Обновление системы...${NC}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -yq
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -yq

    echo -e "${ORANGE}[2/9] Установка базовых зависимостей...${NC}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq \
        git curl build-essential libssl-dev pkg-config
}

step2_install_go() {
    echo -e "${ORANGE}[3/9] Установка Go 1.18...${NC}"
    sudo add-apt-repository -y ppa:longsleep/golang-backports
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq golang-1.18
    echo 'export PATH=$PATH:/usr/lib/go-1.18/bin' | sudo tee /etc/profile.d/go.sh
    source /etc/profile.d/go.sh
    go version || { echo -e "${RED}Ошибка установки Go!${NC}"; exit 1; }
}

step3_install_rust() {
    echo -e "${ORANGE}[4/9] Установка Rust...${NC}"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
    rustup default 1.81.0 -y
    cargo --version || { echo -e "${RED}Ошибка установки Rust!${NC}"; exit 1; }
}

step4_install_risc0() {
    echo -e "${ORANGE}[5/9] Установка Risc0...${NC}"
    curl -L https://risczero.com/install | bash
    source "$HOME/.cargo/env"
    export PATH="$HOME/.risc0/bin:$PATH"
    rzup install --force
    rzup --version || { echo -e "${RED}Ошибка установки Risc0!${NC}"; exit 1; }
}

step5_clone_repo() {
    echo -e "${ORANGE}[6/9] Клонирование репозитория...${NC}"
    [ ! -d "$NODE_DIR" ] && git clone https://github.com/Layer-Edge/light-node.git
    cd "$NODE_DIR" || exit 1
}

step6_setup_env() {
    echo -e "${ORANGE}[7/9] Настройка окружения...${NC}"
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

step7_build_merkle() {
    echo -e "${ORANGE}[8/9] Сборка Merkle-сервиса...${NC}"
    cd "$MERKLE_DIR" || exit 1
    cargo build --release || { echo -e "${RED}Ошибка сборки Merkle!${NC}"; exit 1; }
}

step8_build_node() {
    echo -e "${ORANGE}[9/9] Сборка Light Node...${NC}"
    cd ..
    go build -o layeredge-node || { echo -e "${RED}Ошибка сборки Node!${NC}"; exit 1; }
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

main() {
    show_logo
    step1_check_deps
    step2_install_go
    step3_install_rust
    step4_install_risc0
    step5_clone_repo
    step6_setup_env
    step7_build_merkle
    step8_build_node
    setup_systemd
    
    echo -e "\n${GREEN}[✓] Установка завершена!${NC}"
    echo -e "Проверьте статус: systemctl status merkle.service layeredge-node.service"
}

main
