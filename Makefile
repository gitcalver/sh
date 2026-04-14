# Copyright © 2026 Michael Shields
# SPDX-License-Identifier: MIT

SH_FILES := gitcalver.sh test/test.sh test/install-git.sh

LINUX_SERVICES := debian-12 debian-13 \
	ubuntu-22.04 ubuntu-25.10 \
	alpine-3.21 alpine-3.23 \
	fedora-42 fedora-43 \
	amazon-linux-2 amazon-linux-2023

.PHONY: build test test-local test-docker lint fmt

build:

test: test-local test-docker

test-local:
	./test/test.sh

test-docker:
	docker compose -f test/docker-compose.yml up --build --abort-on-container-failure $(LINUX_SERVICES)

lint:
	shellcheck $(SH_FILES)

fmt:
	shfmt -w $(SH_FILES)
