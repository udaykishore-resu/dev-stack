# dev-stack — orchestration for guest-score + market-mate.
#
# `make help` lists every target. Targets are documented with a `## comment`
# on the same line as the target, which is what help parses; keeping the docs
# on the target itself is the only way they stay true.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

COMPOSE       ?= docker compose
COMPOSE_FILE  ?= docker-compose.yml
COMPOSE_CMD   := $(COMPOSE) -f $(COMPOSE_FILE)

KUBECTL       ?= kubectl
KUSTOMIZE     ?= kustomize
KIND          ?= kind
KIND_CLUSTER  ?= guest-platform
NAMESPACE     ?= guest-platform
OVERLAY       ?= local

# Sibling repositories. Overridable in .env for a checkout that named them
# differently (the contract says market-mate; some clones use marketmate).
GUEST_SCORE_PATH ?= ../guest-score
MARKET_MATE_PATH ?= ../market-mate

# Images that kind must have side-loaded, because overlays/local sets
# imagePullPolicy: Never.
APP_IMAGES := guest-score-api:dev guest-score-scoring:dev guest-score-web:dev \
              marketmate-api:dev marketmate-web:dev

# Config shared byte-for-byte between compose and kustomize.
# canonical path                     -> copy inside the kustomize root
SYNCED_CONFIG := mosquitto/mosquitto.conf:k8s/base/config/mosquitto.conf \
                 postgres/init/01-databases.sh:k8s/base/config/01-databases.sh \
                 postgres/postgresql.conf:k8s/base/config/postgresql.conf

# Every target is a phony verb; there are no file targets in this Makefile.
.PHONY: help up up-infra up-all down clean logs ps psql redis-cli es-health \
        mqtt-sub mqtt-pub smoke wait build config-check \
        kind-up kind-down kind-load k8s-apply k8s-delete k8s-status \
        k8s-sync-config k8s-check-config k8s-build \
        brew-install brew-start brew-stop brew-createdb validate

# ---------------------------------------------------------------------------
help: ## Show this help
	@printf '\033[1mdev-stack\033[0m — guest-score + market-mate local platform\n\n'
	@printf '\033[1mUsage:\033[0m make <target>\n\n'
	@awk 'BEGIN {FS = ":.*?## "} \
	     /^# =+ / { next } \
	     /^##@ / { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
	     /^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' \
	     $(MAKEFILE_LIST)
	@printf '\n'

##@ Docker Compose

up: up-infra ## Alias for up-infra (the default: infra only)

up-infra: ## Start infra only (postgres, redis, elasticsearch, mosquitto)
	$(COMPOSE_CMD) up -d
	@$(MAKE) --no-print-directory wait

up-all: config-check ## Start infra + both applications (profile: all)
	$(COMPOSE_CMD) --profile all up -d --build
	@$(MAKE) --no-print-directory wait

down: ## Stop everything, keep the volumes
	$(COMPOSE_CMD) --profile all down --remove-orphans

clean: ## Stop everything AND DELETE the postgres/elasticsearch volumes
	@printf '\033[33mThis deletes dev-stack-pgdata and dev-stack-esdata.\033[0m\n'
	@read -r -p 'Type "yes" to continue: ' ans; [ "$$ans" = yes ] || { echo aborted; exit 1; }
	$(COMPOSE_CMD) --profile all down --remove-orphans --volumes
	@echo 'volumes removed; the next `make up` will re-run postgres/init/01-databases.sh'

build: config-check ## Build the application images without starting them
	$(COMPOSE_CMD) --profile all build

logs: ## Follow logs (make logs S=postgres for one service)
	$(COMPOSE_CMD) --profile all logs -f --tail 100 $(S)

ps: ## Show container status and health
	$(COMPOSE_CMD) --profile all ps

wait: ## Block until every running service reports healthy
	@./scripts/wait-for-healthy.sh

smoke: ## Run the end-to-end smoke test (skips app checks if apps are down)
	@./scripts/smoke.sh

# Guard for the app profile: the build contexts are sibling repos that may not
# be checked out. Failing here with a readable message beats a 200-line
# "failed to solve: lstat /path: no such file or directory" from buildkit.
config-check:
	@missing=0; \
	for d in "$(GUEST_SCORE_PATH)" "$(MARKET_MATE_PATH)"; do \
	  if [ ! -d "$$d" ]; then printf '\033[31mmissing sibling repo: %s\033[0m\n' "$$d"; missing=1; fi; \
	done; \
	if [ $$missing -eq 1 ]; then \
	  printf 'The app profile builds from sibling directories. Either clone them next\n'; \
	  printf 'to dev-stack, or set GUEST_SCORE_PATH / MARKET_MATE_PATH in .env.\n'; \
	  printf '\033[33m`make up-infra` works without them.\033[0m\n'; \
	  exit 1; \
	fi

