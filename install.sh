#!/bin/bash
set -euo pipefail

# --- Цвета ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; PURPLE='\033[0;35m'; NC='\033[0m'

# --- Проверка root ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Ошибка: запустите от root или через sudo${NC}" >&2
   exit 1
fi

echo -e "${BLUE}>>> 1. Сбор данных...${NC}"
read -rp "Введите ваш домен (например, hldpro.ru): " MY_DOMAIN
read -rp "Таймзона (по умолчанию Asia/Yekaterinburg): " MY_TZ
MY_TZ=${MY_TZ:-Asia/Yekaterinburg}
read -rp "Логин для всех панелей: " ADMIN_USER
read -rsp "Пароль для всех панелей: " ADMIN_PASS
echo -e "\n${GREEN}Данные получены. Начинаем развёртывание...${NC}"

PROJECT_DIR="$HOME/my-server"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# --- 2. Обновление системы и swap ---
echo -e "${BLUE}>>> 2. Обновление системы и настройка swap...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y

if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- 3. Установка зависимостей и Docker ---
echo -e "${BLUE}>>> 3. Установка Docker и утилит...${NC}"
apt install -y git curl ufw fail2ban openssl sqlite3 ca-certificates gnupg lsb-release dnsutils

if ! command -v docker &> /dev/null || ! command -v docker-compose &> /dev/null; then
    echo -e "${YELLOW}Docker не найден — устанавливаем...${NC}"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
fi

# --- Ожидание запуска Docker daemon ---
echo -e "${BLUE}>>> Ожидание готовности Docker daemon...${NC}"
for i in {1..30}; do
    if docker info >/dev/null 2>&1; then
        echo -e "${GREEN}Docker daemon готов.${NC}"
        break
    fi
    sleep 2
done
if ! docker info >/dev/null 2>&1; then
    echo -e "${RED}Ошибка: Docker daemon не запустился за 60 секунд.${NC}" >&2
    exit 1
fi

# --- 4. Генерация хешей ---
echo -e "${BLUE}>>> 4. Генерация безопасных хешей...${NC}"
ADG_HASH=$(openssl passwd -6 "$ADMIN_PASS")  # Для AdGuard (SHA-512 crypt)

