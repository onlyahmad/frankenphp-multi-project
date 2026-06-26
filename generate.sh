#!/bin/bash
# =============================================================
# generate.sh - Auto-generate Caddyfile & podman-compose.yml
#               dari projects.conf
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/projects.conf"
CADDYFILE="${SCRIPT_DIR}/Caddyfile"
COMPOSEFILE="${SCRIPT_DIR}/podman-compose.yml"

# Warna output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ---- Validasi ----
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}ERROR: projects.conf tidak ditemukan!${NC}"
    exit 1
fi

# Parse projects.conf (skip komentar dan baris kosong)
declare -a NAMES=()
declare -a PORTS=()
declare -a PATHS=()
declare -a AUTH_USERS=()
declare -a AUTH_PASSES=()

while IFS=: read -r name port path auth_user auth_pass; do
    # Skip komentar dan baris kosong
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    # Trim whitespace
    name=$(echo "$name" | xargs)
    port=$(echo "$port" | xargs)
    path=$(echo "$path" | xargs)
    auth_user=$(echo "${auth_user:-}" | xargs)
    auth_pass=$(echo "${auth_pass:-}" | xargs)

    # Validasi
    if [[ -z "$name" || -z "$port" || -z "$path" ]]; then
        echo -e "${RED}ERROR: Format salah pada baris: ${name}:${port}:${path}${NC}"
        echo "Format yang benar: NAMA:PORT:PATH"
        exit 1
    fi

    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}ERROR: Port '${port}' bukan angka valid untuk project '${name}'${NC}"
        exit 1
    fi

    if [[ ! -d "${SCRIPT_DIR}/html/${path}/public" ]]; then
        echo -e "${YELLOW}WARNING: Directory html/${path}/public tidak ditemukan untuk project '${name}'. Membuat direktori...${NC}"
        mkdir -p "${SCRIPT_DIR}/html/${path}/public"
    fi

    NAMES+=("$name")
    PORTS+=("$port")
    PATHS+=("$path")
    AUTH_USERS+=("$auth_user")
    AUTH_PASSES+=("$auth_pass")
done < "$CONFIG_FILE"

