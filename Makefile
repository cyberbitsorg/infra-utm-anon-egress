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

console: ## Serial console (the display never works: cloud kernels have no DRM)
	@scripts/console.sh $(or $(VM),$(SSH_ARGS))

down: ## Stop all VMs (keeps them for later)
	@scripts/down.sh

destroy: ## Stop and delete all VMs and generated artifacts
	@scripts/destroy.sh

verify: ## Assert the security property: workstation isolated, reachable via gateway
	@scripts/verify.sh

test: ## Run the shell unit tests (no UTM needed)
	@bash tests/parse-vm-entry.sh
	@bash tests/parse-nic-layout.sh
	@bash tests/subnet-overlap.sh
	@bash tests/seed-network.sh
	@bash tests/gen-inventory.sh
	@bash tests/ssh-jump.sh
	@bash tests/secret-vars.sh
	@bash tests/wg-config.sh
	@bash tests/vpn-pkg-scan.sh
	@bash tests/tool-groups.sh
	@bash tests/vpn-watch-list.sh
	@bash tests/mullvad-select.sh

lint: ## Syntax-check scripts and Ansible
	@bash -n scripts/*.sh tests/*.sh && echo "shell OK"
	@command -v ansible-lint >/dev/null && ansible-lint ansible/ || echo "ansible-lint not installed, skipping"
