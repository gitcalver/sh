# Copyright © 2026 Michael Shields
# SPDX-License-Identifier: MIT

ARG BASE
FROM ${BASE}

COPY test/install-git.sh /tmp/
ARG SNAPSHOT
RUN sh /tmp/install-git.sh "${SNAPSHOT}" && rm /tmp/install-git.sh

WORKDIR /work
COPY gitcalver.sh ./
COPY test/test.sh test/

CMD ["sh", "test/test.sh"]
