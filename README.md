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
  environmentFile = "/var/lib/multica/env";        # Env file (KEY=VALUE) with MULTICA_TOKEN, etc.

  # === CORE SETTINGS ===
  installDesktop = true;                           # Put desktop app on PATH (Linux only)

  # Postgres (local, pgvector) is always provisioned; the backend runs in dev mode
  # on localhost:8080. These are fixed and not configurable.

  # === DEV LOGIN ===
  devLoginEmail = "admin@multica.local";           # Identity reconciler logs in as (dev mode)

  # === DECLARATIVE SKILLS ===
  # Fully owned by config: declared skills created/updated, undeclared skills deleted on rebuild.
  # Reconciliation logs in via passwordless dev-mode login.
  skills = {
    example-skill = {
      description = "Example skill";
      text = ''
        # Skill body
        Instructions here.
      '';
      # settings = { model = "opus"; };                  # Optional skill-specific config (JSON)
      # files."reference.md" = { text = "..."; };        # Optional extra files
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
      skills = [ "example-skill" ];                    # Skill names to assign
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
  # OCI containers running multica daemon, each auto-registering as a runtime.
  # Agents reference by name via runtime field. Provides process/filesystem
  # isolation; networking is shared with the host (--network=host).
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
      mode = "run_only";                          # "run_only" (default) or "create_issue"
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

**Secrets:** Keep sensitive data out of the Nix store (world-readable). Use `environmentFile` for
`MULTICA_TOKEN`, API keys, etc.

**Authentication:** The reconciler auto-logs in using `devLoginEmail` with a fixed dev verification code,
creating a workspace if none exists. Provide a personal access token (`mul_…`) in `environmentFile` as
`MULTICA_TOKEN=mul_…` to use an existing workspace with a real account. Without a token, the reconciler
uses dev-mode passwordless login.
