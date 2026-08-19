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

lint:
	shellcheck $(SH_FILES)

fmt:
	shfmt -w $(SH_FILES)
