# The CI runner image: GitHub's official runner plus the build tools the private repositories'
# workflows assume a GitHub-hosted Ubuntu runner has. Built by `make runner-image` and pushed
# to the cluster registry; bump RUNNER_VERSION in the Makefile to update it.
ARG RUNNER_VERSION
ARG RUNNER_DIGEST
FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}@${RUNNER_DIGEST}

USER root
# gcc for cgo (go test -race needs it), make for Makefile-driven jobs, unzip and xz for tool
# archives that setup-* actions and scripts download, openssl for generated secrets, and the
# Compose plugin (`docker compose`), which GitHub's image leaves out and Docker's apt repository
# provides. The packages are the current ones at build time; `docker push` prints the image
# digest, which is what identifies a build.
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends build-essential unzip xz-utils openssl docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*
USER runner

# The actions the repositories' workflows use, fetched by `make action-cache` (scripts/action-cache.sh)
# into the build context. The runner looks for <owner>_<repo>/<sha>.tar.gz here before it downloads
# an action, so jobs stop asking codeload.github.com, whose anonymous limit runners behind one
# address exhaust together (429). An action not here is downloaded as before.
COPY action-cache/ /home/runner/action-archive-cache/
ENV ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE=/home/runner/action-archive-cache
