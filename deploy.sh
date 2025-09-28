#!/bin/bash
# deploy.sh - Remote Server Deployment Script for Moodle Crawler
#
# REMOTE DEPLOYMENT: This script automates deployment to a remote Ubuntu/Debian server
# via SSH. It handles the complete setup process including:
# - File transfer via rsync
# - Python environment setup (virtual environment + dependencies)
# - User/group creation (moodle user)
# - Directory permissions and ownership
# - Service installation and startup
#
# REQUIREMENTS:
# - SSH access to remote server (passwordless key-based auth recommended)
# - Target server: Ubuntu/Debian with apt package manager
# - Remote user with sudo privileges (typically 'root')
#
# USAGE:
#   ./deploy.sh                    # Uses hardcoded REMOTE_HOST/REMOTE_USER
#   REMOTE_HOST=server.com ./deploy.sh  # Override target server
#
# This script copies the entire Moodle-statistic project to a remote server
# and sets it up in /opt/moodle-crawler following Linux best practices.

# Fail fast and treat unset vars as errors
set -euo pipefail

# SSH options used for remote commands (centralized for consistency)
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"

# Settings - Use environment variables for security
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-root}"
SOURCE_DIR="$(pwd)"
REMOTE_BASE_DIR="/opt"
REMOTE_APP_DIR="${REMOTE_BASE_DIR}/moodle-crawler"

# Validate required environment variables
if [ -z "$REMOTE_HOST" ]; then
    echo "ERROR: REMOTE_HOST environment variable is required"
    echo "Usage: REMOTE_HOST=your-server.com REMOTE_USER=ubuntu $0"
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Remote execution helper function
remote_exec() {
    ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "$@"
}

echo -e "${BLUE}=== Moodle Crawler Deployment Script ===${NC}"
echo -e "${YELLOW}This script will deploy the Moodle crawler to ${REMOTE_USER}@${REMOTE_HOST}${NC}"
echo -e "${YELLOW}Source directory: ${SOURCE_DIR}${NC}"
echo -e "${YELLOW}Destination directory: ${REMOTE_APP_DIR}${NC}"
echo

# Check if ssh is available
if ! command -v ssh &> /dev/null; then
    echo -e "${RED}SSH is not installed. Please install SSH before continuing.${NC}"
    exit 1
fi

# Check if source directory exists and contains necessary files
if [ ! -f "${SOURCE_DIR}/moodle-crawler.py" ] || [ ! -f "${SOURCE_DIR}/run-crawler.sh" ]; then
    echo -e "${RED}Source directory doesn't appear to contain the Moodle crawler files.${NC}"
    echo -e "${RED}Please run this script from the Moodle-statistic directory.${NC}"
    exit 1
fi

# Check connection to server
echo -e "${BLUE}Checking connection to server...${NC}"
if ! ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "echo 2>&1"; then
    echo -e "${RED}Cannot connect to ${REMOTE_USER}@${REMOTE_HOST}.${NC}"
    echo -e "${RED}Please make sure the server is reachable and you have SSH access.${NC}"
    echo -e "${RED}You might need to add your SSH key to the server first:${NC}"
    echo -e "${YELLOW}ssh-copy-id ${REMOTE_USER}@${REMOTE_HOST}${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Connection successful${NC}"

# Create remote directory if it doesn't exist
echo -e "${BLUE}Creating remote directory structure...${NC}"
remote_exec "mkdir -p ${REMOTE_APP_DIR}"
echo -e "${GREEN}✓ Remote directory structure created${NC}"

# Copy files to remote server
echo -e "${BLUE}Copying files to remote server...${NC}"
rsync -avz --exclude 'venv' --exclude '__pycache__' --exclude '*.pyc' \
      "${SOURCE_DIR}/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_APP_DIR}/"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Files copied successfully${NC}"
else
    echo -e "${RED}Error copying files to remote server.${NC}"
    exit 1
fi

# Set appropriate permissions on the remote server
echo -e "${BLUE}Setting appropriate permissions...${NC}"
remote_exec "chmod +x ${REMOTE_APP_DIR}/run-crawler.sh ${REMOTE_APP_DIR}/moodle-crawler.py"
echo -e "${GREEN}✓ Permissions set${NC}"


