# infra-utm-anon-egress
# Gateway + isolated workstation on UTM (Apple Silicon). The workstation has no
# internet path of its own; all egress goes through the gateway.

SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help preflight up provision configure status ssh console down destroy lint test verify

# Allow `make ssh workstation` (bare VM name) alongside `make ssh VM=workstation`;
# same for `make console`. When one of them is the goal, the remaining goals are the VM name: capture them and
# stub each out as a no-op target so make does not fail with "no rule to make
# target". Guarded on ssh being the first goal so typos on other targets still
# error normally. (A VM must therefore not share a name with a make target.)
ifneq ($(filter $(firstword $(MAKECMDGOALS)),ssh console),)
SSH_ARGS := $(filter-out ssh console,$(MAKECMDGOALS))
ifneq ($(SSH_ARGS),)
.PHONY: $(SSH_ARGS)
$(eval $(SSH_ARGS):;@:)
endif
endif

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## Full hands-off deploy: preflight, create VMs, configure with Ansible
	@scripts/up.sh

preflight: ## Check macOS, UTM, and required tools; generate SSH key
	@scripts/preflight.sh

provision: ## Create and boot the VMs only (no Ansible)
	@scripts/up.sh --provision-only

configure: ## Run Ansible against already-running VMs
	@scripts/up.sh --configure-only

status: ## Show status of all VMs
	@scripts/status.sh

ssh: ## SSH into a VM: make ssh gateway | make ssh workstation
	@scripts/ssh.sh $(or $(VM),$(SSH_ARGS))

console: ## Serial console: make console gateway | make console workstation
	@scripts/console.sh $(or $(VM),$(SSH_ARGS))

down: ## Stop all VMs (keeps them for later)
	@scripts/down.sh

destroy: ## Stop and delete all VMs and generated artifacts
	@scripts/destroy.sh

verify: ## Assert the security property: workstation isolated, reachable via gateway
	@scripts/verify.sh

test: ## Run the shell unit tests (no UTM needed)
	@# Globbed, not listed: a hand-maintained list means a new test under
	@# tests/ silently never runs, and a test that does not run is green by
	@# default -- the exact failure mode this repo's guards exist to prevent.
	@# `|| exit 1` stops at the first failure, as the explicit list did.
	@set -e; ran=0; for t in tests/*.sh; do ran=$$((ran+1)); bash "$$t" || exit 1; done; \
		[ "$$ran" -gt 0 ] || { echo "no tests found under tests/"; exit 1; }; \
		echo "$$ran test file(s) passed"

lint: ## Syntax-check scripts and Ansible
	@bash -n scripts/*.sh tests/*.sh && echo "shell OK"
	@# ANSIBLE_COLLECTIONS_PATH is derived because ansible-lint's own
	@# ansible-core does not see Homebrew ansible's bundled collections; without
	@# it, unresolvable modules silently stop the lint at the `min` profile.
	@if command -v ansible-lint >/dev/null 2>&1; then \
		ANSIBLE_COLLECTIONS_PATH="$$(ansible-galaxy collection list 2>/dev/null \
			| sed -n 's|^# \(.*\)/ansible_collections$$|\1|p' \
			| grep -v '/_internal$$' | paste -sd: -)" \
			ansible-lint ansible/; \
	else \
		echo "ansible-lint not installed, skipping"; \
	fi
