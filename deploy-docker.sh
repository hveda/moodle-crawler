#!/usr/bin/env bash
set -euo pipefail

# deploy-docker.sh - Remote Container Deployment Script for Moodle Crawler
#
# REMOTE DEPLOYMENT: This script deploys the Moodle crawler as a containerized
# systemd service to a remote server via SSH. It handles:
# - Container runtime installation (Podman/Docker)
# - Image pulling from registry
# - User/group creation and permissions
# - Systemd service installation and startup
# - Volume mounting for data persistence
#
# REQUIREMENTS:
# - SSH access to remote server (passwordless key-based auth recommended)
# - Target server: Ubuntu/Debian/RHEL with systemd
# - Remote user with sudo privileges (typically 'root')
# - Container registry access (if using private registry)
#
# USAGE:
#   ./deploy-docker.sh --remote-host server.com --remote-user root
#   ./deploy-docker.sh --dry-run  # Preview actions without execution
#
# Deploy the containerized Moodle crawler as a systemd-managed service.
# Supports both Podman (default) and Docker runtimes with automatic installation.

PROGNAME=$(basename "$0")

# Load environment variables from .env files if they exist
if [ -f ".env.production" ]; then
    set -a  # automatically export all variables
    source .env.production
    set +a
elif [ -f ".env" ]; then
    set -a
    source .env
    set +a
fi

# Configuration with environment variable defaults
IMAGE="${REGISTRY_URL:-registry.digitalocean.com/sibermu/moodle-crawler:latest}"
SERVICE_NAME=moodle-crawler-docker.service
SERVICE_SRC=./config/systemd/moodle-crawler-docker.service
DATA_DIR="${DATA_DIR:-/opt/moodle-crawler-docker/data}"
USER_OWNER="${SERVICE_USER:-moodle}"
DOCKER_CONFIG_SRC="./config/docker/docker-config.json"
DOCKER_CONFIG_DEST="/root/.docker/config.json"
DRY_RUN=false
RUNTIME="${CONTAINER_RUNTIME:-podman}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-root}"

# If runtime is docker, the script will ensure docker is installed; otherwise it
# prefers podman when available. Use --runtime to override to 'podman' or 'docker'.

usage() {
  cat <<EOF
Usage: $PROGNAME [options]

REMOTE DEPLOYMENT OPTIONS:
  --remote-host <host>      Remote server hostname/IP (required for remote deployment)
  --remote-user <user>      Remote SSH user (default: $REMOTE_USER)

CONTAINER OPTIONS:
  --image <image>           Docker image to run (default: $IMAGE)
  --service-src <path>      Path to unit file to install (default: $SERVICE_SRC)
  --service-name <name>     Systemd unit name (default: $SERVICE_NAME)
  --data-dir <path>         Host data directory to mount (default: $DATA_DIR)
  --user <user>             Owner for data dir (default: $USER_OWNER)
  --runtime <podman|docker> Force container runtime to use (default: auto-detect)
  --dry-run                 Print actions without performing them
  -h, --help                Show this help

Examples:
  # Deploy to remote server (RECOMMENDED)
  $PROGNAME --remote-host server.example.com --remote-user root

  # Deploy with custom image and runtime
  $PROGNAME --remote-host 192.168.1.100 --runtime docker --image custom/crawler:latest

  # Preview deployment actions (dry run)
  $PROGNAME --remote-host server.com --dry-run

NOTE: This script is designed for REMOTE deployment. It will deploy the containerized
service to the specified remote server via SSH, not to the local machine.
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      IMAGE=$2; shift 2;;
    --service-src)
      SERVICE_SRC=$2; shift 2;;
    --service-name)
      SERVICE_NAME=$2; shift 2;;
    --data-dir)
      DATA_DIR=$2; shift 2;;
    --user)
      USER_OWNER=$2; shift 2;;
    --runtime)
      RUNTIME=$2; shift 2;;
    --remote-host)
      REMOTE_HOST=$2; shift 2;;
    --remote-user)
      REMOTE_USER=$2; shift 2;;
      --docker-config-src)
        DOCKER_CONFIG_SRC=$2; shift 2;;
      --docker-config-dest)
        DOCKER_CONFIG_DEST=$2; shift 2;;
    
    --dry-run)
      DRY_RUN=true; shift;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

