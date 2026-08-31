# Moodle Crawler — Go build & dev targets
# Production deploys via deploy.sh (native binary + systemd), not containers.

.PHONY: build test vet fmt clean run deploy help

build:
	go build -o build/moodle-crawler .

test:
	go test -v ./...

vet:
	go vet ./...

fmt:
	gofmt -l -w .

clean:
	rm -rf build

run:
	go run . --url=https://example.com --interval=60

deploy:
	./deploy.sh

help:
	@echo "build   — compile static binary to build/moodle-crawler"
	@echo "test    — run go tests"
	@echo "vet     — go vet"
	@echo "fmt     — gofmt (write)"
	@echo "clean   — remove build/"
	@echo "run     — run locally against example.com"
	@echo "deploy  — deploy via deploy.sh (systemd)"
