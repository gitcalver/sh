# Copyright © 2026 Michael Shields
# SPDX-License-Identifier: MIT

SH_FILES := gitcalver.sh action/publish.sh test/test.sh test/action.sh test/install-git.sh

.PHONY: build test test-local test-docker lint fmt

build:

test: test-local test-docker

test-local:
	./test/test.sh
	./test/action.sh

test-docker:
	docker compose -f test/docker-compose.yml up --build --abort-on-container-failure

lint: actions-lock-verify-local
	shellcheck $(SH_FILES)

fmt:
	shfmt -w $(SH_FILES)

.PHONY: actions-lock-install actions-lock actions-lock-verify-local actions-lock-verify

actions-lock-install:
	gh extension install github/gh-actions-lock --pin v0.5.1 --force

actions-lock:
	gh actions-lock --no-interactive

actions-lock-verify-local:
	gh actions-lock --verify-local

actions-lock-verify:
	gh actions-lock --verify
