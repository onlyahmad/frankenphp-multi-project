#!/bin/bash
# =============================================================
# benchmark.sh - Uji Coba Kecepatan & Kapasitas FrankenPHP
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/projects.conf"

# Warna output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}ERROR: projects.conf tidak ditemukan!${NC}"
    exit 1
fi

echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN} FrankenPHP Benchmark Tool (ApacheBench) ${NC}"
echo -e "${CYAN}=========================================${NC}"
echo "Menggunakan Podman container (httpd:alpine) untuk melakukan pengujian."
echo "Note: Kecepatan asli Laravel tergantung pada kompleksitas query dan caching (Route/Config cache)."
echo ""

# Konfigurasi Benchmark
TOTAL_REQUESTS=100
CONCURRENCY=10

echo -e "${YELLOW}Parameter:${NC} ${TOTAL_REQUESTS} requests, ${CONCURRENCY} concurrency level"
echo ""

# Loop semua project dari projects.conf
while IFS=: read -r name port path auth_user auth_pass; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name=$(echo "$name" | xargs)
    port=$(echo "$port" | xargs)
    auth_user=$(echo "${auth_user:-}" | xargs)
    auth_pass=$(echo "${auth_pass:-}" | xargs)

    echo -e "${GREEN}▶ Menguji Project:${NC} ${name} (Port: ${port})"
    
    # URL testing
    URL="http://host.containers.internal:${port}/"
    
    # Setup otorisasi jika ada
    AUTH_HEADER=""
    if [[ -n "$auth_user" && -n "$auth_pass" ]]; then
        echo "  [!] Project menggunakan Basic Auth, menyuntikkan kredensial..."
        # Format kredensial untuk ab
        AUTH_HEADER="-A ${auth_user}:${auth_pass}"
    fi

    echo "  Melakukan request ke ${URL}..."
    
    # Menjalankan ab (ApacheBench) dari dalam container
    # -q: hide progress
    # -n: total requests
    # -c: concurrency
    podman run --rm docker.io/httpd:alpine ab -q -n ${TOTAL_REQUESTS} -c ${CONCURRENCY} ${AUTH_HEADER} ${URL} | grep -E "Requests per second|Time per request|Failed requests|Complete requests|Transfer rate" || echo -e "${RED}Gagal menguji ${name}.${NC}"
    
    echo "--------------------------------------------------------"
done < "$CONFIG_FILE"

echo -e "${CYAN}Selesai!${NC}"
echo "Tips untuk meningkatkan skor kecepatan (RPS):"
echo " 1. Jalankan php artisan optimize (route & config cache) di setiap project."
echo " 2. Pastikan koneksi database tidak bottleneck."
echo " 3. Gunakan mode worker (Octane) di FrankenPHP jika didukung."