# Create the moodle user and group
echo -e "${BLUE}Creating moodle user and group...${NC}"
remote_exec "id -u moodle &>/dev/null || useradd -r -s /bin/false moodle"
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ User moodle created or already exists${NC}"
else
    echo -e "${RED}Error creating user moodle. Please check manually.${NC}"
fi

# -- Safe fixes: ensure the moodle user can access and run the service
echo -e "${BLUE}Applying safe fixes: ownership and executable bits (service reload deferred)...${NC}"
remote_exec "
    # Ensure app dir is owned by moodle and is traversable
    if id -u moodle &>/dev/null; then
        chown -R moodle:moodle ${REMOTE_APP_DIR} || true
        chmod 755 ${REMOTE_APP_DIR} || true
        # Ensure data dir is writable by moodle
        mkdir -p ${REMOTE_APP_DIR}/data
        chown -R moodle:moodle ${REMOTE_APP_DIR}/data || true
    else
        echo 'User moodle does not exist on remote host; skipping chown steps'
    fi

    # Make sure the primary scripts are executable
    chmod +x ${REMOTE_APP_DIR}/run-crawler.sh || true
    chmod +x ${REMOTE_APP_DIR}/moodle-crawler.py || true
"

echo -e "${GREEN}✓ Safe fixes applied (best-effort)${NC}"

# Create the moodle user and group
echo -e "${BLUE}Creating moodle user and group...${NC}"
remote_exec "id -u moodle &>/dev/null || useradd -r -s /bin/false moodle"
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ User moodle created or already exists${NC}"
else
    echo -e "${RED}Error creating user moodle. Please check manually.${NC}"
fi

# Handle existing metrics files (safe backup: copy with timestamp)
echo -e "${BLUE}Managing metrics files (backing up existing files)...${NC}"
remote_exec "
    # Create necessary directories
    mkdir -p ${REMOTE_APP_DIR}/data

    TIMESTAMP=\$(date +%Y%m%d%H%M%S)

    # Backup main metrics file if it exists by copying with timestamp
    if [ -f ${REMOTE_APP_DIR}/data/metrics.prom ]; then
        cp -a ${REMOTE_APP_DIR}/data/metrics.prom ${REMOTE_APP_DIR}/data/metrics.prom.\${TIMESTAMP}.backup
        echo 'Backed up existing metrics.prom to metrics.prom.'\${TIMESTAMP}'.backup'
    fi

    # Backup any rotated metrics files to timestamped copies
    if [ -d ${REMOTE_APP_DIR}/data ]; then
        find ${REMOTE_APP_DIR}/data -name "metrics.prom.*" -type f | while read rotated_file; do
            filename=\$(basename "\$rotated_file")
            cp -a "\$rotated_file" "${REMOTE_APP_DIR}/data/\${filename}.\${TIMESTAMP}.backup"
            echo "Backed up \$filename to \${filename}.\${TIMESTAMP}.backup"
        done
    fi

    # Remove metrics_history.log as it's no longer used
    if [ -f ${REMOTE_APP_DIR}/data/metrics_history.log ]; then
        rm -f ${REMOTE_APP_DIR}/data/metrics_history.log
        echo 'Removed deprecated metrics_history.log'
    fi

    # Ensure a metrics.prom exists (do not overwrite existing file)
    if [ ! -f ${REMOTE_APP_DIR}/data/metrics.prom ]; then
        touch ${REMOTE_APP_DIR}/data/metrics.prom
    fi

    # Set proper permissions (best-effort)
    chown -R moodle:moodle ${REMOTE_APP_DIR}/data || true
    chmod -R 755 ${REMOTE_APP_DIR}/data || true
"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Data directory and metrics files backed up successfully${NC}"
else
    echo -e "${RED}Error managing metrics files. Please check manually.${NC}"
fi

# Install Python and dependencies on the remote server
echo -e "${BLUE}Ensuring Python 3 is installed on the remote server...${NC}"
remote_exec "DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-pip python3-venv"
if [ $? -ne 0 ]; then
    echo -e "${RED}Error installing Python 3. Please check manually.${NC}"
    echo -e "${YELLOW}Continuing with deployment anyway...${NC}"
fi

