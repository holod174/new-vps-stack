#!/bin/bash
set -euo pipefail

# --- Цвета ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; PURPLE='\033[0;35m'; NC='\033[0m'

# --- Проверка root ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Ошибка: запустите от root${NC}" >&2
   exit 1
fi

# --- 1. Сбор данных ---
if [[ "${1:-}" == "debug" ]]; then
    echo -e "${YELLOW}>>> РЕЖИМ ОТЛАДКИ: Автозаполнение включено${NC}"
    MY_DOMAIN="hldpro.ru"
    MY_TZ="Asia/Yekaterinburg"
    ADMIN_USER="admin"
    ADMIN_PASS="MySuperStrongP@ss2026"
else
    echo -e "${BLUE}>>> 1. Сбор данных...${NC}"
    read -rp "Введите ваш домен (hldpro.ru): " MY_DOMAIN
    MY_DOMAIN=${MY_DOMAIN:-"hldpro.ru"}
    read -rp "Таймзона (Asia/Yekaterinburg): " MY_TZ
    MY_TZ=${MY_TZ:-"Asia/Yekaterinburg"}
    read -rp "Логин для всех панелей: " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-"admin"}
    read -rsp "Пароль (мин. 12 симв.): " ADMIN_PASS
    ADMIN_PASS=${ADMIN_PASS:-"MySuperStrongP@ss2026"}
    echo -e "\n"
fi

PROJECT_DIR="$HOME/my-server"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# --- 2. Подготовка ОС ---
echo -e "${BLUE}>>> 2. Обновление ОС и настройка Swap...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo -e "${GREEN}Swap 2GB создан успешно.${NC}"
fi

# --- 3. Софт и Хеширование ---
echo -e "${BLUE}>>> 3. Установка Docker и генерация хешей...${NC}"
apt install -y git curl ufw fail2ban openssl sqlite3 ca-certificates gnupg lsb-release dnsutils apache2-utils
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh
    echo -e "${GREEN}Docker установлен.${NC}"
fi
BCRYPT_HASH=$(htpasswd -nbBC 8 "" "$ADMIN_PASS" | cut -d ":" -f 2)
echo -e "${GREEN}Bcrypt-хеш для пароля сгенерирован.${NC}"

# --- 4. Сеть и Firewall ---
echo -e "${BLUE}>>> 4. Настройка Firewall и DNS...${NC}"
ufw --force reset
ufw allow 22,80,443,81,3000,2053,9000/tcp && ufw allow 53/tcp && ufw allow 53/udp
echo "y" | ufw enable
systemctl stop systemd-resolved && systemctl disable systemd-resolved || true
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo -e "${GREEN}Порт 53 освобожден. Firewall настроен.${NC}"

# --- 5. Структура и Docker Compose ---
mkdir -p data/{npm,3x-ui,adguard/{conf,work},portainer}
cat > docker-compose.yml <<EOF
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    restart: unless-stopped
    ports: ["80:80", "81:81", "443:443"]
    environment: { TZ: "$MY_TZ" }
    volumes: ["./data/npm:/data", "./data/letsencrypt:/etc/letsencrypt"]
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:latest
    restart: unless-stopped
    network_mode: host
    environment: { X_UI_ADMIN_USER: "$ADMIN_USER", X_UI_ADMIN_PWD: "$ADMIN_PASS" }
    volumes: ["./data/3x-ui:/etc/xray-ui"]
  adguard:
    image: adguard/adguardhome:latest
    restart: unless-stopped
    network_mode: host
    volumes: ["./data/adguard/work:/opt/adguardhome/work", "./data/adguard/conf:/opt/adguardhome/conf"]
  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    ports: ["9000:9000"]
    volumes: ["/var/run/docker.sock:/var/run/docker.sock", "./data/portainer:/data"]
EOF

# --- 6. Запуск контейнеров ---
echo -e "${BLUE}>>> 6. Запуск Docker контейнеров...${NC}"
docker compose up -d
echo -e "${GREEN}Контейнеры запущены.${NC}"

# --- 7. Portainer API (с подробным ответом) ---
echo -e "${BLUE}>>> 7. Инициализация Portainer...${NC}"
docker compose restart portainer
sleep 10
PORTAINER_URL="http://localhost:9000/api/users/admin/init"
RESPONSE=$(curl -s -X POST "$PORTAINER_URL" -H "Content-Type: application/json" -d "{\"Username\":\"$ADMIN_USER\",\"Password\":\"$ADMIN_PASS\"}")
if echo "$RESPONSE" | grep -q '"id"'; then
    echo -e "${GREEN}Успех: Portainer администратор создан.${NC}"
else
    echo -e "${YELLOW}Инфо: Portainer уже инициализирован или ответ: $RESPONSE${NC}"
fi

# --- 8. Настройка NPM Database + перезапуск ---
echo -e "${BLUE}>>> 8. Настройка базы данных NPM...${NC}"
NPM_DB="data/npm/database.sqlite"

# Ждём появления базы и таблицы auth
for i in {1..30}; do
    if [ -s "$NPM_DB" ] && sqlite3 "$NPM_DB" ".tables" 2>/dev/null | grep -q "auth"; then
        break
    fi
    echo -n "."
    sleep 2
done
echo ""

# Обновляем email и пароль
sqlite3 "$NPM_DB" "UPDATE user SET email = '${ADMIN_USER}@${MY_DOMAIN}' WHERE id = 1;"
sqlite3 "$NPM_DB" "UPDATE auth SET secret = '$BCRYPT_HASH' WHERE user_id = 1 AND type = 'password';"
echo -e "${GREEN}Данные администратора внедрены в базу NPM.${NC}"

