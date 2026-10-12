SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

BATS ?= bats
GITLEAKS_IMAGE := ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f
SCRIPTS := $(wildcard scripts/*/*.sh) tests/integration/run.sh $(wildcard tests/lab/*.sh)
COMPOSE_CI := docker compose --env-file release.env --env-file .env.example

.PHONY: help lint test integration secrets ci vm-test vm-destroy lab-gpu preflight deploy rollback backup

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

lint: ## shellcheck every script + render the compose model
	shellcheck -x $(SCRIPTS) tests/helpers/*.bash
	$(COMPOSE_CI) config -q

test: ## Unit and policy tests (no Docker daemon, no GPU needed)
	$(BATS) -r tests

integration: ## Full deploy/rollback lifecycle on real containers with a fake GPU backend
	bash tests/integration/run.sh

secrets: ## Scan git history for committed secrets
	docker run --rm -v "$(CURDIR):/repo:ro" $(GITLEAKS_IMAGE) git /repo --config /repo/.gitleaks.toml --redact --no-banner

ci: lint test ## What CI runs before integration

VM_BOX := cloud-image/ubuntu-24.04-amd64
VM_BOX_URL := https://vagrantcloud.com/cloud-image/boxes/ubuntu-24.04/versions/20260926.0.0/providers/libvirt/amd64/vagrant.box

vm-test: ## Real Ubuntu 24.04 VM (vagrant-libvirt): bootstrap twice, then lint/test/integration
	if ! vagrant box list | grep -q '^$(VM_BOX) '; then \
	  tmp=$$(mktemp --suffix=.box); curl -fL --retry 3 -o "$$tmp" '$(VM_BOX_URL)'; \
	  vagrant box add --name '$(VM_BOX)' "$$tmp"; rm -f "$$tmp"; fi
	cd tests/vagrant && vagrant up --provision-with backup-disk,bootstrap && vagrant rsync && vagrant provision --provision-with test

lab-gpu: ## Real vLLM on ONE local NVIDIA GPU with the lab model, rootless Podman by default (docs/operations/LAB.md)
	bash tests/lab/run-gpu.sh $(if $(KEEP),--keep,)

vm-destroy: ## Delete the test VM
	cd tests/vagrant && vagrant destroy -f

# ---- Operations (on the guest VM, as root) ---------------------------------
preflight: ## Release preflight against the working tree
	bash scripts/deploy/preflight.sh

deploy: ## Deploy the committed tree as a new release (auto-rollback on failure)
	bash scripts/deploy/deploy.sh

rollback: ## Roll back to the previous release (prompts about data if needed)
	bash scripts/deploy/rollback.sh --previous

backup: ## Back up gateway DB and Open WebUI data
	bash scripts/ops/backup.sh
