# Makefile for Moodle Crawler project

# Container runtime detection (default: podman)
CONTAINER_RUNTIME ?= $(shell which podman 2>/dev/null || which docker 2>/dev/null || echo "podman")

.PHONY: build build-go test test-go test-python clean run-python run-go deploy docker-deploy docker-build docker-push container-info sync-data help

# Build targets
build: build-go

build-go:
	go build -o build/moodle-crawler main.go

# Test targets
test: test-go test-python

test-go:
	go test -v ./...

test-python:
	python -m pytest test_extract.py -v

# Clean build artifacts
clean:
	rm -rf build/*
	rm -rf __pycache__
	rm -rf venv

# Run targets
run-python:
	./run-crawler.sh --verify

run-go:
	go run main.go --url=https://example.com --interval=60

# Deployment targets
deploy:
	./deploy.sh

docker-deploy:
	./deploy-docker.sh

# Development setup
setup:
	python3 -m venv venv
	./venv/bin/pip install -r requirements.txt

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
	@mkdir -p data/python data/docker
	@rsync -avz --progress --delete \
		-e "ssh -i $(SSH_KEY_PATH) -p $(REMOTE_PORT)" \
		$(REMOTE_USER)@$(REMOTE_HOST):$(PYTHON_DATA_DIR)/ data/python/ || echo "Warning: Failed to sync Python data"
	@rsync -avz --progress --delete \
		-e "ssh -i $(SSH_KEY_PATH) -p $(REMOTE_PORT)" \
		$(REMOTE_USER)@$(REMOTE_HOST):$(DOCKER_DATA_DIR)/ data/docker/ || echo "Warning: Failed to sync Docker data"
	@echo "✅ Data sync completed"

# Help target showing all available commands
help:
	@echo "🔧 Moodle Crawler - Simple Data Collection Tool"
	@echo "=============================================="
	@echo ""
	@echo "📋 SETUP COMMANDS:"
	@echo "  setup              Setup Python virtual environment"
	@echo ""
	@echo "🔄 DATA SYNCHRONIZATION:"
	@echo "  sync-data          Sync data from remote server"
	@echo ""
	@echo "🔨 BUILD & TEST:"
	@echo "  build              Build Go binary"
	@echo "  test               Run all tests (Go + Python)"
	@echo "  clean              Clean build artifacts"
	@echo ""
	@echo "🚀 RUN CRAWLERS:"
	@echo "  run-python         Run Python crawler locally"
	@echo "  run-go             Run Go crawler locally"
	@echo ""
	@echo "🐳 CONTAINER OPERATIONS:"
	@echo "  docker-build       Build container image locally"
	@echo "  docker-push        Push to container registry"
	@echo "  container-info     Show container runtime"
	@echo ""
	@echo "☁️  DEPLOYMENT:"
	@echo "  deploy             Deploy Python version to remote server"
	@echo "  docker-deploy      Deploy container to remote server"