log() { echo "[deploy] $*"; }
run() {
  if [ "$DRY_RUN" = true ]; then
    echo "DRY-RUN: $*"
  else
    eval "$@"
  fi
}

# Validate required parameters for remote deployment
if [ -n "$REMOTE_HOST" ] && [ -z "$REMOTE_HOST" ]; then
    echo "ERROR: REMOTE_HOST is required for remote deployment"
    echo "Usage: $PROGNAME --remote-host your-server.com --remote-user root"
    exit 1
fi

# Runtime selection and preconditions
# If runtime not provided, prefer podman if present, otherwise docker if present.
if [ -z "$RUNTIME" ]; then
  if command -v podman >/dev/null 2>&1; then
    RUNTIME=podman
  elif command -v docker >/dev/null 2>&1; then
    RUNTIME=docker
  else
    # default to podman; installation will be required if not present
    RUNTIME=podman
  fi
fi

log "Selected container runtime: $RUNTIME"

if [ "$RUNTIME" = "podman" ]; then
  if ! command -v podman >/dev/null 2>&1; then
    echo "podman not found. Attempting to install Podman (apt or brew)."
    if [ "$DRY_RUN" = true ]; then
      echo "DRY-RUN: apt-get update && apt-get install -y podman || brew install podman"
    else
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y podman
      elif command -v brew >/dev/null 2>&1; then
        brew install podman
      else
        echo "Automatic Podman installation not supported on this OS by this script. Install podman manually and re-run." >&2
        exit 1
      fi
    fi
    # verify installation
    if ! command -v podman >/dev/null 2>&1; then
      echo "podman still not available after install attempt; please install it manually and re-run." >&2
      exit 1
    fi
  fi
fi

