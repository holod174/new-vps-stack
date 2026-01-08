#!/bin/bash

# --- Настройка цветов ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# 1. Проверка на root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Ошибка: Запустите скрипт от имени root (через sudo)${NC}"
   exit 1
fi

echo -e "${BLUE}>>> 1. Подготовка системы (Обновление и Swap)...${NC}"
apt update && apt upgrade -y
# Создание Swap 2GB для стабильности на дешевых VPS
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
fi

# 2. Установка софта
echo -e "${BLUE}>>> 2. Установка Docker и системных утилит...${NC}"
apt install -y git curl ufw fail2ban openssl
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh
fi

# 3. Настройка Firewall
echo -e "${BLUE}>>> 3. Настройка Firewall (открытие портов)...${NC}"
ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp
ufw allow 53/udp && ufw allow 53/tcp
ufw allow 81/tcp   # Панель NPM
ufw allow 3000/tcp # Установка AdGuard
ufw allow 2053/tcp # Панель 3x-ui
echo "y" | ufw enable

# 4. Структура проекта
mkdir -p ~/my-server/data/npm ~/my-server/data/3x-ui ~/my-server/data/adguard
cd ~/my-server
echo ".env" > .gitignore
echo "data/" >> .gitignore

# 5. Создание .env с выбором данных
if [ ! -f .env ]; then
    echo -e "${YELLOW}Введите ваш домен (например, site.com):${NC}"
    read MY_DOMAIN
    
    echo -e "${YELLOW}Введите вашу таймзону (например, Asia/Yekaterinburg):${NC}"
    echo -e "${BLUE}Подсказка: Москва — Europe/Moscow, Екатеринбург — Asia/Yekaterinburg${NC}"
    read MY_TZ
    
    # Если нажал Enter и не ввел TZ, поставим по умолчанию Екатеринбург
    if [ -z "$MY_TZ" ]; then MY_TZ="Asia/Yekaterinburg"; fi

    cat <<EOF > .env
MY_DOMAIN=$MY_DOMAIN
TZ=$MY_TZ
DB_PASSWORD=$(openssl rand -hex 12)
EOF
    echo -e "${GREEN}Настройки сохранены в .env${NC}"
fi

# 6. Освобождение порта 53
systemctl stop systemd-resolved && systemctl disable systemd-resolved
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf

# 7. Генерация docker-compose.yml (для автономности скрипта)
cat <<EOF > docker-compose.yml
services:
  npm:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: always
    ports: ['80:80', '81:81', '443:443']
    volumes: ['./data/npm:/data', './data/letsencrypt:/etc/letsencrypt']
  3x-ui:
    image: ghcr.io/m0neit/3x-ui:latest
    restart: always
    network_mode: host
    volumes: ['./data/3x-ui:/etc/xray-ui']
  adguard:
    image: adguard/adguardhome
    restart: always
    ports: ['53:53/tcp', '53:53/udp', '3000:3000/tcp']
    volumes: ['./data/adguard/work:/opt/adguardhome/work', './data/adguard/conf:/opt/adguardhome/conf']
EOF

# 8. Запуск
echo -e "${GREEN}>>> Запуск сервисов...${NC}"
docker compose up -d

# 9. Получение внешнего IP
IP=$(curl -s ifconfig.me)

# --- ФИНАЛЬНЫЙ ВЫВОД ---
echo -e "\n${PURPLE}================================================================${NC}"
echo -e "${GREEN}             УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!                      ${NC}"
echo -e "${PURPLE}================================================================${NC}"
echo -e "${YELLOW}1. Nginx Proxy Manager (Управление доменами и SSL)${NC}"
echo -e "   Адрес:   http://$IP:81"
echo -e "   Логин:   admin@example.com"
echo -e "   Пароль:  changeme"
echo -e "----------------------------------------------------------------"
echo -e "${YELLOW}2. AdGuard Home (DNS и Блокировка рекламы)${NC}"
echo -e "   Адрес:   http://$IP:3000"
echo -e "   Инфо:    Настройте логин/пароль при первом входе"
echo -e "----------------------------------------------------------------"
echo -e "${YELLOW}3. 3x-ui (Управление VPN)${NC}"
echo -e "   Адрес:   http://$IP:2053"
echo -e "   Логин:   admin"
echo -e "   Пароль:  admin"
echo -e "${PURPLE}================================================================${NC}"
echo -e "${RED}ВАЖНО:${NC} Смените стандартные пароли сразу после входа!"
