# multica-nix

Declaratively install and configure a self-hosted [Multica](https://github.com/multica-ai/multica)
server with Nix. Provides a NixOS module that runs the backend (via Docker), provisions PostgreSQL 17 + pgvector,
and puts the CLI and desktop app on PATH. Declare skills, agents, and squads; the reconciler
syncs them into the workspace on rebuild.

## Usage

Add the flake as an input to your `flake.nix`:

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

Then in your NixOS configuration, enable and configure with `services.multica`. See below for the
complete option reference with all available settings:

## Configuration

```nix
services.multica = {
  # === REQUIRED ===
  enable = true;                                    # Turn the service on
  environmentFile = "/var/lib/multica/env";        # Env file (KEY=VALUE) with JWT_SECRET, MULTICA_TOKEN, etc.

  # === CORE SETTINGS ===
  package = pkgs.callPackage ./pkgs/multica-cli.nix { };           # Multica CLI package
  desktopPackage = pkgs.callPackage ./pkgs/multica-desktop.nix { }; # Desktop app package
  installDesktop = true;                           # Put desktop app on PATH (Linux only)

  # === NETWORKING ===
  host = "localhost";                              # Public host for backend URL in clients
  backendPort = 8080;                              # Backend API listen port
  openFirewall = false;                            # Open port in firewall

  # === BACKEND ===
  backendImage = "ghcr.io/multica-ai/multica-backend@sha256:...";  # Backend OCI image (digest-pinned)
  backendImageFile = null;                         # Optional pre-fetched image tarball
  extraBackendEnvironment = { };                   # Extra env vars for backend (S3, OAuth, etc.)

  # === DATABASE ===
  database.createLocally = true;                   # Provision local PostgreSQL + pgvector
  database.name = "multica";                       # Database name
  database.user = "multica";                       # Database user

  # === DEV MODE ===
  devMode = true;                                  # Enable passwordless login with fixed code
  devVerificationCode = "888888";                  # Fixed code for any email (dev mode only)
  devLoginEmail = "admin@multica.local";           # Identity reconciler logs in as (dev mode)
  workspaceName = "Default";                       # Workspace name (auto-created in dev mode)
  workspaceSlug = "default";                       # Workspace slug (auto-created in dev mode)

  # === WORKSPACE ===
  workspaceId = null;                              # Target workspace ID (auto-detect if null)

  # === SANDBOX PACKAGES ===
  sandboxExtraPackages = [ ];                      # Extra packages in all sandboxes

  # === DECLARATIVE SKILLS ===
  # Fully owned by config: declared skills created/updated, undeclared skills deleted on rebuild.
  # Reconciliation needs MULTICA_TOKEN (production) or auto-login (devMode).
  skills = {
    example-skill = {
      description = "Example skill";
      text = ''
        # Skill body
        Instructions here.
      '';
      # source = ./skills/example.md;                    # Or load from file instead of text
      # settings = { model = "opus"; };                  # Optional skill-specific config (JSON)
      # files."reference.md" = { text = "..."; };        # Optional extra files
      # files."checklist.md" = { source = ./checklist; };
    };
  };

  # === DECLARATIVE AGENTS ===
  # Fully owned by config: declared agents created/updated, undeclared agents archived on rebuild.
  # Agents need a runtime (from sandboxes or multica daemon). If no runtime exists, agents/squads skipped.
  # Reconciliation order: skills → agents → squads (so agents can reference declared skills,
  # squads can reference declared agents).
  agents = {
    example-agent = {
      description = "Example agent";
      instructions = "Be thorough.";                    # System prompt
      runtime = "my-sandbox";                          # Runtime name/id; null = sole runtime auto-used
      model = "claude-opus-5";                         # Model ID; null = runtime default
      # thinkingLevel = "high";                        # Reasoning effort (runtime-specific)
      # visibility = "private";                        # "private" (owner) or "workspace" (members)
      # maxConcurrentTasks = 5;                        # Max concurrent runs (1-50); null = server default
      skills = [ "example-skill" ];                    # Skill names to assign
      # customArgs = [ "--flag" "value" ];             # Extra runtime CLI args
      # runtimeConfig = { };                           # Runtime-specific config (JSON)
      # customEnvFile = "/absolute/path/env.json";     # Secret env vars (kept out of store)
      # mcpConfigFile = "/absolute/path/mcp.json";     # MCP server config (kept out of store)
    };
  };

  # === DECLARATIVE SQUADS ===
  # Fully owned by config: declared squads created/updated, undeclared squads archived on rebuild.
  # Members replaced to match declared set. Leader auto-added as member — do not list under members.
  # Archived squads cannot be restored via CLI; re-declaring creates a new squad.
  squads = {
    example-squad = {
      description = "Example squad";
      # instructions = "...";                           # Squad-wide instructions
      leader = "example-agent";                        # Leader agent (by name or id)
      members = {
        # other-agent.role = "member";                  # Members keyed by agent name; leader excluded
        # another-agent.role = "specialist";
      };
    };
  };

  # === DECLARATIVE SANDBOXES ===
  # Isolated OCI containers running multica daemon. Each auto-registers as a runtime.
  # Agents reference by name via runtime field.
  sandboxes = {
    my-sandbox = {
      extraPackages = [ ];                         # Extra packages for this sandbox
      # extraPackages = [ pkgs.ripgrep pkgs.gh ];
      volumeMounts = [ ];                          # Docker-style bind mounts ("host:container" or "host:container:ro")
      # volumeMounts = [ "/var/lib/work:/app/workspace" "/home/shared:/app/shared:ro" ];
    };
  };

  # === DECLARATIVE QUICK ACTIONS ===
  # Named prompts dispatching to an agent or squad. Fully owned: declared created/updated,
  # undeclared deleted on rebuild. Reconciled after agents/squads.
  quickActions = {
    example-action = {
      description = "Example action";
      prompt = "Do something useful.";              # The prompt run when triggered
      assignee = "example-agent";                  # Agent or squad name/id
      # assigneeType = "agent";                    # "agent" (default) or "squad"
      # visibility = "private";                    # "private" (you) or "public" (all members)
    };
  };

  # === DECLARATIVE AUTOPILOTS ===
  # Scheduled/triggered agent automations. Attribute name is title (identity).
  # Fully owned: declared created/updated, undeclared deleted on rebuild.
  # Reconciled after agents/squads. Only cron triggers declarative here; webhook triggers
  # managed manually (multica autopilot trigger-add). Triggers upserted by label; undeclared deleted.
  autopilots = {
    "Example Autopilot" = {
      description = "Example autopilot";           # Used as run prompt
      agent = "example-agent";                    # Agent name/id
      # mode = "run_only";                         # "run_only" (default) or "create_issue"
      # project = "proj_123";                      # Project ID for runs/issues (mode: create_issue)
      # issueTitleTemplate = "Report {{date}}";    # Template for created issues (mode: create_issue, {{date}} only)
      # subscribers = [ "alice@example.com" ];     # Members to notify
      # status = "active";                         # "active" or "paused"; null = server default
      triggers = {
        example = {
          cron = "0 9 * * *";                     # Cron expression
          # timezone = "UTC";                     # IANA timezone (default: UTC)
          # enabled = true;                       # Whether trigger is enabled (default: true)
        };
      };
    };
  };
};
```

## Notes

**Full workspace ownership:** Skills, agents, squads, quick actions, and autopilots are fully owned by this
config. Declared resources are created/updated on rebuild; undeclared resources are deleted/archived. If you
have manually created resources to keep, add them to the config first.

**Reconciliation order:** Skills → agents → squads. Agents can reference declared skills; squads can reference
declared agents. Sandboxes spin up after the backend is healthy. If no runtime exists, agents/squads are
skipped (reconciler logs notice; rebuild succeeds).

**Secrets:** Keep sensitive data out of the Nix store (world-readable). Use `environmentFile` for `JWT_SECRET`,
`MULTICA_TOKEN`, API keys, etc. Agent `customEnvFile` and `mcpConfigFile` are read at reconcile time as
absolute file paths (e.g., `/var/lib/multica/agent.env.json`).

**Authentication:** In `devMode = true`, the reconciler auto-logs in using `devLoginEmail` and `devVerificationCode`,
creating a workspace if none exists. In `devMode = false`, supply a personal access token (`mul_…`) in
`environmentFile` as `MULTICA_TOKEN=mul_…`. Without a token and outside dev mode, the reconciler skips (does
not fail the rebuild).