BCRYPT_HASH=$(docker run --rm -i node:alpine sh -c "
    echo '$ADMIN_PASS' | node -e '
        const bcrypt = require(\"bcryptjs\");
        process.stdin.once(\"data\", pwd => console.log(bcrypt.hashSync(pwd.toString().trim(), 8)));
    '
")

# --- 5. Настройка UFW ---
echo -e "${BLUE}>>> 5. Настройка Firewall (UFW)...${NC}"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 53/tcp
ufw allow 53/udp
ufw allow 81/tcp
ufw allow 3000/tcp
ufw allow 2053/tcp
ufw allow 9000/tcp
ufw --force enable

# --- 6. Структура проекта ---
echo -e "${BLUE}>>> 6. Создание структуры каталогов...${NC}"
mkdir -p data/{npm,3x-ui,adguard/{conf,work},portainer}
echo -e ".env\ndata/\n*.log" > .gitignore

# --- 7. Конфигурация AdGuard Home ---
cat > data/adguard/conf/AdGuardHome.yaml <<EOF
bind_host: 0.0.0.0
bind_port: 3000
users:
  - name: $ADMIN_USER
    password: "$ADG_HASH"
dns:
  bind_hosts: ["0.0.0.0"]
  port: 53
http_proxy:
  enabled: false
EOF

# --- 8. .env ---
cat > .env <<EOF
MY_DOMAIN=$MY_DOMAIN
TZ=$MY_TZ
ADMIN_USER=$ADMIN_USER
EOF

# --- 9. Освобождение порта 53 ---
echo -e "${BLUE}>>> 7. Отключение systemd-resolved...${NC}"
systemctl stop systemd-resolved
systemctl disable systemd-resolved
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf

# --- 10. docker-compose.yml ---
cat > docker-compose.yml <<EOF
version: '3.8'
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    restart: unless-stopped
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    environment:
      - TZ=$MY_TZ
    volumes:
      - ./data/npm:/data
      - ./data/letsencrypt:/etc/letsencrypt

  3x-ui:
    image: ghcr.io/m0neit/3x-ui:latest
    restart: unless-stopped
    network_mode: host
    environment:
      - X_UI_ADMIN_USER=$ADMIN_USER
      - X_UI_ADMIN_PWD=$ADMIN_PASS
    volumes:
      - ./data/3x-ui:/etc/xray-ui

  adguard:
    image: adguard/adguardhome
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./data/adguard/work:/opt/adguardhome/work
      - ./data/adguard/conf:/opt/adguardhome/conf

  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    ports:
      - "9000:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data/portainer:/data
EOF

# --- 11. Запуск контейнеров ---
echo -e "${BLUE}>>> 11. Запуск сервисов...${NC}"
docker compose up -d

# --- 12. Инициализация Portainer через API ---
echo -e "${BLUE}>>> 12. Инициализация Portainer через API...${NC}"
PORTAINER_URL="http://localhost:9000"
INIT_FILE="data/portainer/init_done"

if [ ! -f "$INIT_FILE" ]; then
    echo -n "Ожидание запуска Portainer"
    for i in {1..30}; do
        if curl -s "$PORTAINER_URL/api/status" >/dev/null; then break; fi
        echo -n "."; sleep 2
    done
    echo

    if curl -s "$PORTAINER_URL/api/users/admin/init" >/dev/null; then
        PAYLOAD="{\"Username\":\"$ADMIN_USER\",\"Password\":\"$ADMIN_PASS\"}"
        RESPONSE=$(curl -s -X POST "$PORTAINER_URL/api/users/admin/init" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD")

        if echo "$RESPONSE" | grep -q '"id"'; then
            echo -e "${GREEN}Portainer успешно инициализирован!${NC}"
            touch "$INIT_FILE"
        else
            echo -e "${YELLOW}Portainer: инициализация не удалась. Ответ: $RESPONSE${NC}"
        fi
    else
        echo -e "${YELLOW}Portainer: endpoint недоступен — возможно, уже инициализирован.${NC}"
    fi
else
    echo -e "${GREEN}Portainer уже инициализирован (пропуск).${NC}"
fi

# --- 13. Настройка Nginx Proxy Manager (SQLite) ---
echo -e "${BLUE}>>> 13. Настройка NPM...${NC}"
NPM_DB="data/npm/database.sqlite"

echo -n "Ожидание базы NPM"
for i in {1..30}; do
    if [ -f "$NPM_DB" ]; then
        if sqlite3 "$NPM_DB" "SELECT 1 FROM user WHERE id = 1;" >/dev/null 2>&1; then
            break
        fi
    fi
    echo -n "."; sleep 2
done
echo

if [ -f "$NPM_DB" ] && sqlite3 "$NPM_DB" "SELECT 1 FROM user WHERE id = 1;" >/dev/null 2>&1; then
    sqlite3 "$NPM_DB" "UPDATE user SET password = '$BCRYPT_HASH', email = '${ADMIN_USER}@${MY_DOMAIN}' WHERE id = 1;"
    echo -e "${GREEN}NPM: пароль и email обновлены.${NC}"
else
    echo -e "${YELLOW}NPM: не удалось обновить учётную запись. Используйте admin@example.com / changeme.${NC}"
fi

# --- 14. Автоматическая настройка прокси через NPM API (с проверкой DNS) ---
echo -e "${BLUE}>>> 14. Проверка DNS и настройка HTTPS-прокси...${NC}"

CURRENT_IP=$(curl -s --max-time 5 ifconfig.me)
if [ -z "$CURRENT_IP" ]; then
    echo -e "${YELLOW}Не удалось определить внешний IP — пропуск автоматической настройки прокси.${NC}"
else
    echo -e "IP этого сервера: ${GREEN}$CURRENT_IP${NC}"
    echo -e "Проверка A-записей для поддоменов..."

    # Список поддоменов и портов
    declare -A SERVICES=( ["3x-ui"]=2053 ["adguard"]=3000 ["portainer"]=9000 )
    ALL_READY=true

    for sub in "${!SERVICES[@]}"; do
        full_domain="$sub.$MY_DOMAIN"
        resolved_ip=$(dig +short "$full_domain" A 2>/dev/null | head -n1)
        if [ "$resolved_ip" = "$CURRENT_IP" ]; then
            echo -e "✅ $full_domain → $resolved_ip"
        else
            echo -e "❌ $full_domain → '$resolved_ip' (ожидается $CURRENT_IP)"
            ALL_READY=false
        fi
    done

    if [ "$ALL_READY" = true ]; then
        read -rp "DNS корректен. Создать HTTPS-прокси с Let's Encrypt? (y/N): " CONFIRM_SSL
        if [[ "${CONFIRM_SSL,,}" == "y" ]]; then
            NPM_API="http://localhost:81/api"
            echo -n "Ожидание NPM API"
            for i in {1..30}; do
                if curl -sf "$NPM_API/status" >/dev/null; then break; fi
                echo -n "."; sleep 2
            done
            echo

            if ! curl -sf "$NPM_API/status" >/dev/null; then
                echo -e "${YELLOW}NPM API недоступен — пропуск.${NC}"
            else
                AUTH_RESP=$(curl -sf -X POST "$NPM_API/tokens" \
                    -H "Content-Type: application/json" \
                    -d "{\"identity\":\"$ADMIN_USER@$MY_DOMAIN\",\"password\":\"$ADMIN_PASS\"}" 2>/dev/null || true)
                TOKEN=$(echo "$AUTH_RESP" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
                if [ -z "$TOKEN" ]; then
                    echo -e "${YELLOW}Ошибка авторизации в NPM API.${NC}"
                else
                    HEADERS="-H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json'"
                    for sub in "${!SERVICES[@]}"; do
                        port=${SERVICES[$sub]}
                        full_domain="$sub.$MY_DOMAIN"
                        payload=$(cat <<EOF
{
  "domain_names": ["$full_domain"],
  "forward_host": "$CURRENT_IP",
  "forward_port": $port,
  "access_list_id": 0,
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
                        echo -n "Создание $full_domain..."
                        resp=$(curl -sf -X POST "$NPM_API/nginx/proxy-hosts" $HEADERS -d "$payload" 2>/dev/null || true)
                        if echo "$resp" | grep -q '"id"'; then
                            echo -e " ${GREEN}OK${NC}"
                        else
                            echo -e " ${YELLOW}Ошибка${NC}"
                        fi
                    done
                    echo -e "${GREEN}Готово! HTTPS будет доступен через 1-2 минуты.${NC}"
                fi
            fi
        else
            echo -e "${BLUE}Автоматизация отменена. Настройте прокси вручную в NPM (${NC}http://${CURRENT_IP}:81${BLUE}).${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  DNS не готов. Добавьте A-записи, затем настройте прокси вручную в NPM.${NC}"
    fi
fi

# --- Финальный вывод ---
IP=$(curl -s --max-time 5 ifconfig.me || echo "IP недоступен")

echo -e "\n${PURPLE}================================================================${NC}"
echo -e "${GREEN}             УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!                      ${NC}"
echo -e "${PURPLE}================================================================${NC}"
echo -e "${YELLOW}Учётные данные:${NC}"
echo -e "Логин: ${GREEN}$ADMIN_USER${NC}"
echo -e "Пароль: ${GREEN}$ADMIN_PASS${NC}"
echo -e "----------------------------------------------------------------"
echo -e "${BLUE}• Nginx Proxy Manager:${NC} http://$IP:81"
echo -e "${BLUE}• AdGuard Home:${NC}        http://$IP:3000          → https://adguard.$MY_DOMAIN"
echo -e "${BLUE}• 3x-ui (VPN):${NC}         http://$IP:2053           → https://3x-ui.$MY_DOMAIN"
echo -e "${BLUE}• Portainer:${NC}           http://$IP:9000           → https://portainer.$MY_DOMAIN"
echo -e "${PURPLE}================================================================${NC}"
echo -e "${YELLOW}Совет: если прокси не создались автоматически — зайдите в NPM и настройте их вручную.${NC}"
