#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

usage() {
    cat <<'EOF'
Usage: bench.sh [BENCHMARKER_OPTIONS...]

Build and run the existing benchmarker against an Apple Container environment.
Example: bench.sh -benchmark-timeout 1m -d
The target URL and userdata path are supplied automatically.
The environment name is fixed to private-isu.
EOF
}
die() { echo "Error: $*" >&2; exit 1; }

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac
prefix=private-isu
id="${prefix}-benchmarker"
image="${id}:latest"

command -v container >/dev/null || die 'Install Apple Container first (see README.md)'
[[ -d "$ROOT/benchmarker/userdata/img" ]] || die 'Run make init at the repository root first'
container list --all >/dev/null || die 'Start Apple Container with: container system start'
container inspect "${prefix}-nginx" >/dev/null || die 'Start the environment with compose.sh up first'
if container inspect "$id" >/dev/null 2>&1; then
    die "$id already exists; stop/delete it before running another benchmark for this environment"
fi

# Build the unchanged workload with Apple Container's compatible COPY variant.
container build --platform linux/arm64 -t "$image" \
    -f "$ROOT/webapp/apple-container/Dockerfile.benchmarker" "$ROOT/benchmarker"
nginx_ip=$(container list --format table | awk -v name="${prefix}-nginx" '
    $1 == name && $5 == "running" && $6 ~ /^[0-9]+\./ {
        address = $6
        sub(/\/.*/, "", address)
        print address
        found = 1
    }
    END { if (!found) exit 1 }
') || die 'nginx is not running or has no IPv4 address'

cleanup() {
    result=$?
    trap - EXIT
    container delete --force "$id" >/dev/null 2>&1 || true
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Benchmark target: $prefix (http://$nginx_ip)" >&2
container run --rm --platform linux/arm64 --name "$id" --network "$prefix" \
    "$image" /bin/benchmarker "$@" -t "http://$nginx_ip" -u /opt/userdata
