#!/bin/bash
set -euo pipefail

WEBAPP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

usage() {
    cat <<'EOF'
Usage:
  compose.sh up [ruby|golang|php|python|node] [HTTP_PORT] [MYSQL_PORT]
  compose.sh down
  compose.sh status
  compose.sh logs [nginx|app|mysql|memcached]

Environment name: private-isu (fixed).
Defaults: ruby, HTTP_PORT=8080, MYSQL_PORT=13306 (bound to 127.0.0.1).
down preserves the MySQL volume. up rebuilds images from current sources.
MYSQL_WAIT_SECONDS (default 1800) controls the initial import timeout.
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    up|down|status|logs) action=$1 ;;
    *) usage >&2; exit 1 ;;
esac
shift
prefix=private-isu
network="$prefix"
volume="${prefix}-mysql"

case "$action" in
    up) [[ $# -le 3 ]] || die 'Too many arguments' ;;
    logs) [[ $# -le 1 ]] || die 'Too many arguments' ;;
    *) [[ $# -eq 0 ]] || die 'Too many arguments' ;;
esac

if [[ $action == up ]]; then
    language=${1:-ruby}
    case "$language" in
        ruby|golang|php|python|node) ;;
        *) die "Unsupported language: $language" ;;
    esac
    http_port=${2:-8080}
    mysql_port=${3:-13306}
    for port in "$http_port" "$mysql_port"; do
        [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) ||
            die 'Ports must be integers between 1 and 65535 (without leading zeros)'
    done
    [[ $http_port != "$mysql_port" ]] || die 'HTTP and MySQL ports must differ'
    mysql_wait=${MYSQL_WAIT_SECONDS:-1800}
    [[ $mysql_wait =~ ^[1-9][0-9]{0,5}$ ]] || die 'Invalid MYSQL_WAIT_SECONDS'
    [[ -s "$WEBAPP/sql/dump.sql.bz2" ]] || die 'Run make init at the repository root first'
    command -v curl >/dev/null || die 'curl is required for the HTTP readiness check'
fi

if [[ $action == logs ]]; then
    service=${1:-app}
    case "$service" in nginx|app|mysql|memcached) ;; *) die "Unknown service: $service" ;; esac
fi

command -v container >/dev/null || die 'Install Apple Container first (see README.md)'
# Fail before mutating anything if the service is not available.
container list --all >/dev/null || die 'Start Apple Container with: container system start'

exists() { container inspect "$1" >/dev/null 2>&1; }

ip_address() {
    container list --format table | awk -v name="$1" '
        $1 == name && $5 == "running" && $6 ~ /^[0-9]+\./ {
            address = $6
            sub(/\/.*/, "", address)
            print address
            found = 1
        }
        END { if (!found) exit 1 }
    '
}

case "$action" in
    logs) exec container logs --follow "${prefix}-${service}" ;;
    status) exec container inspect "${prefix}-nginx" "${prefix}-app" "${prefix}-mysql" "${prefix}-memcached" ;;
    down)
        for service in benchmarker nginx app memcached mysql; do
            id="${prefix}-${service}"
            if exists "$id"; then
                container stop "$id"
                container delete "$id"
            fi
        done
        if container network inspect "$network" >/dev/null 2>&1; then
            container network delete "$network"
        fi
        echo "Stopped $prefix. MySQL data retained in volume $volume."
        exit 0
        ;;
esac

for service in benchmarker nginx app mysql memcached; do
    if exists "${prefix}-${service}"; then
        die "${prefix}-${service} already exists; run down first"
    fi
done

# Build before creating runtime resources.
app_image="${prefix}-app:latest"
nginx_image="${prefix}-nginx:latest"
if [[ $language == golang ]]; then
    container build --platform linux/arm64 -t "$app_image" \
        -f "$WEBAPP/apple-container/Dockerfile.golang" "$WEBAPP/golang"
else
    container build --platform linux/arm64 -t "$app_image" "$WEBAPP/$language"
fi
container build --platform linux/arm64 -t "$nginx_image" \
    -f "$WEBAPP/apple-container/Dockerfile" "$WEBAPP"

created=()
created_network=false
rollback() {
    result=$?
    trap - EXIT
    if (( result != 0 )); then
        echo "Startup failed; removing containers from this attempt (MySQL data is retained)." >&2
        for id in ${created[@]+"${created[@]}"}; do
            container delete --force "$id" || true
        done
        if $created_network; then container network delete "$network" || true; fi
    fi
    exit "$result"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! container network inspect "$network" >/dev/null 2>&1; then
    container network create "$network"
    created_network=true
fi
if ! container volume inspect "$volume" >/dev/null 2>&1; then
    container volume create -s 16G "$volume"
fi

run_service() {
    local service=$1
    shift
    # run may create the container even when starting it fails.
    created+=("${prefix}-${service}")
    container run --detach --platform linux/arm64 --name "${prefix}-${service}" \
        --network "$network" "$@"
}

run_service mysql --cpus 1 --memory 1G \
    --env 'MYSQL_ROOT_HOST=%' --env MYSQL_ROOT_PASSWORD=root \
    --volume "$volume:/var/lib/mysql" \
    --volume "$WEBAPP/sql:/docker-entrypoint-initdb.d:ro" \
    --publish "127.0.0.1:${mysql_port}:3306" docker.io/library/mysql:9.7
run_service memcached docker.io/library/memcached:1.6

echo 'Waiting for MySQL initialization (the first dump import can take several minutes)...'
deadline=$((SECONDS + mysql_wait))
# TCP only: the entrypoint's temporary import server listens on a Unix socket.
until container exec "${prefix}-mysql" mysql --protocol=TCP -h 127.0.0.1 \
    -uroot -proot --database=isuconp -e 'SELECT 1' >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
        container logs "${prefix}-mysql" >&2 || true
        die 'Timed out waiting for MySQL; inspect the import logs above'
    fi
    sleep 2
done

mysql_ip=$(ip_address "${prefix}-mysql")
memcached_ip=$(ip_address "${prefix}-memcached")
public_path=/home/public
[[ $language != php ]] || public_path=/var/www/public
run_service app --init --cpus 1 --memory 1G \
    --env "ISUCONP_DB_HOST=$mysql_ip" --env ISUCONP_DB_PORT=3306 \
    --env ISUCONP_DB_USER=root --env ISUCONP_DB_PASSWORD=root --env ISUCONP_DB_NAME=isuconp \
    --env "ISUCONP_MEMCACHED_ADDRESS=${memcached_ip}:11211" \
    --volume "$WEBAPP/public:$public_path" "$app_image"
app_ip=$(ip_address "${prefix}-app")
run_service nginx --env "APP_HOST=$app_ip" --env "APP_LANGUAGE=$language" \
    --volume "$WEBAPP/public:/public" --publish "127.0.0.1:${http_port}:80" "$nginx_image"

deadline=$((SECONDS + 180))
until curl --fail --silent --output /dev/null --max-time 5 "http://127.0.0.1:${http_port}/login"; do
    if (( SECONDS >= deadline )); then
        container logs "${prefix}-app" >&2 || true
        container logs "${prefix}-nginx" >&2 || true
        die 'Timed out waiting for HTTP readiness'
    fi
    sleep 2
done
echo "Ready: http://127.0.0.1:$http_port ($language)"
echo "MySQL: 127.0.0.1:$mysql_port (root / root, database isuconp)"
