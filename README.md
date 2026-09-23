# multica-nix

Install and configure a self-hosted [Multica](https://github.com/multica-ai/multica)
server declaratively with Nix. Change the config, rebuild, and the running system follows.

Stand up the server (backend + database), put the CLI and desktop app on PATH, and
declare *skills*, *agents*, and *squads* that are reconciled into the workspace on rebuild.
Clients talk to the backend API directly — there is no browser web frontend.

## What it gives you

- `packages.<system>.multica-cli` — the Multica CLI (prebuilt static binary, v0.4.41).
- `nixosModules.multica` — a NixOS module (`services.multica`) that runs the published
backend image (`ghcr.io/multica-ai/multica-backend`, digest-pinned) via docker, and
provisions PostgreSQL 17 + pgvector natively.

## Quick start (NixOS)

1. Add the flake as an input and import the module:

```nix
{
inputs.multica.url = "github:youruser/multica-nix"; # or path:/home/james/multica-nix

outputs = { nixpkgs, multica, ... }: {
nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
modules = [
multica.nixosModules.multica
./configuration.nix
];
};
};
}
```

2. Enable and configure the service (see "Full configuration example" below for all options).
Minimal setup:

```nix
services.multica = {
enable = true;
environmentFile = "/var/lib/multica/env";
};
```

3. `sudo nixos-rebuild switch`, then launch the desktop app (`multica-desktop`).
The backend health check is at `http://localhost:8080/health`.

## Logging in

Multica login is passwordless — it emails a one-time code. This build runs the backend in
**development mode** with a fixed verification code by default, so you can log in offline with
no mail server configured. Use the desktop app; enter **any email address** and when prompted
for the code, enter **`888888`**.

The account is created automatically on first login. Mint a personal access token under
**Settings → Tokens** and set it as `MULTICA_TOKEN` in your `environmentFile` for the CLI/daemon.

### Desktop app

The packaged `multica-desktop` is pre-pointed at this local instance: its launcher writes
`~/.multica/desktop.json` on every start, so it never falls back to Multica cloud. Just
launch it and sign in with any email + the dev code. If it was already open, fully quit
and reopen it so it re-reads the config.

> ⚠️ **Local/dev only.** The fixed code is valid for *any* email, so anyone who can reach
> the backend can log in. This is only safe because the NixOS firewall is closed by default
> and the port binds to loopback — never expose this build on an internet-facing host without
> disabling `devMode`.

## Full configuration example

Here is a complete, real-world `services.multica` configuration with every important option
explicitly set. Use it as a starting point and modify values for your setup:

```nix
services.multica = {
  enable = true;
  environmentFile = "/var/lib/multica/env";

  host = "0.0.0.0";
  backendPort = 8080;
  openFirewall = true;

  database.createLocally = true;

  extraBackendEnvironment = {
    RESEND_API_KEY = "re_...";
    ALLOWED_EMAIL_DOMAINS = "example.com";
  };

  devMode = false;
  devLoginEmail = "admin@example.com";
  workspaceName = "Production";
  workspaceSlug = "production";

  installDesktop = false;

  skills = {
    pr-review = {
      description = "Code review process";
      text = ''
        # Pull Request Review
        - Tests pass
        - Scope is clear
        - Rollback plan exists
      '';
      settings = { model = "opus"; };
    };

    linting = {
      description = "Linting rules";
      source = ./skills/linting.md;
      files."checklist.md".source = ./checklist.md;
    };
  };

  agents = {
    reviewer = {
      description = "Senior code reviewer";
      instructions = "Be thorough but concise.";
      runtime = "claude-sandbox";
      model = "claude-opus-5";
      thinkingLevel = "high";
      visibility = "workspace";
      maxConcurrentTasks = 3;
      skills = [ "pr-review" "linting" ];
      customEnvFile = "/var/lib/multica/reviewer.env.json";
      mcpConfigFile = "/var/lib/multica/reviewer.mcp.json";
    };

    builder = {
      description = "CI/CD automation";
      runtime = "claude-sandbox";
      model = "claude-sonnet-5";
      skills = [ "linting" ];
    };
  };

  squads = {
    engineering = {
      description = "Core engineering team";
      leader = "reviewer";
      instructions = "Focus on quality and velocity.";
      members = {
        builder.role = "member";
      };
    };
  };

  sandboxExtraPackages = [ pkgs.ripgrep pkgs.gh ];

  sandboxes = {
    claude-sandbox = {
      extraPackages = [ pkgs.jq pkgs.yq ];
      volumeMounts = [
        "/var/lib/work:/app/workspace"
        "/home/shared:/app/shared:ro"
      ];
    };
  };

  quickActions = {
    triage = {
      description = "Label and prioritize issues";
      prompt = "Triage this: assign labels, estimate effort, suggest owner.";
      assignee = "reviewer";
      assigneeType = "agent";
      visibility = "public";
    };

    review-pr = {
      description = "Review a pull request";
      prompt = "Review this PR: check tests, scope, and rollback plan.";
      assignee = "engineering";
      assigneeType = "squad";
      visibility = "workspace";
    };
  };

  autopilots = {
    "Weekly Digest" = {
      description = "Summarize completed work";
      agent = "reviewer";
      mode = "create_issue";
      project = "proj_123";
      issueTitleTemplate = "Weekly Digest {{date}}";
      subscribers = [ "alice@example.com" "bob@example.com" ];
      status = "active";
      triggers = {
        friday-eod = {
          cron = "0 17 * * FRI";
          timezone = "America/New_York";
          enabled = true;
        };
      };
    };

    "Nightly Lint" = {
      description = "Check code quality across repos";
      agent = "builder";
      mode = "run_only";
      triggers = {
        nightly = {
          cron = "0 2 * * *";
          timezone = "UTC";
        };
      };
    };
  };
};
```

### About options

**Omit defaults.** Any option not shown in the example uses its module default. See the Nix
module (`modules/multica.nix`) for the complete option reference with all defaults and descriptions.

**Full workspace ownership.** Skills, agents, squads, quick actions, and autopilots declared
here are created/updated on rebuild. Any resources *not* declared are deleted/archived. If you
have manually created resources to keep, add them to the config first.

**Reconciliation order.** Resources reconcile in sequence: skills → agents → squads (agents
can reference declared skills; squads can reference declared agents). Sandboxes spin up after
the backend is healthy. If no runtime exists, agents/squads are skipped but the rebuild succeeds.

**Secrets.** Keep sensitive data out of the Nix store. Use `environmentFile` for `JWT_SECRET`,
`MULTICA_TOKEN`, API keys, etc. Agent `customEnvFile` and `mcpConfigFile` are read at
reconcile time as absolute file paths (e.g., `/var/lib/multica/agent.env.json`).

## Authentication & Tokens

### Dev mode (default)

In `devMode = true`, the reconciler automatically logs in using `devLoginEmail` and `devVerificationCode`,
creating a workspace if none exists. Log in to the desktop app with the same email to see
the workspace and resources the reconciler manages.

### Production mode

Set `devMode = false` and supply a personal access token in `environmentFile` as `MULTICA_TOKEN=mul_…`.
Without a token and outside dev mode, the reconciler logs a notice and skips reconciliation (does not fail the rebuild).

Sandboxes in dev mode auto-authenticate the same way. In production, they require `MULTICA_TOKEN`.

## Networking

The backend container uses **host networking**, so it reaches native postgres over `localhost`.
The backend port is therefore reachable on all interfaces at the OS level; the NixOS firewall
(closed by default) is what keeps it private. Set `openFirewall = true` only when you intend
remote access. A hardened bridged-network variant is a planned improvement.

## Testing

```bash
make build   # build the CLI
make test    # run the integration VM test (boots the real stack, checks /health)
make check   # nix flake check: CLI build + VM test
make dev     # dev shell (nixpkgs-fmt, skopeo, jq)
```

The integration test (`tests/integration.nix`) fetches the pinned backend image into the Nix
store so the sandboxed test VM needs no network. The image hash is architecture-specific — the
first run on a new architecture prints the hash to paste into `imageSha`.

## Updating the pinned version

1. Bump `version` + the four `hash`es in `pkgs/multica-cli.nix` (use `nix-prefetch-url`).
2. Bump the backend digest in `modules/multica.nix` (`make update-digests` prints current ones).
3. Update `imageSha` in `tests/integration.nix` (the test prints the expected value).

## Roadmap

- Optional: per-skill change detection to skip unchanged updates.
- Optional: build backend/web from source, home-manager module for the CLI, hardened networking.