if [ "$RUNTIME" = "docker" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker not found. Attempting to install Docker (apt-based systems)."
    if [ "$DRY_RUN" = true ]; then
      echo "DRY-RUN: apt-get update && apt-get install -y docker.io"
    else
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y docker.io
        systemctl enable --now docker.service
      else
        echo "Automatic Docker installation not supported on this OS by this script. Install docker manually and re-run." >&2
        exit 1
      fi
    fi
  fi
fi

# We always generate a runtime-flavored unit inside the script. SERVICE_SRC may
# be used if the operator wants to provide a custom unit, but by default we
# generate a Podman-friendly unit below.

# Note: image pull and service install are performed on the remote host below

# If remote host provided, perform remote deployment (rsync files and install unit)
if [ -n "$REMOTE_HOST" ]; then
  if ! command -v ssh >/dev/null 2>&1; then
    echo "ssh client is required for remote deployment" >&2
    exit 1
  fi

  SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PasswordAuthentication=no -o ChallengeResponseAuthentication=no -o GSSAPIAuthentication=no"

  log "Checking SSH connectivity to ${REMOTE_USER}@${REMOTE_HOST}"
  if [ "$DRY_RUN" = true ]; then
    echo "DRY-RUN: ssh ${REMOTE_USER}@${REMOTE_HOST} echo connected"
  else
    if ! ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "echo connected" >/dev/null 2>&1; then
      echo "Cannot SSH to ${REMOTE_USER}@${REMOTE_HOST}. Aborting." >&2
      exit 1
    fi
  fi

  # Ensure remote data dir exists (we don't rsync the repo when only running the image)
  log "Ensuring remote data directory exists: ${DATA_DIR} on ${REMOTE_USER}@${REMOTE_HOST}"

  # Ensure runtime exists on remote (install via apt if docker/podman requested)
  if [ "$DRY_RUN" = true ]; then
    echo "DRY-RUN: ssh ${REMOTE_USER}@${REMOTE_HOST} [check runtime]"
  else
    # Try installing podman (or docker only if explicitly requested) using
    # common package managers. This is best-effort; if the remote host uses a
    # different OS, the operator should install the runtime manually.
    if [ "$RUNTIME" = "podman" ]; then
      ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "command -v podman >/dev/null 2>&1 || (command -v apt-get >/dev/null 2>&1 && apt-get update && apt-get install -y podman) || (command -v dnf >/dev/null 2>&1 && dnf -y install podman) || (command -v yum >/dev/null 2>&1 && yum -y install podman) || (command -v brew >/dev/null 2>&1 && brew install podman)"
    elif [ "$RUNTIME" = "docker" ]; then
      ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "command -v docker >/dev/null 2>&1 || (command -v apt-get >/dev/null 2>&1 && apt-get update && apt-get install -y docker.io && systemctl enable --now docker) || (command -v dnf >/dev/null 2>&1 && dnf -y install docker) || (command -v yum >/dev/null 2>&1 && yum -y install docker)"
    fi
  fi
  # Pull image on remote host
  # If the operator provided a docker/podman config locally, upload it to the
  # remote host before pulling images so private registries are accessible.
  if [ -z "$DOCKER_CONFIG_SRC" ]; then
    # auto-detect common filenames
    if [ -f ./config/docker/docker-config.json ]; then
      DOCKER_CONFIG_SRC=./config/docker/docker-config.json
    fi
  fi

  if [ -n "$DOCKER_CONFIG_SRC" ]; then
    # Default remote destination depends on runtime
    if [ -z "$DOCKER_CONFIG_DEST" ]; then
      if [ "$RUNTIME" = "podman" ]; then
        DOCKER_CONFIG_DEST="/etc/containers/registries.conf"
      else
        DOCKER_CONFIG_DEST="/root/.docker/config.json"
      fi
    fi

    log "Uploading docker config $DOCKER_CONFIG_SRC to ${REMOTE_USER}@${REMOTE_HOST}:$DOCKER_CONFIG_DEST"
    if [ "$DRY_RUN" = true ]; then
      echo "DRY-RUN: scp ${DOCKER_CONFIG_SRC} ${REMOTE_USER}@${REMOTE_HOST}:/tmp/docker-config.tmp && ssh ${REMOTE_USER}@${REMOTE_HOST} 'mkdir -p \$(dirname $DOCKER_CONFIG_DEST) && mv /tmp/docker-config.tmp $DOCKER_CONFIG_DEST && chown root:root $DOCKER_CONFIG_DEST && chmod 600 $DOCKER_CONFIG_DEST'"
    else
      scp ${DOCKER_CONFIG_SRC} ${REMOTE_USER}@${REMOTE_HOST}:/tmp/docker-config.tmp
      ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "mkdir -p \$(dirname $DOCKER_CONFIG_DEST) && mv /tmp/docker-config.tmp $DOCKER_CONFIG_DEST && chown root:root $DOCKER_CONFIG_DEST && chmod 600 $DOCKER_CONFIG_DEST"
    fi
  fi

  log "Pulling image $IMAGE on remote host with $RUNTIME"
  if [ "$DRY_RUN" = true ]; then
    echo "DRY-RUN: ssh ${REMOTE_USER}@${REMOTE_HOST} \"${RUNTIME} pull ${IMAGE}\""
  else
    ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "${RUNTIME} pull ${IMAGE}"
  fi

  # Create moodle user and data dir on remote, set ownership
  log "Preparing remote user and data directory with robust permissions"
  if [ "$DRY_RUN" = true ]; then
    echo "DRY-RUN: ssh ${REMOTE_USER}@${REMOTE_HOST} 'Create moodle user, setup data dir with nobody permissions, verify write access, handle SELinux'"
  else
    ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "
      # Create moodle user for service management (not for container execution)
      getent group ${USER_OWNER} >/dev/null 2>&1 || groupadd -r ${USER_OWNER} || true
      id -u ${USER_OWNER} >/dev/null 2>&1 || useradd -r -g ${USER_OWNER} -s /usr/sbin/nologin ${USER_OWNER} || true

      # Create data directory with proper permissions for container nobody user
      [ -d ${DATA_DIR} ] || mkdir -p ${DATA_DIR}

      # Set ownership to nobody:nobody (65534:65534) so container can write
      chown -R 65534:65534 ${DATA_DIR}

      # Set directory permissions: owner can read/write/execute
      chmod 755 ${DATA_DIR}

      # Ensure any existing files are writable by the container user
      find ${DATA_DIR} -type f -exec chmod 644 {} \; 2>/dev/null || true

      # Verify write permissions by testing with the nobody user
      echo 'Testing write permissions for container user (65534:65534)...'
      if runuser -u '#65534' -g '#65534' -- touch ${DATA_DIR}/test-write.tmp 2>/dev/null; then
        rm -f ${DATA_DIR}/test-write.tmp
        echo '✓ Write permissions verified for container user 65534:65534'
      else
        echo '✗ WARNING: User 65534:65534 cannot write to ${DATA_DIR}'
        echo '  Attempting SELinux context fixes...'

        # Handle SELinux contexts if SELinux is enforcing
        if command -v getenforce >/dev/null 2>&1 && [ \"\$(getenforce)\" = \"Enforcing\" ]; then
          echo '  SELinux is enforcing, setting container_file_t context...'
          semanage fcontext -a -t container_file_t \"${DATA_DIR}(/.*)?\" 2>/dev/null || true
          restorecon -R ${DATA_DIR} 2>/dev/null || true

          # Test again after SELinux fix
          if runuser -u '#65534' -g '#65534' -- touch ${DATA_DIR}/test-write.tmp 2>/dev/null; then
            rm -f ${DATA_DIR}/test-write.tmp
            echo '✓ Write permissions verified after SELinux context fix'
          else
            echo '✗ WARNING: Permission issues persist after SELinux fix'
            echo '  Check filesystem mount options and ownership manually'
          fi
        else
          echo '  SELinux not enforcing, check filesystem mount options and ownership'
        fi
      fi
    "
  fi

  # Build or reuse a systemd unit for the selected runtime. If the operator
  # supplied a custom unit via --service-src, use that. Otherwise generate a
  # runtime-specific unit under /tmp/<service> and install that.
  SERVICE_SRC_USE="$SERVICE_SRC"
  GENERATED_UNIT="/tmp/${SERVICE_NAME}"
  if [ -f "$SERVICE_SRC" ]; then
    log "Using provided service unit: $SERVICE_SRC"
    SERVICE_SRC_USE="$SERVICE_SRC"
  else
    log "Generating ${RUNTIME}-flavored systemd unit at ${GENERATED_UNIT}"
      if [ "$DRY_RUN" = true ]; then
        echo "DRY-RUN: generate ${RUNTIME} unit at ${GENERATED_UNIT}"
      else
        # Choose the full path to the runtime binary. Fall back to the name
        # (e.g. 'podman' or 'docker') if /usr/bin/<runtime> doesn't exist.
        case "$RUNTIME" in
          podman)
            RUNTIME_BIN="/usr/bin/podman"
            ;;
          docker)
            RUNTIME_BIN="/usr/bin/docker"
            ;;
          *)
            RUNTIME_BIN="$RUNTIME"
            ;;
        esac

  [...previous code...]
  PRE_CMD="-REPLACE_RUNTIME_BIN rm -f \${CONTAINER_NAME}"
  # Mount host DATA_DIR into /app/data inside the container with security options
  # Container runs as nobody (65534:65534) for security
  START_CMD="REPLACE_RUNTIME_BIN run --name \${CONTAINER_NAME} --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges:true --user=65534:65534 --memory=128m --cpus=0.5 --pids-limit=100 -p 127.0.0.1:9100:9100 -v \${DATA_DIR}:/app/data:Z --tmpfs /tmp:rw,noexec,nosuid,size=10m \${IMAGE} --url \${URL} --interval \${INTERVAL} --output-dir /app/data --prometheus=true"
  STOP_CMD="REPLACE_RUNTIME_BIN stop -t 10 \${CONTAINER_NAME}"

    cat > "${GENERATED_UNIT}" <<'UNIT'
