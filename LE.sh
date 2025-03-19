#!/bin/bash

# Конфигурация
LOGO_URL="https://raw.githubusercontent.com/ProNodeRunner/Logo/main/Logo"
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
NODE_DIR="light-node"
MERKLE_DIR="risc0-merkle-service"

show_logo() {
    echo -e "${ORANGE}"
    curl -sSf $LOGO_URL 2>/dev/null || echo "=== LAYEREDGE NODE MANAGER ==="
    echo -e "${NC}"
}

show_menu() {
    clear
    show_logo
    echo -e "${ORANGE}1. Установить ноду"
    echo -e "2. Показать статус"
    echo -e "3. Показать логи"
    echo -e "4. Перезапустить сервисы"
    echo -e "5. Удалить ноду"
    echo -e "6. Выход${NC}"
}

install_dependencies() {
    echo -e "${ORANGE}[1/5] Установка зависимостей...${NC}"
    sudo apt-get update -yq
    sudo apt-get install -yq git curl build-essential
    
    echo -e "${ORANGE}[2/5] Установка Go 1.18...${NC}"
    sudo add-apt-repository -y ppa:longsleep/golang-backports
    sudo apt-get install -yq golang-1.18
    echo 'export PATH=$PATH:/usr/lib/go-1.18/bin' >> ~/.bashrc
    source ~/.bashrc

    echo -e "${ORANGE}[3/5] Установка Rust...${NC}"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
    rustup default 1.81.0

    echo -e "${ORANGE}[4/5] Установка Risc0...${NC}"
    curl -L https://risczero.com/install | bash
    source "$HOME/.cargo/env"
    rzup install
}

setup_project() {
    echo -e "${ORANGE}[5/5] Клонирование репозитория...${NC}"
    git clone https://github.com/Layer-Edge/light-node.git
    cd $NODE_DIR || exit 1

    read -p "Введите приватный ключ кошелька: " PRIVATE_KEY
    cat > .env <<EOL
GRPC_URL=34.31.74.109:9090
CONTRACT_ADDR=cosmos1ufs3tlq4umljk0qfe8k5ya0x6hpavn897u2cnf9k0en9jr7qarqqt56709
ZK_PROVER_URL=http://127.0.0.1:3001
API_REQUEST_TIMEOUT=100
POINTS_API=http://127.0.0.1:8080
PRIVATE_KEY='$PRIVATE_KEY'
EOL

    echo -e "${GREEN}Конфигурация создана!${NC}"
}

start_services() {
    echo -e "${ORANGE}Запуск сервисов...${NC}"
    
    # Merkle Service
    cd $MERKLE_DIR && cargo build --release >/dev/null 2>&1
    nohup cargo run --release > merkle.log 2>&1 &
    echo -e "${GREEN}Merkle-сервис запущен!${NC}"

    # Light Node
    cd ../ && go build -o layeredge-node >/dev/null 2>&1
    nohup ./layeredge-node > node.log 2>&1 &
    echo -e "${GREEN}Light Node запущен!${NC}"
}

node_status() {
    echo -e "\n${ORANGE}=== СТАТУС СЕРВИСОВ ===${NC}"
    pgrep -af "cargo run" | grep merkle | awk '{print $1 " Merkle: " ($2 ? "🟢" : "🔴")}'
    pgrep -af "./layeredge-node" | awk '{print $1 " Node:   " ($2 ? "🟢" : "🔴")}'
}

show_logs() {
    echo -e "\n${ORANGE}=== ЛОГИ MERCKLE ===${NC}"
    tail -n 10 $MERKLE_DIR/merkle.log
    
    echo -e "\n${ORANGE}=== ЛОГИ НОДЫ ===${NC}"
    tail -n 10 node.log
}

delete_node() {
    echo -e "${RED}Удаление ноды...${NC}"
    pkill -f "layeredge-node"
    pkill -f "cargo run"
    rm -rf $NODE_DIR
    sudo apt-get purge -yq golang-1.18 rustc
}

while true; do
    show_menu
    read -p "Выберите действие: " choice

    case $choice in
        1) 
            install_dependencies
            setup_project
            start_services
            ;;
        2) node_status ;;
        3) show_logs ;;
        4) 
            pkill -f "layeredge-node"
            pkill -f "cargo run"
            start_services
            ;;
        5) delete_node ;;
        6) exit 0 ;;
        *) echo -e "${RED}Неверный выбор!${NC}" ;;
    esac
    
    read -p $'\nНажмите Enter чтобы продолжить...'
done
