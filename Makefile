# Friendly entrypoints over nix. Everything here just wraps a nix command.
SYSTEM := $(shell nix eval --impure --raw --expr 'builtins.currentSystem')

.PHONY: help build check test fmt fmt-check dev update-digests

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

build: ## Build the multica CLI package
	nix build .#multica-cli

check: ## Evaluate the flake and run all checks (CLI build + VM test)
	nix flake check -L

test: ## Run the integration VM test only
	nix build -L .#checks.$(SYSTEM).integration

fmt: ## Format all Nix files
	nix fmt

fmt-check: ## Check formatting without writing
	nix run nixpkgs#nixpkgs-fmt -- --check .

dev: ## Enter the dev shell
	nix develop

update-digests: ## Print current GHCR image digests for the pinned version
	@for r in multica-backend; do \
	  t=$$(curl -s "https://ghcr.io/token?scope=repository:multica-ai/$$r:pull&service=ghcr.io" | jq -r .token); \
	  d=$$(curl -sI -H "Authorization: Bearer $$t" \
	    -H "Accept: application/vnd.oci.image.index.v1+json" \
	    "https://ghcr.io/v2/multica-ai/$$r/manifests/v0.4.41" | \
	    grep -i '^docker-content-digest:' | tr -d '\r' | awk '{print $$2}'); \
	  echo "$$r: $$d"; \
	done
