SYSTEM := $(shell nix eval --impure --raw --expr 'builtins.currentSystem')

.PHONY: build check test fmt fmt-check dev update-digests

build:
	nix build .#multica-cli

check:
	nix flake check -L

test:
	nix build -L .#checks.$(SYSTEM).integration

fmt:
	nix fmt

fmt-check:
	nix run nixpkgs#nixpkgs-fmt -- --check .

dev:
	nix develop

update-digests:
	@for r in multica-backend; do \
	  t=$$(curl -s "https://ghcr.io/token?scope=repository:multica-ai/$$r:pull&service=ghcr.io" | jq -r .token); \
	  d=$$(curl -sI -H "Authorization: Bearer $$t" \
	    -H "Accept: application/vnd.oci.image.index.v1+json" \
	    "https://ghcr.io/v2/multica-ai/$$r/manifests/v0.4.41" | \
	    grep -i '^docker-content-digest:' | tr -d '\r' | awk '{print $$2}'); \
	  echo "$$r: $$d"; \
	done
