#!/usr/bin/env bash
set -euo pipefail
GLM_DATA_DIR=/mnt/nvme/glm-5.3
GLM_INSTALL_DIR=/opt/glm53
GLM_PORT=8000
GLM_BIND_ADDRESS=0.0.0.0
GLM_CHECK_ONLY=0
GLM_RENDER_ONLY=0
usage() {
  cat <<'EOF'
Usage: sudo bash glm53-install.sh [options]
  --data-dir PATH     Model/runtime cache (default /mnt/nvme/glm-5.3)
  --install-dir PATH  Deployment files (default /opt/glm53)
  --port NUMBER       Public API port (default 8000)
  --bind ADDRESS      Bind address (default 0.0.0.0)
  --check             Read-only prerequisite check; do not deploy
  --render-only PATH  Write deployment files only; do not start services
Prerequisites: Linux x86_64, Docker Compose v2+, NVIDIA Container Toolkit,
r580+ driver, 8 GPUs with at least 170000 MiB each, ~850 GiB free storage.
EOF
}
while (($#)); do
  case "$1" in
    --data-dir) GLM_DATA_DIR=${2:?missing path}; shift 2 ;;
    --install-dir) GLM_INSTALL_DIR=${2:?missing path}; shift 2 ;;
    --port) GLM_PORT=${2:?missing port}; shift 2 ;;
    --bind) GLM_BIND_ADDRESS=${2:?missing address}; shift 2 ;;
    --check) GLM_CHECK_ONLY=1; shift ;;
    --render-only) GLM_INSTALL_DIR=${2:?missing path}; GLM_RENDER_ONLY=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $GLM_DATA_DIR = /* && $GLM_INSTALL_DIR = /* ]] || fail 'Use absolute paths.'
[[ $GLM_DATA_DIR =~ ^/[a-zA-Z0-9_./-]+$ && $GLM_INSTALL_DIR =~ ^/[a-zA-Z0-9_./-]+$ ]] || fail 'Paths must contain only letters, numbers, underscores, dots, slashes, and hyphens.'
[[ $GLM_PORT =~ ^[0-9]+$ ]] && ((GLM_PORT >= 1 && GLM_PORT <= 65535)) || fail 'Invalid port.'
[[ $GLM_BIND_ADDRESS =~ ^[0-9.]+$ ]] || fail 'Bind address must be an IPv4 address.'
[[ $GLM_DATA_DIR != *$'\n'* && $GLM_INSTALL_DIR != *$'\n'* ]] || fail 'Invalid path.'
export GLM_DATA_DIR GLM_PORT GLM_BIND_ADDRESS
compose() { docker compose --project-name glm53 --project-directory "$GLM_INSTALL_DIR" -f "$GLM_INSTALL_DIR/compose.yaml" "$@"; }
check_prerequisites() {
  [[ $(uname -m) = x86_64 ]] || fail 'This pinned image deployment requires x86_64.'
  for executable in docker nvidia-smi python3 curl ss systemctl; do
    command -v "$executable" >/dev/null || fail "Install $executable first."
  done
  docker info >/dev/null 2>&1 || fail 'Docker is unavailable or permission denied; use sudo.'
  docker compose version >/dev/null 2>&1 || fail 'Install the Docker Compose plugin first.'
  docker info --format '{{json .Runtimes}}' | python3 -c 'import json,sys; sys.exit(0 if "nvidia" in json.load(sys.stdin) else 1)' || fail 'Install/configure NVIDIA Container Toolkit for Docker first.'
  nvidia-smi --query-gpu=memory.total,driver_version --format=csv,noheader,nounits | python3 -c '
import sys
rows=[line.strip().split(",") for line in sys.stdin if line.strip()]
if len(rows)!=8 or any(int(r[0])<170000 for r in rows) or any(int(r[1].strip().split(".")[0])<580 for r in rows):
    raise SystemExit("Need exactly 8 GPUs, >=170000 MiB each, and r580+ driver for this full-context deployment.")
print("GPU/driver check passed.")' || fail 'Unsupported hardware for the packaged configuration.'
  local ancestor=$GLM_DATA_DIR
  while [[ ! -d $ancestor ]]; do ancestor=$(dirname "$ancestor"); done
  local cached=0
  if [[ -d $GLM_DATA_DIR/hf-cache ]]; then cached=$(du -sb "$GLM_DATA_DIR/hf-cache" | awk '{print $1}'); fi
  local needed=$((850 * 1024 * 1024 * 1024 - cached))
  if ((needed < 40 * 1024 * 1024 * 1024)); then needed=$((40 * 1024 * 1024 * 1024)); fi
  local available
  available=$(df -B1 --output=avail "$ancestor" | tail -1 | tr -d ' ')
  ((available >= needed)) || fail "Insufficient storage at $ancestor; use --data-dir on a larger disk."
  local docker_root docker_available
  docker_root=$(docker info --format '{{.DockerRootDir}}')
  docker_available=$(df -B1 --output=avail "$docker_root" | tail -1 | tr -d ' ')
  ((docker_available >= 40 * 1024 * 1024 * 1024)) || fail "Need at least 40 GiB free at Docker's storage root: $docker_root."
  echo 'Prerequisites passed.'
}
if ((GLM_RENDER_ONLY)); then
  mkdir -p "$GLM_INSTALL_DIR"
  write_assets
  echo "Rendered files in $GLM_INSTALL_DIR; no services changed."
  exit 0
fi
check_prerequisites
if ((GLM_CHECK_ONLY)); then exit 0; fi
((EUID == 0)) || fail 'Run the installer with sudo.'
existing=''
if [[ -f $GLM_INSTALL_DIR/compose.yaml ]]; then existing=$(compose ps -q vllm); fi
if [[ -z $existing ]]; then
  nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | python3 -c 'import sys; sys.exit(any(int(line.strip())>1024 for line in sys.stdin if line.strip()))' || fail 'GPUs are busy. This installer will not stop another deployment.'
fi
if [[ -z $existing ]] && ss -H -ltn "sport = :$GLM_PORT" | head -1 | python3 -c 'import sys; sys.exit(bool(sys.stdin.read().strip()))'; then
  :
elif [[ -z $existing ]]; then
  fail "Port $GLM_PORT is already occupied; use --port or stop its owner first."
fi
mkdir -p "$GLM_INSTALL_DIR" "$GLM_DATA_DIR/hf-cache" "$GLM_DATA_DIR/runtime-cache"
write_assets
compose config --quiet
systemctl enable --now docker
echo 'Pulling vLLM and downloading model weights (cache is reused)...'
compose --profile prepare pull download
compose --profile prepare run --rm download
echo 'Building proxy and starting vLLM; first startup can take several minutes...'
compose up -d --build --wait --wait-timeout 7200 vllm proxy
health_host=$GLM_BIND_ADDRESS
if [[ $health_host = 0.0.0.0 ]]; then health_host=127.0.0.1; fi
curl -fsS "http://$health_host:$GLM_PORT/health" >/dev/null
curl -fsS "http://$health_host:$GLM_PORT/v1/models"
echo
echo "Ready: http://<instance-address>:$GLM_PORT/v1 (model zai-org/GLM-5.3)"
echo "Manage: cd $GLM_INSTALL_DIR && sudo docker compose logs -f"