if [[ ${#NAMES[@]} -eq 0 ]]; then
    echo -e "${RED}ERROR: Tidak ada project yang dikonfigurasi di projects.conf${NC}"
    exit 1
fi

# Cek duplikat port
declare -A PORT_MAP=()
for i in "${!PORTS[@]}"; do
    if [[ -n "${PORT_MAP[${PORTS[$i]}]:-}" ]]; then
        echo -e "${RED}ERROR: Port ${PORTS[$i]} digunakan oleh '${PORT_MAP[${PORTS[$i]}]}' dan '${NAMES[$i]}'${NC}"
        exit 1
    fi
    PORT_MAP[${PORTS[$i]}]="${NAMES[$i]}"
done

echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN} FrankenPHP Multi-Project Generator${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""
echo -e "${GREEN}Ditemukan ${#NAMES[@]} project:${NC}"
for i in "${!NAMES[@]}"; do
    echo -e "  ${YELLOW}→${NC} ${NAMES[$i]} (port ${PORTS[$i]}) => html/${PATHS[$i]}"
done
echo ""

# =============================================================
# Generate Caddyfile
# =============================================================
echo -e "${GREEN}Generating Caddyfile...${NC}"

cat > "$CADDYFILE" << 'CADDY_GLOBAL'
{
    frankenphp
    order php_server before file_server
    auto_https off
    admin off
}

CADDY_GLOBAL

for i in "${!NAMES[@]}"; do
    cat >> "$CADDYFILE" << CADDY_SITE_HEADER
# ${NAMES[$i]} -> port ${PORTS[$i]}
http://:${PORTS[$i]} {
    root * /srv/${NAMES[$i]}/public
    encode zstd gzip br

    # Optimasi Kecepatan: Caching Static Assets
    @static {
        path *.ico *.css *.js *.gif *.webp *.avif *.jpg *.jpeg *.png *.svg *.woff *.woff2
    }
    header @static Cache-Control "public, max-age=31536000, immutable"

    header {
        X-Frame-Options "DENY"
        Content-Security-Policy "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; object-src 'none'; frame-ancestors 'none'"
        X-Content-Type-Options "nosniff"
        Cache-Control "no-store, no-cache, must-revalidate"
        Pragma "no-cache"
        Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "geolocation=(), microphone=(), camera=()"
        -X-Powered-By
    }

    php_server
    file_server

CADDY_SITE_HEADER

    # Otorisasi Tersendiri: Basic Auth
    if [[ -n "${AUTH_USERS[$i]}" && -n "${AUTH_PASSES[$i]}" ]]; then
        echo -e "  ${YELLOW}→${NC} Generating hash for auth ${NAMES[$i]}..."
        # Generate bcrypt hash
        HASH=$(python3 -c "import crypt; print(crypt.crypt('${AUTH_PASSES[$i]}', '\$2a\$10\$' + '1234567890123456789012'))" 2>/dev/null || true)
        if [[ -z "$HASH" ]]; then
            HASH=$(podman run --rm docker.io/caddy:alpine caddy hash-password --plaintext "${AUTH_PASSES[$i]}" 2>/dev/null)
        fi
        
        cat >> "$CADDYFILE" << CADDY_AUTH
    basicauth / {
        ${AUTH_USERS[$i]} ${HASH}
    }
CADDY_AUTH
    fi

    # Isolasi project dengan open_basedir di .user.ini
    echo "open_basedir = /srv/${NAMES[$i]}/:/tmp/" > "${SCRIPT_DIR}/html/${PATHS[$i]}/public/.user.ini"

    # Use quoted heredoc for the regex part to prevent backslash interpretation
    cat >> "$CADDYFILE" << 'CADDY_SITE_FOOTER'
    @hidden {
        path_regexp hidden ^/(\.|_.*|.*\.(env|git|log|sql|sqlite|json|yml|lock|htaccess|htpasswd|phar)$)
    }
    respond @hidden 404
}

CADDY_SITE_FOOTER
done

echo -e "  ${GREEN}✓${NC} Caddyfile berhasil di-generate"

# =============================================================
# Generate podman-compose.yml
# =============================================================
echo -e "${GREEN}Generating podman-compose.yml...${NC}"

# Build ports section
PORTS_SECTION=""
for i in "${!NAMES[@]}"; do
    PORTS_SECTION+="      - \"${PORTS[$i]}:${PORTS[$i]}\"   # ${NAMES[$i]}\n"
done
# Remove or comment out Xdebug for production
# PORTS_SECTION+="      - \"9003:9003\"   # xdebug"

# Build volumes section
VOLUMES_SECTION=""
for i in "${!NAMES[@]}"; do
    VOLUMES_SECTION+="      - ./html/${PATHS[$i]}:/srv/${NAMES[$i]}:rw,z\n"
done
# Add trailing newline for clean separation
VOLUMES_SECTION+=""

# Build SERVER_NAME
SERVER_NAMES=""
for i in "${!NAMES[@]}"; do
    if [[ -n "$SERVER_NAMES" ]]; then
        SERVER_NAMES+=", "
    fi
    SERVER_NAMES+="http://:${PORTS[$i]}"
done

cat > "$COMPOSEFILE" << COMPOSE_EOF
services:
  app:
    container_name: frankenphp
    image: docker.io/1510520140/franken-php8.2
    ports:
$(echo -e "$PORTS_SECTION")
    volumes:
      # Project directories (auto-generated)
$(echo -e "$VOLUMES_SECTION")
      # Config files
      - ./.docker/php/php.ini:/usr/local/etc/php/php.ini:ro
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      # Caddy persistent data
      - caddy_data:/data
      - caddy_config:/config
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
      - NET_BIND_SERVICE
    networks:
      - backend
      - redis
      - database

    environment:
      SERVER_NAME: "${SERVER_NAMES}"

    depends_on:
      - redis

    deploy:
      resources:
        limits:
          memory: 1g
          cpus: "0.5"

  mysql:
    container_name: mysql-frankenphp
    image: docker.io/library/mysql:8.0.36
    command:
      - --sort_buffer_size=67108864
    environment:
      MYSQL_ROOT_PASSWORD: passwordfrankenphp!
      MYSQL_USER: user
      MYSQL_PASSWORD: passwordfrankenphp@
    # Do not expose internal database port to host in production
    # ports:
    #   - "3306:3306"
    volumes:
      - mysql_data:/var/lib/mysql
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      - database
    deploy:
      resources:
        limits:
          memory: 1g
          cpus: "0.5"

  redis:
    container_name: redis-frankenphp
    image: docker.io/library/redis:latest
    command: >
      redis-server
      --appendonly yes
      --replica-read-only no
      --requirepass yourredispasswordfrankenphp
    # Do not expose internal redis port to host in production
    # ports:
    #   - "127.0.0.1:6377:6379"
    volumes:
      - redis_data:/data
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      - redis
    deploy:
      resources:
        limits:
          memory: 512m
          cpus: "0.25"

  phpmyadmin:
    container_name: phpmyadmin-frankenphp
    image: docker.io/library/phpmyadmin:latest
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    # Exposing phpmyadmin in production can be dangerous, it's mapped to localhost only
    ports:
      - "127.0.0.1:8080:80"
    environment:
      PMA_HOST: mysql
      PMA_USER: root
      PMA_PASSWORD: passwordfrankenphp!
      UPLOAD_LIMIT: 500M
    depends_on:
      - mysql
    networks:
      - database

networks:
  backend:
    driver: bridge
  redis:
    driver: bridge
  database:
    driver: bridge

volumes:
  mysql_data:
  redis_data:
  caddy_data:
  caddy_config:
COMPOSE_EOF

echo -e "  ${GREEN}✓${NC} podman-compose.yml berhasil di-generate"

# =============================================================
# Summary
# =============================================================
echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN} Selesai! Akses project:${NC}"
echo -e "${CYAN}=========================================${NC}"
for i in "${!NAMES[@]}"; do
    echo -e "  ${YELLOW}→${NC} ${NAMES[$i]}: ${GREEN}http://localhost:${PORTS[$i]}${NC}"
done
echo -e "  ${YELLOW}→${NC} phpMyAdmin: ${GREEN}http://localhost:8080${NC}"
echo ""
echo -e "${YELLOW}Jalankan:${NC}"
echo "  podman-compose -f podman-compose.yml up -d --force-recreate app"
echo ""