##@ Infra shells and probes

psql: ## Open psql on the guestscore DB (make psql DB=marketmate)
	$(COMPOSE_CMD) exec postgres psql -U $${POSTGRES_USER:-postgres} -d $(or $(DB),guestscore)

redis-cli: ## Open redis-cli (make redis-cli N=1 for MarketMate's DB)
	$(COMPOSE_CMD) exec redis redis-cli -n $(or $(N),0)

# Double quotes around the URL: the port comes from the environment, and
# single quotes would send a literal $ELASTIC_PORT to curl.
es-health: ## Print Elasticsearch cluster health and the index list
	@curl -fsS "http://127.0.0.1:$${ELASTIC_PORT:-9200}/_cluster/health?pretty" || \
	  { echo 'elasticsearch not reachable'; exit 1; }
	@echo; curl -fsS "http://127.0.0.1:$${ELASTIC_PORT:-9200}/_cat/indices?v" || true

mqtt-sub: ## Subscribe to the whole guestscore/# topic tree (Ctrl-C to stop)
	$(COMPOSE_CMD) exec mosquitto mosquitto_sub -h 127.0.0.1 -t 'guestscore/#' -v

mqtt-pub: ## Publish a sample incident event (T=topic M=payload to override)
	$(COMPOSE_CMD) exec -T mosquitto mosquitto_pub -h 127.0.0.1 -q 1 \
	  -t '$(or $(T),guestscore/prop_mum_01/events)' \
	  -m '$(or $(M),{"event_id":"evt_7f3a","type":"incident","property_id":"prop_mum_01","member_id":"m_taj","guest_global_id":"GS-488122DBCBB0","stay_id":"s_1187","occurred_at":"2026-08-14T09:12:00Z","incident":{"type":"noise_complaint","severity":"moderate","note":"after 23:00"}})'
	@echo 'published'

##@ Kubernetes (kind)

kind-up: ## Create the kind cluster and install ingress-nginx
	$(KIND) create cluster --config kind/cluster.yaml
	@echo 'installing ingress-nginx...'
	$(KUBECTL) apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/kind/deploy.yaml
	$(KUBECTL) -n ingress-nginx wait --for=condition=ready pod \
	  --selector=app.kubernetes.io/component=controller --timeout=180s
	@echo 'cluster "$(KIND_CLUSTER)" ready; next: make kind-load k8s-apply'

kind-down: ## Delete the kind cluster
	$(KIND) delete cluster --name $(KIND_CLUSTER)

kind-load: build ## Side-load the app images into kind (required: pullPolicy is Never)
	@for img in $(APP_IMAGES); do \
	  echo "loading $$img"; \
	  $(KIND) load docker-image "$$img" --name $(KIND_CLUSTER); \
	done