# 🔁 КРИТИЧЕСКИ ВАЖНО: перезапустить NPM, чтобы он перечитал БД!
echo -e "${YELLOW}Перезапуск NPM для применения новых учётных данных...${NC}"
docker compose restart npm
sleep 10  # даём время на полную инициализацию

# --- 9. Автоматизация прокси и SSL ---
echo -e "${BLUE}>>> 9. Проверка DNS и создание Proxy Hosts...${NC}"
CURRENT_IP=$(curl -4 -s ifconfig.me)
echo -e "Внешний IP сервера: ${PURPLE}$CURRENT_IP${NC}"

declare -A SERVICES=( ["3x-ui"]=2053 ["adguard"]=3000 ["portainer"]=9000 )
ALL_DNS_OK=true

for sub in "${!SERVICES[@]}"; do
    full_domain="$sub.$MY_DOMAIN"
    resolved_ip=$(dig -4 +short "$full_domain" A | head -n1)
    if [ "$resolved_ip" = "$CURRENT_IP" ]; then
        echo -e "✅ $full_domain -> $resolved_ip ${GREEN}(OK)${NC}"
    else
        echo -e "❌ $full_domain -> $resolved_ip ${RED}(DNS еще не обновился)${NC}"
        ALL_DNS_OK=false
    fi
done

if [ "$ALL_DNS_OK" = true ]; then
    echo -e "${YELLOW}Все DNS-записи верны. Ожидание готовности Nginx Proxy Manager (порт 81)...${NC}"
    
    # Ждём, пока NPM начнёт отвечать
    for i in {1..40}; do
        if curl -s --connect-timeout 3 "http://127.0.0.1:81" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ NPM готов к работе.${NC}"
            break
        fi
        echo -n "."
        sleep 3
        if [ $i -eq 40 ]; then
            echo -e "\n${RED}❌ NPM не запустился за 2 минуты. Проверьте логи: docker logs my-server-npm-1${NC}"
            exit 1
        fi
    done

    NPM_API="http://127.0.0.1:81/api"

    # Авторизация
    echo -e "Авторизация в NPM..."
    AUTH_RESP=$(curl -s -X POST "$NPM_API/tokens" \
        -H "Content-Type: application/json" \
        -d "{\"identity\":\"$ADMIN_USER@$MY_DOMAIN\",\"password\":\"$ADMIN_PASS\"}")

    TOKEN=$(echo "$AUTH_RESP" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$TOKEN" ]; then
        echo -e "${RED}❌ Не удалось авторизоваться в NPM. Возможно, пароль ещё не применён или NPM не завершил инициализацию.${NC}"
        echo -e "Попробуйте подождать 1-2 минуты и запустить скрипт повторно с флагом debug:"
        echo -e "  sudo ./install.sh debug"
        exit 1
    fi

    echo -e "${GREEN}✅ Токен получен. Создаём прокси-хосты...${NC}"
    for sub in "${!SERVICES[@]}"; do
        port=${SERVICES[$sub]}
        full_domain="$sub.$MY_DOMAIN"
        echo -n "  → https://$full_domain ... "

        PAYLOAD=$(cat <<EOF
{
  "domain_names": ["$full_domain"],
  "forward_host": "$CURRENT_IP",
  "forward_port": $port,
  "certificate_id": "new",
  "ssl_forced": true,
  "http2_support": true,
  "meta": {
    "letsencrypt_email": "$ADMIN_USER@$MY_DOMAIN",
    "letsencrypt_agree": true
  }
}
EOF
        )

        RESP=$(curl -s -X POST "$NPM_API/nginx/proxy-hosts" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD")

        if echo "$RESP" | grep -q '"id"'; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAIL${NC}"
            echo "Ответ: $RESP" >&2
        fi
    done
else
    echo -e "${RED}ВНИМАНИЕ: Авто-выпуск SSL пропущен, так как DNS ещё не указывает на этот сервер.${NC}"
fi

# --- 10. ФИНАЛЬНЫЙ ОТЧЕТ (Расширенный) ---
echo -e "\n${PURPLE}================================================================${NC}"
echo -e "${GREEN}               УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!                     ${NC}"
echo -e "${PURPLE}================================================================${NC}"
echo -e "${YELLOW}ОСНОВНЫЕ ДАННЫЕ:${NC}"
echo -e "Домен:          ${CYAN}$MY_DOMAIN${NC}"
echo -e "IP Сервера:     ${CYAN}$CURRENT_IP${NC}"
echo -e "Логин панелей:  ${GREEN}$ADMIN_USER${NC}"
echo -e "Пароль панелей: ${GREEN}$ADMIN_PASS${NC}"
echo -e "----------------------------------------------------------------"
echo -e "${YELLOW}ДОСТУП К СЕРВИСАМ:${NC}"
echo -e "1. Portainer:   https://portainer.$MY_DOMAIN (управление Docker)"
echo -e "2. AdGuard:     https://adguard.$MY_DOMAIN   (фильтрация DNS)"
echo -e "3. 3x-ui (VPN): https://3x-ui.$MY_DOMAIN     (настройка туннелей)"
echo -e "4. NPM Panel:   http://$CURRENT_IP:81        (управление прокси)"
echo -e "----------------------------------------------------------------"
echo -e "${RED}ВАЖНО:${NC} Если HTTPS ссылки не открываются, подождите 2-3 минуты,"
echo -e "пока NPM выпустит сертификаты Let's Encrypt."
echo -e "${PURPLE}================================================================${NC}"
