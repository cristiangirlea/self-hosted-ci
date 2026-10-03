# Day-to-day entry points. Run from Git Bash or any shell with GNU make; every target is idempotent.
#
# Your values live in config.mk (git-ignored; copy config.mk.example): the GitHub owner, the
# repositories that get runners, and the lab domain. A repository that builds on this one keeps its
# own config file and points at it:  make -C vendor/self-hosted-ci CONFIG=$PWD/config.mk up
CONFIG ?= config.mk
-include $(CONFIG)
CLUSTER ?= lab
# A wildcard name that resolves to 127.0.0.1 (tofu/ can create it in Cloudflare). The default
# resolves nowhere, which is fine: `make verify` resolves the name itself.
DOMAIN  ?= lab.example.test
# Runtime files (TLS certificate, backups); set DATA in the config to keep them elsewhere.
DATA    ?= .data
TLS_DIR := $(DATA)/tls
# Every kubectl call names the cluster explicitly: a stray current-context must never receive these.
KUBECTL := kubectl --context k3d-$(CLUSTER)
# Docker on Windows wants a Windows-style path for a bind mount; MSYS would mangle a POSIX one.
HOST_DATA := $(shell cygpath -m "$(abspath $(DATA))" 2>/dev/null || echo "$(abspath $(DATA))")

# winget installs each portable package into its own folder and adds it to the user PATH; a
# shell opened before `make tools` ran does not have them yet, so add them here as well.
WINGET_PKGS := $(LOCALAPPDATA)/Microsoft/WinGet/Packages
export PATH := $(PATH):$(LOCALAPPDATA)/Programs/lab-tools/bin:$(subst $() $(),:,$(wildcard $(WINGET_PKGS)/*/ $(WINGET_PKGS)/*/*/))

.PHONY: tools wsl-cap up down status tls hello verify lint arc runner-image runner-node runners runners-lint runners-status fork-approval config-check scrub

# P2, CI runners. Versions pinned here and nowhere else: the controller and scale-set charts move
# together, and the runner image is GitHub's runner plus build tools (runners/image/Dockerfile).
ARC_VERSION    := 0.14.2
ARC_CHART      := oci://ghcr.io/actions/actions-runner-controller-charts
RUNNER_VERSION := 2.337.0
# Bumped whenever runners/image/Dockerfile changes: nodes keep an image they already pulled under
# the same tag, so a rebuild needs a tag they have not seen.
RUNNER_IMAGE   := ci-runner:$(RUNNER_VERSION)-2
# Digests pin what the tags pointed at when they were checked (2026-09-30), so a re-pushed tag
# cannot change the build. Update the version and the digest together.
RUNNER_DIGEST  := sha256:e5496277be5d09bc968b3d64911b74e219ac4a3f2edce956a3ecf9271bea1ef4
DIND_VERSION   := 29.2.1
DIND_DIGEST    := sha256:68f6d9ab84623d1116c5432a3b924a07ee09960e6129ca1cb03ef14010588cb4
# The one node CI runners use; `make runner-node` taints it so nothing else is scheduled there.
RUNNER_NODE    := k3d-$(CLUSTER)-agent-1
# From config.mk. The repositories whose Linux jobs run here; the GitHub App must be installed on
# each. PUBLIC_REPOS are the public ones among them: a run from a fork's pull request would execute
# a stranger's code on these runners, so `make fork-approval` makes each such run wait for approval.
GITHUB_OWNER   ?=
REPOS          ?=
PUBLIC_REPOS   ?=
RUNNER_NS      := arc-runners
# Each repo's scale set is named $(RUNNER_PREFIX)-<repo>: the chart names its namespaced
# resources after the scale set, so two sets with one name in one namespace collide.
RUNNER_PREFIX  := lab
HELM           := helm --kube-context k3d-$(CLUSTER)

## tools: install the pinned tool versions (winget, plus k3d and sops from GitHub releases).
tools:
	powershell -NoProfile -ExecutionPolicy Bypass -File tools/install.ps1

## wsl-cap: apply the WSL memory/CPU ceilings from tools/wslconfig. Restarts WSL, which stops
## EVERY Docker container on the machine (they come back only if they have a restart policy).
wsl-cap:
	@test ! -f "$(USERPROFILE)/.wslconfig" || { cp "$(USERPROFILE)/.wslconfig" "$(USERPROFILE)/.wslconfig.bak"; echo "existing .wslconfig saved as .wslconfig.bak"; }
	@echo "containers running now: $$(docker ps -q | wc -l) (all of them stop during the restart)"
	cp tools/wslconfig "$(USERPROFILE)/.wslconfig"
	wsl --shutdown
	@echo "WSL stopped; Docker Desktop restarts its engine on the next docker command (wait ~30 s)."

