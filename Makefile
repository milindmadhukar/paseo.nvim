# `ws` is one static binary so that any agent, in any sandbox, can call it.
PREFIX ?= $(HOME)/.local
BIN    ?= $(PREFIX)/bin

.PHONY: build install test test-go test-lua fmt clean

build:
	go build -o dist/ws ./cmd/ws

install:
	go build -o $(BIN)/ws ./cmd/ws
	@echo "installed $(BIN)/ws"

test: test-go test-lua

test-go:
	go test ./...

test-lua:
	./tests/run.sh

fmt:
	gofmt -w .
	stylua .

clean:
	rm -rf dist
