SYSTEM := $(shell nix eval --impure --raw --expr 'builtins.currentSystem')

.PHONY: build check test fmt fmt-check dev

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