## up: create the cluster from cluster/k3d.yaml if it does not exist, start it if stopped, wait for Traefik.
up:
	@mkdir -p $(DATA)/backups
	@k3d cluster list $(CLUSTER) >/dev/null 2>&1 || k3d cluster create --config cluster/k3d.yaml --volume "$(HOST_DATA)/backups:/backups@all"
	@k3d cluster start $(CLUSTER) >/dev/null 2>&1 || true
	@# Right after a create or start the API can refuse connections for a few seconds.
	@n=0; until $(KUBECTL) get nodes 2>/dev/null; do n=$$((n+1)); test $$n -le 30 || { echo "the API at k3d-$(CLUSTER) did not answer within 60 s"; exit 1; }; sleep 2; done
	@# k3s installs Traefik a few seconds after the nodes are Ready; `make tls` needs its CRDs.
	@n=0; until $(KUBECTL) get crd tlsstores.traefik.io >/dev/null 2>&1; do n=$$((n+1)); test $$n -le 90 || { echo "Traefik CRDs did not appear within 3 minutes; inspect: $(KUBECTL) -n kube-system get jobs,pods"; exit 1; }; sleep 2; done
	$(KUBECTL) -n kube-system rollout status deploy/traefik --timeout=180s
	kubectl config use-context k3d-$(CLUSTER)

## down: delete the cluster (persistent volumes and the registry's blobs survive in named Docker volumes).
down:
	k3d cluster delete $(CLUSTER)

status:
	k3d cluster list
	$(KUBECTL) get nodes -o wide
	$(KUBECTL) get pods -A

## tls: wildcard certificate from the mkcert local CA, installed as Traefik's default certificate.
tls:
	@mkdir -p $(TLS_DIR)
	@test -f $(TLS_DIR)/wildcard.pem -a -f $(TLS_DIR)/wildcard-key.pem || mkcert -cert-file $(TLS_DIR)/wildcard.pem -key-file $(TLS_DIR)/wildcard-key.pem "*.$(DOMAIN)" "$(DOMAIN)"
	$(KUBECTL) -n kube-system create secret tls lab-wildcard-tls --cert=$(TLS_DIR)/wildcard.pem --key=$(TLS_DIR)/wildcard-key.pem --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) apply -k infrastructure/traefik

## hello: the smoke-test application behind the ingress, its hostname filled in from DOMAIN.
hello: lint
	$(KUBECTL) kustomize apps/hello/local | sed 's/hello\.lab\.example\.test/hello.$(DOMAIN)/g' | $(KUBECTL) apply -f -
	$(KUBECTL) -n hello rollout status deploy/hello --timeout=120s

## lint: the hello ingress carries the placeholder host that `make hello` replaces.
lint:
	@grep -q "hello\.lab\.example\.test" apps/hello/local/ingress.yaml || { echo "apps/hello/local/ingress.yaml must use the placeholder hello.lab.example.test"; exit 1; }

## verify: reach the hello app through Traefik over TLS, resolving the name locally (works before DNS exists).
# Windows curl builds use Schannel, which rejects a CA that publishes no revocation list unless told
# otherwise. Recursively expanded, so `curl --version` runs only when this target does.
CURL_FLAGS = $(if $(findstring Schannel,$(shell curl --version 2>/dev/null)),--ssl-revoke-best-effort,)
# Traefik takes a few seconds to load a new default certificate, so the check retries for up to 30 s.
verify: lint
	@n=0; until curl -sS $(CURL_FLAGS) --resolve hello.$(DOMAIN):443:127.0.0.1 --cacert "$$(mkcert -CAROOT)/rootCA.pem" https://hello.$(DOMAIN)/ 2>/dev/null | head -4; do n=$$((n+1)); test $$n -le 15 || { echo "hello.$(DOMAIN) did not answer with the mkcert certificate within 30 s"; exit 1; }; sleep 2; done

## arc: install or upgrade the Actions Runner Controller (the operator; it needs no credentials).
arc:
	$(HELM) upgrade --install arc $(ARC_CHART)/gha-runner-scale-set-controller --version $(ARC_VERSION) \
	  --namespace arc-systems --create-namespace -f infrastructure/arc/controller-values.yaml --wait --timeout 5m

