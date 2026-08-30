# Makefile for Moodle Crawler project

# Container runtime detection (default: podman)
CONTAINER_RUNTIME ?= $(shell which podman 2>/dev/null || which docker 2>/dev/null || echo "podman")

.PHONY: build build-go test test-go clean run-go deploy docker-deploy docker-build docker-push container-info sync-data help

# Build targets
build: build-go

build-go:
	go build -o build/moodle-crawler main.go

# Test targets
test: test-go

test-go:
	go test -v ./...

# Clean build artifacts
clean:
	rm -rf build/*

# Run targets
run-go:
	go run main.go --url=https://example.com --interval=60

# Deployment targets
deploy:
	./deploy.sh

docker-deploy:
	./deploy-docker.sh

# Container build (for local testing)
docker-build:
	$(CONTAINER_RUNTIME) build -t moodle-crawler:latest .

# Container push to registry
docker-push:
	$(CONTAINER_RUNTIME) tag moodle-crawler:latest registry.digitalocean.com/sibermu/moodle-crawler:latest
	$(CONTAINER_RUNTIME) push registry.digitalocean.com/sibermu/moodle-crawler:latest

# Show detected container runtime
container-info:
	@echo "Using container runtime: $(CONTAINER_RUNTIME)"
	@$(CONTAINER_RUNTIME) --version 2>/dev/null || echo "Warning: $(CONTAINER_RUNTIME) not found"

# Data synchronization from remote server
# Set REMOTE_HOST/REMOTE_USER etc. in the environment or a local .env file
# (do NOT commit credentials). Example:
#   make sync-data REMOTE_HOST=host REMOTE_USER=user SSH_KEY_PATH=~/.ssh/id_rsa
sync-data:
	@echo "📊 Syncing data from remote server..."
	@mkdir -p data
	@rsync -avz --progress --delete \
		-e "ssh -i $(SSH_KEY_PATH) -p $(REMOTE_PORT)" \
		$(REMOTE_USER)@$(REMOTE_HOST):$(DATA_DIR)/ data/ || echo "Warning: Failed to sync data"
	@echo "✅ Data sync completed"

# Help target showing all available commands
help:
	@echo "🔧 Moodle Crawler - Simple Data Collection Tool (Go)"
	@echo "===================================================="
	@echo ""
	@echo "🔄 DATA SYNCHRONIZATION:"
	@echo "  sync-data          Sync data from remote server"
	@echo ""
	@echo "🔨 BUILD & TEST:"
	@echo "  build              Build Go binary"
	@echo "  test               Run Go tests"
	@echo "  clean              Clean build artifacts"
	@echo ""
	@echo "🚀 RUN CRAWLER:"
	@echo "  run-go             Run Go crawler locally"
	@echo ""
	@echo "🐳 CONTAINER OPERATIONS:"
	@echo "  docker-build       Build container image locally"
	@echo "  docker-push        Push to container registry"
	@echo "  container-info     Show container runtime"
	@echo ""
	@echo "☁️  DEPLOYMENT:"
	@echo "  deploy             Deploy Go binary to remote server (systemd)"
	@echo "  docker-deploy      Deploy container to remote server"
