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

Here is a complete `services.multica` block with every available option documented. Use this
as a reference when building your config:

```nix
services.multica = {
  # == CORE ==
  enable = true;                           # required: turn the service on

  # == NETWORKING ==
  host = "localhost";                      # optional; default: public host for clients
  backendPort = 8080;                      # optional; default: backend API port
  openFirewall = false;                    # optional; default: expose backend to network?

  # == BACKEND IMAGE ==
  backendImage = "ghcr.io/multica-ai/multica-backend@sha256:...";  # optional; override version
  # backendImageFile = null;               # optional; pre-fetched image tarball (offline use)

  # == DATABASE ==
  database = {
    createLocally = true;                  # optional; default: provision local PostgreSQL?
    name = "multica";                      # optional; database name
    user = "multica";                      # optional; database user
  };

  # == ENVIRONMENT & SECRETS ==
  environmentFile = "/var/lib/multica/env";  # required; env file (JWT_SECRET, MULTICA_TOKEN, etc.)
  extraBackendEnvironment = {              # optional; extra env vars for backend container
    # S3_BUCKET = "my-bucket";
    # GITHUB_APP_ID = "123456";
    # ALLOWED_EMAIL_DOMAINS = "example.com";
  };

  # == DEV MODE ==
  devMode = true;                          # optional; default: enable passwordless login
  devVerificationCode = "888888";          # optional; fixed code for any email in dev mode
  devLoginEmail = "admin@multica.local";   # optional; identity reconciler logs in as
  workspaceName = "Default";               # optional; name of auto-created workspace in dev
  workspaceSlug = "default";               # optional; slug of auto-created workspace in dev

  # == WORKSPACE ==
  workspaceId = null;                      # optional; target workspace id (auto-detect if null)

  # == DESKTOP CLIENT ==
  installDesktop = true;                   # optional; default: put desktop app on PATH (Linux)

  # == DECLARATIVE SKILLS ==
  # Skills are reconciled to match this config exactly: declared skills are created/updated,
  # undeclared skills are deleted. Reconciliation needs a token (MULTICA_TOKEN in environmentFile
  # in production, or auto-login in devMode). Skills → agents → squads reconcile in order.
  skills = {
    pr-review = {
      description = "Code review process";
      text = ''
        # Pull Request Review

        Check the following before approving:
        - Tests pass
        - Scope is well-defined
        - Rollback plan exists
      '';
      # settings = { model = "opus"; };   # optional; skill-specific config (JSON)
      # files."reference.md".text = "...";  # optional; extra files keyed by path
      # files."checklist.md".source = ./checklist.md;
    };

    linting-rules = {
      # description = "";                 # optional; default: empty
      source = ./skills/linting-rules.md;  # load body from file instead of inline text
    };
  };

  # == DECLARATIVE AGENTS ==
  # Agents are reconciled to match this config exactly: declared agents are created/updated,
  # undeclared agents are archived. Agents need a runtime (from sandboxes or multica daemon).
  # If no runtime exists, agents/squads are skipped (reconciler logs notice, rebuild succeeds).
  agents = {
    reviewer = {
      description = "Code reviewer for pull requests";
      instructions = "Be thorough and terse in feedback.";  # optional; system prompt
      runtime = "sandbox-1";              # optional; runtime name/id; null = sole runtime auto-used
      model = "claude-opus-5";            # optional; model id (null = runtime default)
      # thinkingLevel = "high";           # optional; reasoning effort (runtime-specific)
      # visibility = "private";           # optional; "private" (owner) or "workspace" (all members)
      # maxConcurrentTasks = 5;           # optional; 1-50; null = server default
      skills = [ "pr-review" "linting-rules" ];  # optional; skill names to assign
      # customArgs = [ "--flag" "value" ];  # optional; extra CLI args for runtime
      # runtimeConfig = { };              # optional; runtime-specific config (JSON)
      # customEnvFile = "/absolute/path/to/env.json";    # optional; secret env vars
      # mcpConfigFile = "/absolute/path/to/mcp.json";    # optional; MCP server config
    };

    builder = {
      description = "Builds and deploys code";
      # ... (same options as above)
    };
  };

  # == DECLARATIVE SQUADS ==
  # Squads are reconciled to match this config exactly: declared squads are created/updated,
  # undeclared squads are archived. Members are replaced to match. Leader is auto-added
  # as a member — do not list it under `members`. Archived squads cannot be restored via CLI.
  squads = {
    delivery-team = {
      description = "Ships the roadmap";
      leader = "reviewer";                # required; agent name/id (auto-added as member)
      # instructions = "";                # optional; squad-wide instructions
      members = {
        builder.role = "member";          # keyed by agent name, role is optional (default: "member")
        # other-agent.role = "specialist";
      };
    };
  };

  # == DECLARATIVE SANDBOXES ==
  # Sandboxes are isolated OCI containers running a multica daemon. Each auto-registers
  # as a runtime with the backend. Agents reference sandboxes by attribute name via `runtime`.
  # In devMode, sandboxes auto-authenticate. Reconciliation order: skills → agents → squads,
  # then sandboxes are spun up (they auto-register after backend is healthy).
  sandboxExtraPackages = [ ];              # optional; extra packages in all sandboxes
  # sandboxExtraPackages = [ pkgs.ripgrep pkgs.gh ];

  sandboxes = {
    sandbox-1 = {
      extraPackages = [ ];                # optional; extra packages for this sandbox only
      volumeMounts = [                    # optional; docker-style bind mounts
        # "/host/path:/container/path"
        # "/host/path:/container/path:ro"
      ];
    };
  };

  # == DECLARATIVE QUICK ACTIONS ==
  # Quick actions are named prompts that dispatch to an agent or squad. Reconciled after
  # agents/squads. Workspace is fully owned by this config: declared actions are
  # created/updated, undeclared actions are deleted. No CLI; reconciler drives REST API.
  quickActions = {
    triage = {
      description = "Triage a GitHub issue";
      prompt = "Analyze this issue: assign labels, estimate effort, suggest next steps.";  # required
      assignee = "reviewer";              # required; agent or squad name/id
      # assigneeType = "agent";           # optional; default: "agent" or "squad"
      # visibility = "private";           # optional; "private" (you) or "public" (members)
    };
  };

  # == DECLARATIVE AUTOPILOTS ==
  # Autopilots are scheduled/triggered agent automations. Reconciled after agents/squads.
  # Attribute name is the autopilot's title (its identity). Workspace is fully owned:
  # declared autopilots are created/updated, undeclared are deleted. Only schedule (cron)
  # triggers are declarative; webhook triggers are manual (`multica autopilot trigger-add`).
  # Cron triggers are upserted by label; triggers not declared are deleted.
  autopilots = {
    "Nightly Triage" = {
      description = "Summarize and label new issues daily.";  # required; used as run prompt
      agent = "reviewer";                 # required; agent name/id
      mode = "run_only";                  # optional; "run_only" (default) or "create_issue"
      # project = "proj_123";             # optional; project id for runs/issues
      # issueTitleTemplate = "Triage {{date}}";  # optional; template for created issues (mode: create_issue)
      # subscribers = [ "alice@example.com" ];   # optional; members to notify
      # status = "active";                # optional; "active" or "paused" (null = server default)
      triggers = {
        nightly = {
          cron = "0 9 * * *";             # required; cron expression
          timezone = "UTC";               # optional; default: IANA timezone
          # enabled = true;               # optional; default: enable trigger
        };
        # morning-us-east = {
        #   cron = "0 8 * * MON-FRI";
        #   timezone = "America/New_York";
        # };
      };
    };
  };
};
```

### Key behaviors

**Full workspace ownership.** Skills, agents, squads, quick actions, and autopilots are all
fully owned by this config: declared resources are created/updated, and *undeclared* resources
are deleted/archived on the next rebuild. If you have resources in the UI or CLI that you want
to keep, add them to the config first.

**Reconciliation order.** Resources reconcile in this order: skills → agents → squads
(so agents can reference your declared skills, squads can reference your declared agents).
Sandboxes spin up after the backend is healthy; if no runtime exists, agents and squads are
skipped (reconciler logs a notice; rebuild does not fail).

**Secrets.** Keep secrets out of the Nix store (world-readable). Use `environmentFile` for
`JWT_SECRET`, `MULTICA_TOKEN`, and other sensitive vars. Agent `customEnvFile` and `mcpConfigFile`
are paths read at reconcile time, not Nix values — use absolute paths like `/var/lib/multica/agent.env.json`.

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