k8s-sync-config: ## Refresh k8s/base/config/ from the canonical config files
	@for pair in $(SYNCED_CONFIG); do \
	  src=$${pair%%:*}; dst=$${pair##*:}; \
	  mkdir -p "$$(dirname "$$dst")"; cp "$$src" "$$dst"; echo "synced $$src -> $$dst"; \
	done

# kustomize refuses to read files outside its root, so k8s/base/config/ holds
# copies. This catches the case where someone edits mosquitto/mosquitto.conf
# and forgets that the cluster reads the copy.
k8s-check-config: ## Fail if k8s/base/config/ has drifted from the canonical files
	@drift=0; \
	for pair in $(SYNCED_CONFIG); do \
	  src=$${pair%%:*}; dst=$${pair##*:}; \
	  if ! diff -q "$$src" "$$dst" >/dev/null 2>&1; then \
	    printf '\033[31mdrift: %s != %s\033[0m\n' "$$src" "$$dst"; drift=1; \
	  fi; \
	done; \
	if [ $$drift -eq 1 ]; then echo 'run: make k8s-sync-config'; exit 1; fi; \
	echo 'k8s/base/config is in sync'

k8s-build: k8s-check-config ## Render the manifests to stdout (make k8s-build OVERLAY=prod)
	@$(KUSTOMIZE) build k8s/overlays/$(OVERLAY)

k8s-apply: k8s-check-config ## Apply the overlay to the current context (OVERLAY=local|prod)
	$(KUSTOMIZE) build k8s/overlays/$(OVERLAY) | $(KUBECTL) apply -f -
	@echo 'waiting for rollouts...'
	-$(KUBECTL) -n $(NAMESPACE) rollout status statefulset/postgres --timeout=180s
	-$(KUBECTL) -n $(NAMESPACE) rollout status statefulset/elasticsearch --timeout=300s
	-$(KUBECTL) -n $(NAMESPACE) rollout status deployment/redis --timeout=60s
	-$(KUBECTL) -n $(NAMESPACE) rollout status deployment/mosquitto --timeout=60s
	@$(MAKE) --no-print-directory k8s-status

k8s-delete: ## Delete the overlay from the current context (keeps PVCs)
	-$(KUSTOMIZE) build k8s/overlays/$(OVERLAY) | $(KUBECTL) delete --ignore-not-found -f -
	@printf '\033[33mPVCs survive on purpose. Remove them with:\033[0m\n'
	@printf '  kubectl -n $(NAMESPACE) delete pvc --all\n'

k8s-status: ## Show pods, services and ingresses in the namespace
	@$(KUBECTL) -n $(NAMESPACE) get pods -o wide || true
	@echo; $(KUBECTL) -n $(NAMESPACE) get svc || true
	@echo; $(KUBECTL) -n $(NAMESPACE) get ingress || true
	@echo; $(KUBECTL) -n $(NAMESPACE) get pvc || true

##@ Homebrew (the no-Docker path — macOS only; see docs/HOMEBREW.md)

brew-install: ## brew install postgresql@17 redis mosquitto (NOT elasticsearch — read the doc)
	@command -v brew >/dev/null || { echo 'Homebrew not installed'; exit 1; }
	brew install postgresql@17 redis mosquitto
	@printf '\033[33mElasticsearch is NOT installable from Homebrew core and elastic/tap is\n'
	@printf 'deprecated. Run ES in Docker or from the official tarball — see\n'
	@printf 'docs/HOMEBREW.md.\033[0m\n'

brew-start: ## brew services start the three local services
	brew services start postgresql@17
	brew services start redis
	brew services start mosquitto
	@brew services list | grep -E 'postgresql@17|redis|mosquitto' || true

brew-stop: ## brew services stop the three local services
	-brew services stop postgresql@17
	-brew services stop redis
	-brew services stop mosquitto

brew-createdb: ## Create the guestscore/marketmate roles and DBs on a brew postgres
	psql -d postgres -v ON_ERROR_STOP=1 -c "SET password_encryption='scram-sha-256'"
	@for r in guestscore marketmate; do \
	  psql -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='$$r'" | grep -q 1 || \
	    psql -d postgres -c "CREATE ROLE $$r WITH LOGIN PASSWORD '$$r'"; \
	  psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$$r'" | grep -q 1 || \
	    createdb -O "$$r" "$$r"; \
	  echo "role+db $$r ready"; \
	done

##@ Validation

validate: ## Validate compose config, kustomize builds and the shell scripts
	@echo '== docker compose config (default profile)'
	@$(COMPOSE_CMD) config -q && echo '   ok'
	@echo '== docker compose config (--profile apps)'
	@$(COMPOSE_CMD) --profile apps config -q && echo '   ok'
	@echo '== kustomize build k8s/overlays/local'
	@$(KUSTOMIZE) build k8s/overlays/local | python3 -c 'import sys,yaml;print("  ",len(list(yaml.safe_load_all(sys.stdin))),"documents")'
	@echo '== kustomize build k8s/overlays/prod'
	@$(KUSTOMIZE) build k8s/overlays/prod | python3 -c 'import sys,yaml;print("  ",len(list(yaml.safe_load_all(sys.stdin))),"documents")'
	@echo '== shell syntax'
	@for f in scripts/*.sh; do bash -n "$$f" && echo "   ok $$f"; done
	@sh -n postgres/init/01-databases.sh && echo '   ok postgres/init/01-databases.sh'
	@command -v shellcheck >/dev/null && { shellcheck scripts/*.sh && shellcheck -s sh postgres/init/01-databases.sh && echo '   ok shellcheck'; } || echo '   (shellcheck not installed, skipped)'
	@echo '== kubernetes schema validation'
	@command -v kubeconform >/dev/null && { \
	  for o in local prod; do \
	    $(KUSTOMIZE) build k8s/overlays/$$o | kubeconform -strict -summary -kubernetes-version 1.30.0 -ignore-missing-schemas -; \
	  done; } || echo '   (kubeconform not installed, skipped)'
	@$(MAKE) --no-print-directory k8s-check-config
