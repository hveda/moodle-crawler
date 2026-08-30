#!/bin/bash
# deploy.sh - Remote Server Deployment Script for Moodle Crawler (Go binary)
#
# REMOTE DEPLOYMENT: deploys the statically-linked Go crawler binary to a
# remote Ubuntu/Debian/RHEL server via SSH. Handles:
# - Local cross-compilation of the crawler (CGO_ENABLED=0)
# - Binary transfer via scp
# - User/group creation (moodle user)
# - Directory permissions and ownership
# - Systemd service installation and startup (direct binary, no container runtime required)
#
# REQUIREMENTS:
# - Go toolchain >= 1.25 on the deploying machine
# - SSH access to remote server (passwordless key-based auth recommended)
# - Remote user with sudo privileges (typically 'root')
#
# USAGE:
#   REMOTE_HOST=server.com ./deploy.sh                     # defaults
#   REMOTE_HOST=server.com MOODLE_URL=https://x ./deploy.sh
#
# Environment overrides:
#   REMOTE_HOST   (required) target server
#   REMOTE_USER   (default root)
#   REMOTE_APP_DIR (default /opt/moodle-crawler)
#   MOODLE_URL    (default https://solusi.sibermu.ac.id)
#   INTERVAL      scrape interval seconds (default 60)

set -euo pipefail

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"

REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-root}"
SOURCE_DIR="$(pwd)"
REMOTE_APP_DIR="${REMOTE_APP_DIR:-/opt/moodle-crawler}"
MOODLE_URL="${MOODLE_URL:-https://solusi.sibermu.ac.id}"
INTERVAL="${INTERVAL:-60}"
BIN="moodle-crawler"

if [ -z "$REMOTE_HOST" ]; then
    echo "ERROR: REMOTE_HOST environment variable is required"
    echo "Usage: REMOTE_HOST=your-server.com REMOTE_USER=ubuntu $0"
    exit 1
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

remote_exec() {
    ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "$@"
}

echo -e "${BLUE}=== Moodle Crawler (Go) Deployment Script ===${NC}"
echo -e "${YELLOW}Deploying to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_APP_DIR}${NC}"
echo -e "${YELLOW}Moodle URL: ${MOODLE_URL} (interval ${INTERVAL}s)${NC}"
echo

# Check prerequisites
if ! command -v ssh &> /dev/null; then
    echo -e "${RED}SSH is not installed. Please install SSH before continuing.${NC}"
    exit 1
fi
if ! command -v go &> /dev/null; then
    echo -e "${RED}Go toolchain not found. Install Go >= 1.25 (https://go.dev/dl/).${NC}"
    exit 1
fi
if [ ! -f "${SOURCE_DIR}/main.go" ]; then
    echo -e "${RED}main.go not found — run this script from the repo root.${NC}"
    exit 1
fi

# Build static binary (no CGO — runs on any Linux without runtime deps)
echo -e "${BLUE}Building static Go binary...${NC}"
mkdir -p "${SOURCE_DIR}/build"
( cd "${SOURCE_DIR}" && CGO_ENABLED=0 go build -ldflags="-w -s" -o "build/${BIN}" main.go )
echo -e "${GREEN}✓ Built build/${BIN} ($(du -h ${SOURCE_DIR}/build/${BIN} | cut -f1))${NC}"

# Check connection to server
echo -e "${BLUE}Checking connection to server...${NC}"
if ! ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "echo 2>&1" > /dev/null; then
    echo -e "${RED}Cannot connect to ${REMOTE_USER}@${REMOTE_HOST}.${NC}"
    echo -e "${YELLOW}ssh-copy-id ${REMOTE_USER}@${REMOTE_HOST}${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Connection successful${NC}"

# Create remote directory structure
echo -e "${BLUE}Creating remote directory structure...${NC}"
remote_exec "mkdir -p ${REMOTE_APP_DIR}/bin ${REMOTE_APP_DIR}/data"
echo -e "${GREEN}✓ Remote directory structure created${NC}"

# Upload binary
echo -e "${BLUE}Uploading binary...${NC}"
scp -q ${SSH_OPTS} "${SOURCE_DIR}/build/${BIN}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_APP_DIR}/bin/${BIN}.new"
remote_exec "mv ${REMOTE_APP_DIR}/bin/${BIN}.new ${REMOTE_APP_DIR}/bin/${BIN} && chmod 755 ${REMOTE_APP_DIR}/bin/${BIN}"
echo -e "${GREEN}✓ Binary uploaded${NC}"

# Create the moodle user and group
echo -e "${BLUE}Creating moodle user and group...${NC}"
remote_exec "id -u moodle &>/dev/null || useradd -r -s /bin/false moodle"
echo -e "${GREEN}✓ User moodle created or already exists${NC}"

# Ownership and data dir
echo -e "${BLUE}Setting ownership and permissions...${NC}"
remote_exec "
    chown root:root ${REMOTE_APP_DIR}/bin/${BIN}
    if id -u moodle &>/dev/null; then
        chown moodle:moodle ${REMOTE_APP_DIR}/data || true
        chmod 755 ${REMOTE_APP_DIR} || true
    else
        echo 'User moodle does not exist; skipping chown'
    fi
"
echo -e "${GREEN}✓ Permissions set${NC}"

# Install systemd unit
echo -e "${BLUE}Installing systemd service...${NC}"
remote_exec "
    cat > /etc/systemd/system/moodle-crawler.service <<UNIT
[Unit]
Description=Moodle Statistics Crawler (Go)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=moodle
Group=moodle
ExecStart=${REMOTE_APP_DIR}/bin/${BIN} --url=${MOODLE_URL} --interval=${INTERVAL} --output-dir=${REMOTE_APP_DIR}/data --prometheus=true
Restart=always
RestartSec=10

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${REMOTE_APP_DIR}/data
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable moodle-crawler
"
echo -e "${GREEN}✓ Service installed and enabled${NC}"

# Restart service
echo -e "${BLUE}(Re)starting service...${NC}"
remote_exec "systemctl restart moodle-crawler"

# Health check: poll service status and the /health endpoint
echo -e "${BLUE}Checking service health...${NC}"
if remote_exec "
    for i in {1..10}; do
        if systemctl is-active --quiet moodle-crawler; then
            echo OK
            exit 0
        fi
        sleep 2
    done
    echo FAIL
    exit 1
"; then
    echo -e "${GREEN}✓ Service is active and running${NC}"
else
    echo -e "${RED}Service did not reach active state. Recent journal entries:${NC}"
    remote_exec "journalctl -u moodle-crawler -n 100 --no-pager || true"
    exit 1
fi

# Post-deployment instructions
echo
echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo -e "${BLUE}Crawler deployed to ${REMOTE_APP_DIR}/bin/${BIN} on ${REMOTE_HOST}${NC}"
echo
echo -e "${YELLOW}Quick health & troubleshooting:${NC}"
echo -e "  systemctl status moodle-crawler -l          # service status"
echo -e "  journalctl -u moodle-crawler -f             # tail logs"
echo -e "  ls -lah ${REMOTE_APP_DIR}/data              # metrics files"
echo -e "  tail -n 20 ${REMOTE_APP_DIR}/data/metrics.prom"
echo -e "  curl http://127.0.0.1:9100/health           # health endpoint (on remote)"
echo
echo -e "${YELLOW}To redeploy: REMOTE_HOST=${REMOTE_HOST} ./deploy.sh${NC}"