# Set up the Python virtual environment
echo -e "${BLUE}Setting up Python environment on the remote server...${NC}"
remote_exec "cd ${REMOTE_APP_DIR} && python3 -m venv venv"
if [ $? -ne 0 ]; then
    echo -e "${RED}Error creating virtual environment. Trying with default python command...${NC}"
    remote_exec "cd ${REMOTE_APP_DIR} && python -m venv venv"
fi

# Install required packages
echo -e "${BLUE}Installing Python packages...${NC}"
remote_exec "cd ${REMOTE_APP_DIR} && venv/bin/pip install --no-cache-dir -r requirements.txt"
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Python environment set up successfully${NC}"
else
    echo -e "${RED}Error installing Python packages. Please check manually.${NC}"
fi

# Reload systemd and restart the service now that dependencies are installed
echo -e "${BLUE}Reloading systemd and restarting service (if present)...${NC}"
remote_exec "
    if systemctl --no-pager status moodle-crawler &>/dev/null; then
        systemctl daemon-reload || true
        systemctl restart moodle-crawler || true
    else
        echo 'moodle-crawler service not found; skipping service restart'
    fi
"

# Health check: poll service status for a short period and fetch logs on failure
echo -e "${BLUE}Checking service health (polling for active state)...${NC}"
if remote_exec "bash -lc 'for i in {1..6}; do if systemctl is-active --quiet moodle-crawler; then echo OK; exit 0; fi; sleep 2; done; echo FAIL; exit 1'" ; then
    echo -e "${GREEN}✓ Service is active and running${NC}"
else
    echo -e "${RED}Service did not reach active state within timeout. Fetching recent journal entries...${NC}"
    echo -e "${YELLOW}Recent journal entries for moodle-crawler:${NC}"
    remote_exec "journalctl -u moodle-crawler -n 200 --no-pager || true"
    echo -e "${RED}Please inspect the logs above to determine why the service failed to start.${NC}"
fi

# Display post-deployment instructions
echo -e "\n${GREEN}=== Deployment Complete ===${NC}"
echo -e "${BLUE}The Moodle crawler has been deployed to ${REMOTE_APP_DIR} on the remote server.${NC}"
echo -e "\n${YELLOW}Next Steps:${NC}"
echo -e "${YELLOW}1. SSH into the server:${NC}"
echo -e "   ssh ${REMOTE_USER}@${REMOTE_HOST}"
echo -e "\n${YELLOW}2. Install as a service (recommended):${NC}"
echo -e "   cd ${REMOTE_APP_DIR}"
echo -e "   sudo ./scripts/deployment/install_service.sh"
echo -e "\n${YELLOW}3. Set up backup rotation (recommended):${NC}"
echo -e "   cd ${REMOTE_APP_DIR}"
echo -e "   sudo ./scripts/deployment/cleanup_and_setup.sh"
echo -e "\n${YELLOW}4. Or run manually:${NC}"
echo -e "   cd ${REMOTE_APP_DIR}"
echo -e "   ./run-crawler.sh https://solusi.sibermu.ac.id -p"
echo
echo -e "${YELLOW}Note: The metrics files are now automatically rotated with date-based filenames${NC}"
echo -e "${YELLOW}      when they reach 10MB in size (format: metrics.prom.YYYYMMDD.N)${NC}"
echo -e "${YELLOW}      Backups are preserved in /mnt/sibermu_data/rotated/ in a flat structure${NC}"
echo
echo -e "${BLUE}Thank you for using the Moodle Crawler Deployment Script${NC}"

echo -e "\n${BLUE}Quick health & troubleshooting commands:${NC}"
echo -e "# Check service status (remote): sudo systemctl status moodle-crawler -l"
echo -e "# Tail recent logs (remote): sudo journalctl -u moodle-crawler -f"
echo -e "# Show recent journal entries for debugging (remote): sudo journalctl -u moodle-crawler -n 200 --no-pager"
echo -e "# Check that metrics exist on remote (replace path if different): ls -lah ${REMOTE_APP_DIR}/data"
echo -e "# Show last lines of metrics and latency files (remote): tail -n 50 ${REMOTE_APP_DIR}/data/metrics.prom || true; tail -n 50 ${REMOTE_APP_DIR}/data/latency.prom || true"