[Unit]
Description=Moodle Crawler (containerized - ${RUNTIME})
Documentation=README.md
After=network-online.target
Wants=network-online.target

[Service]
# Configurable environment variables (can be overridden with a drop-in)
Environment="IMAGE=${IMAGE}"
Environment="CONTAINER_NAME=moodle-crawler"
Environment="DATA_DIR=${DATA_DIR}"
Environment="URL=https://solusi.sibermu.ac.id/"
Environment="INTERVAL=60"

# Ensure any previous container with the same name is removed before starting
  ExecStartPre=${PRE_CMD}

  # Run the container in the foreground so systemd can supervise it.
  # The container publishes the internal health HTTP endpoint on 127.0.0.1:9100
  ExecStart=${START_CMD}
  ExecStop=${STOP_CMD}

# Let systemd restart on failure
Restart=on-failure
RestartSec=10
TimeoutStopSec=30

# Send container stdout/stderr to the journal
StandardOutput=journal
StandardError=journal

# Run the container process as the configured user to match non-container unit
User=${USER_OWNER}
Group=${USER_OWNER}

[Install]
WantedBy=multi-user.target
UNIT
      # Replace the runtime placeholder with the real path
      sed -i.bak "s|REPLACE_RUNTIME_BIN|${RUNTIME_BIN}|g" "${GENERATED_UNIT}" || true
      SERVICE_SRC_USE="${GENERATED_UNIT}"
      fi
  fi

  # Install the selected/generated unit on the remote host
  log "Installing systemd unit on remote: ${SERVICE_NAME}"

  # Check if the service unit already has a volume mount for /app/data
  # Look for patterns like: -v ${DATA_DIR}:/app/data or -v /some/path:/app/data
  if grep -qE "(-v\s+[^[:space:]]+:/app/data|--volume\s+[^[:space:]]+:/app/data)" "${SERVICE_SRC_USE}" 2>/dev/null; then
    log "Service unit already contains volume mount for /app/data; no changes needed"
  else
    log "Service unit missing volume mount for /app/data; injecting bind mount into ExecStart"
    if [ "$DRY_RUN" = true ]; then
      echo "DRY-RUN: modify ${SERVICE_SRC_USE} to add -v ${DATA_DIR}:/app/data:Z to ExecStart"
    else
      # Backup and modify the ExecStart line(s) that contain ' run ' to add the -v mount.
      cp "${SERVICE_SRC_USE}" "${SERVICE_SRC_USE}.orig" || true
      sed -i.bak "/ExecStart.*run/ s/run /run -v ${DATA_DIR//\//\\\/}:\/app\/data:Z /" "${SERVICE_SRC_USE}" || true
    fi
  fi
  if [ "$DRY_RUN" = true ]; then
    echo "DRY-RUN: scp ${SERVICE_SRC_USE} ${REMOTE_USER}@${REMOTE_HOST}:/tmp/${SERVICE_NAME} && ssh ${REMOTE_USER}@${REMOTE_HOST} 'mv /tmp/${SERVICE_NAME} /etc/systemd/system/${SERVICE_NAME} && chown root:root /etc/systemd/system/${SERVICE_NAME} && chmod 644 /etc/systemd/system/${SERVICE_NAME} && systemctl daemon-reload && systemctl enable --now ${SERVICE_NAME}'"
  else
    scp ${SERVICE_SRC_USE} ${REMOTE_USER}@${REMOTE_HOST}:/tmp/${SERVICE_NAME}
    ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "mv /tmp/${SERVICE_NAME} /etc/systemd/system/${SERVICE_NAME} && chown root:root /etc/systemd/system/${SERVICE_NAME} && chmod 644 /etc/systemd/system/${SERVICE_NAME} && systemctl daemon-reload && systemctl enable --now ${SERVICE_NAME}"
  fi

  log "Remote deployment complete. Check remote service status via: ssh ${REMOTE_USER}@${REMOTE_HOST} 'systemctl status ${SERVICE_NAME}'"
fi

# Note: data directory is created and permissioned on the remote host (see above).

log "Remote deployment complete. Check remote service status via: ssh ${REMOTE_USER}@${REMOTE_HOST} 'systemctl status ${SERVICE_NAME}'"

log "Deploy complete"

exit 0