## runner-image: build the runner image and mirror the Docker daemon image into the cluster
## registry (host side: localhost:5000), both from pinned digests.
runner-image: runners-lint
	docker build --build-arg RUNNER_VERSION=$(RUNNER_VERSION) --build-arg RUNNER_DIGEST=$(RUNNER_DIGEST) -t localhost:5000/$(RUNNER_IMAGE) runners/image
	docker push localhost:5000/$(RUNNER_IMAGE)
	docker pull docker:$(DIND_VERSION)-dind@$(DIND_DIGEST)
	docker tag docker:$(DIND_VERSION)-dind@$(DIND_DIGEST) localhost:5000/dind:$(DIND_VERSION)
	docker push localhost:5000/dind:$(DIND_VERSION)

## runner-node: reserve RUNNER_NODE for runners. Runner pods are privileged (dind), so the node
## they share must hold nothing else; pods already there are evicted to the other nodes.
runner-node:
	$(KUBECTL) label node $(RUNNER_NODE) ci=runners --overwrite
	$(KUBECTL) taint node $(RUNNER_NODE) ci=runners:NoExecute --overwrite

## runners: one runner scale set per repo in REPOS, named lab-<repo>. Needs the github-app secret
## (README, "CI runners"); without it the scale sets could not register, so this stops first.
runners: config-check runners-lint runner-node fork-approval
	@$(KUBECTL) -n arc-systems get deploy -l app.kubernetes.io/part-of=gha-rs-controller -o name 2>/dev/null | grep -q . || { echo "the runner controller is not installed: run make arc first"; exit 1; }
	@$(KUBECTL) -n $(RUNNER_NS) get secret github-app >/dev/null 2>&1 || { echo "secret $(RUNNER_NS)/github-app is missing: create it as README.md, CI runners, describes"; exit 1; }
	@for r in $(REPOS); do \
	  echo "== $$r"; \
	  $(HELM) upgrade --install runners-$$r $(ARC_CHART)/gha-runner-scale-set --version $(ARC_VERSION) \
	    --namespace $(RUNNER_NS) -f runners/values.yaml --set githubConfigUrl=https://github.com/$(GITHUB_OWNER)/$$r \
	    --set runnerScaleSetName=$(RUNNER_PREFIX)-$$r || exit 1; \
	done

## fork-approval: hold every fork pull request's workflow run in PUBLIC_REPOS until the owner
## approves it, so no stranger's code reaches these runners unseen. Uses the gh CLI's login.
fork-approval: config-check
	@for r in $(PUBLIC_REPOS); do \
	  echo "== $$r"; \
	  gh api --silent -X PUT repos/$(GITHUB_OWNER)/$$r/actions/permissions/fork-pr-contributor-approval \
	    -f approval_policy=all_external_contributors || exit 1; \
	done

## config-check: the runner targets need to know whose repositories they serve.
config-check:
	@test -n "$(GITHUB_OWNER)" || { echo "GITHUB_OWNER is not set: copy config.mk.example to config.mk and fill it in"; exit 1; }
	@test -n "$(strip $(REPOS))" || { echo "REPOS is empty in config.mk: no repository would get runners"; exit 1; }
	@for r in $(PUBLIC_REPOS); do case " $(REPOS) " in *" $$r "*) ;; *) echo "PUBLIC_REPOS lists $$r, which is not in REPOS"; exit 1;; esac; done

## runners-lint: the image tag in runners/values.yaml must be the one runner-image builds.
runners-lint:
	@test "$$(grep -c "$(RUNNER_IMAGE)$$" runners/values.yaml)" -eq 2 || { echo "runners/values.yaml must use $(RUNNER_IMAGE) for both the runner and its init container"; exit 1; }
	@grep -q "dind:$(DIND_VERSION)" runners/values.yaml || { echo "runners/values.yaml does not use dind:$(DIND_VERSION)"; exit 1; }

## runners-status: the scale sets, their listeners and any runner pods.
runners-status:
	$(KUBECTL) get autoscalingrunnersets,ephemeralrunners -A
	$(KUBECTL) -n arc-systems get pods
	$(KUBECTL) -n $(RUNNER_NS) get pods

## scrub: fail if any tracked file contains a word from WORDS (one per line, case-insensitive), for
## example the names a private repository that builds on this one must keep out of a public copy.
scrub:
	@test -n "$(WORDS)" || { echo "usage: make scrub WORDS=<file with one word per line>"; exit 1; }
	@scripts/scrub-check.sh "$(WORDS)"
