# multica-nix

Install and configure a self-hosted [Multica](https://github.com/multica-ai/multica)
server declaratively with Nix. Change the config, rebuild, and the running system follows.

Stand up the server (backend + database), put the CLI and desktop app on PATH, and
declare *skills* that are reconciled into the workspace on rebuild. Clients talk to the
backend API directly — there is no browser web frontend.

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

2. Create a secret env file **outside the Nix store** (root-only) with a strong JWT secret:

   ```bash
   sudo install -Dm600 /dev/stdin /var/lib/multica/secret.env <<EOF
   JWT_SECRET=$(openssl rand -hex 32)
   EOF
   ```

3. Enable the service:

   ```nix
   services.multica = {
     enable = true;
     environmentFile = "/var/lib/multica/secret.env";
     # host = "multica.example.com";   # if you reach it from another machine
     # openFirewall = true;            # to expose the backend beyond localhost
   };
   ```

4. `sudo nixos-rebuild switch`, then launch the desktop app (`multica-desktop`). The backend
   health check is at <http://localhost:8080/health>.

## Logging in

Multica login is passwordless — it emails a one-time code. This build runs the backend in
development mode with a **fixed verification code**, so you can log in offline with no mail
server configured. Use the desktop app (below); enter **any email address** and, when prompted
for the code, enter **`888888`**.

The account is created automatically on first login. Mint a personal access token under
**Settings → Tokens** and set it as `MULTICA_TOKEN` for the CLI/daemon.

### Desktop app

The packaged `multica-desktop` is pre-pointed at this local instance: its launcher writes
`~/.multica/desktop.json` (`apiUrl` → the backend, `wsUrl` → the backend websocket) on every
start, so it never falls back to Multica cloud. Just launch it and sign in with any email +
`888888`. If it was already open, fully quit and reopen it so it re-reads the config. (A one-off
`desktop-*` profile for the old cloud server may linger under `~/.multica/profiles/`; it's harmless.)

> ⚠️ **Local/dev only.** The fixed code `888888` is valid for *any* email, so anyone who can
> reach the backend can log in. This is only safe because the NixOS firewall is closed by
> default and the port binds to loopback — never expose this build on an internet-facing host.

## Configuration

| Option | Default | Purpose |
| --- | --- | --- |
| `services.multica.enable` | `false` | Turn the server on. |
| `services.multica.environmentFile` | *(required)* | Env file (KEY=VALUE) with `JWT_SECRET`; kept out of the store. |
| `services.multica.host` | `"localhost"` | Public host used in the backend URL seeded into clients. |
| `services.multica.backendPort` | `8080` | Backend API listen port. |
| `services.multica.backendImage` | digest-pinned v0.4.41 | Override to change version. |
| `services.multica.database.{name,user,createLocally}` | `multica` / `multica` / `true` | Native Postgres provisioning. |
| `services.multica.extraBackendEnvironment` | `{}` | Optional backend vars (S3, GitHub app, OAuth, Slack, SMTP/Resend, LLM assist, ...). |
| `services.multica.openFirewall` | `false` | Open the backend port in the firewall. |
| `services.multica.installDesktop` | `true` | Put the desktop client on PATH (Linux only); set false for headless/CLI-only. |
| `services.multica.skills` | `{}` | Declarative skills reconciled into the workspace (see below). |
| `services.multica.agents` | `{}` | Declarative agents (need a runtime; see below). |
| `services.multica.squads` | `{}` | Declarative squads of agents (see below). |
| `services.multica.quickActions` | `{}` | Declarative quick actions (named prompts → agent/squad). |
| `services.multica.autopilots` | `{}` | Declarative autopilots (scheduled agent automations; see below). |
| `services.multica.devMode` | `true` | Dev backend: passwordless login + automatic skill token. Set false for production. |
| `services.multica.devLoginEmail` | `"admin@multica.local"` | Identity the reconciler logs in as in dev mode (log into the app with the same email). |
| `services.multica.workspaceId` | `null` | Workspace to reconcile skills into (defaults to the sole workspace, auto-created in dev). |

Any of Multica's optional integrations go through `extraBackendEnvironment`, e.g.:

```nix
services.multica.extraBackendEnvironment = {
  RESEND_API_KEY = "..."; # better: put secrets in environmentFile instead
  ALLOWED_EMAIL_DOMAINS = "example.com";
};
```

Keep secrets in `environmentFile` (or sops-nix / agenix), never in the Nix config — the store
is world-readable.

## Declarative skills

Declare skills as an attribute set keyed by name — the attribute name *is* the skill's
identity. On rebuild a `multica-skills` service reconciles them into the workspace: declared
skills are created or updated to match; skills you remove are left untouched (reconciliation
is **additive**, so it never deletes).

```nix
services.multica.skills = {
  pr-review = {
    description = "How we review pull requests";
    text = ''
      # PR review
      Check tests, scope, and a rollback plan before approving.
    '';
    # optional: settings = { model = "opus"; };  # -> the CLI's --config JSON
    # optional extra files bundled with the skill:
    # files."reference.md".source = ./skills/pr-review-reference.md;
  };

  lender-list.source = ./skills/lender-list.md;  # body straight from a file
};
```

Each skill takes `description`, a body as either inline `text` **or** a file `source` (exactly
one), an optional `settings` attrset (serialised to JSON), and optional `files` (extra files
keyed by their path within the skill, each also `text` or `source`).

**Auth.** The reconciler drives the `multica` CLI, which needs a token — and on this dev build it
gets one **automatically**, so declaring a skill and rebuilding just works:

- In `devMode` (the default) the reconciler logs in with the fixed code as `devLoginEmail`
  (default `admin@multica.local`), creates a workspace if none exists, and pushes your skills.
  **Log in to the desktop app with that same email** to see the workspace and skills it manages.
- To target a real (non-dev) backend, set `devMode = false` and provide a personal access token
  (**Settings → Tokens**, a `mul_…` token) in `environmentFile` as `MULTICA_TOKEN=mul_…`. A
  supplied `MULTICA_TOKEN` always takes precedence over dev login. Without a token and outside
  dev mode the reconciler logs a notice and skips — it never fails the rebuild.

If the identity can see more than one workspace, set `services.multica.workspaceId`.

## Declarative agents and squads

Agents and squads reconcile the same way, in order **skills → agents → squads** (so an agent
can reference skills you declare, and a squad can reference agents you declare). The resources
are **additive** (declaring creates/updates; removing never deletes), but their relationships —
an agent's assigned skills, a squad's members — are **replaced to match** the config.

```nix
services.multica.agents.reviewer = {
  description = "Reviews pull requests";
  runtime = "Claude (myhost)";        # runtime name or id; omit if only one exists
  model = "claude-sonnet-4-6";
  instructions = ''Be thorough and terse.'';
  skills = [ "pr-review" ];           # skill names → assigned to the agent
};

services.multica.squads.delivery = {
  description = "Ships the roadmap";
  leader = "reviewer";                # agent name or id (auto-added as a member)
  members.builder.role = "member";    # keyed by agent name; leader excluded
};
```

**Runtimes.** An agent must run on a runtime, and runtimes aren't declarative — they register
when a `multica daemon` runs. Reference one by name/id with `runtime` (`multica runtime list`);
if the workspace has exactly one it's used automatically. **If no runtime exists, agents and
squads are skipped** (the reconciler logs a notice and still does skills) so a box without a
daemon still rebuilds.

**Secrets.** An agent's custom env vars and MCP config often carry API tokens, so they're passed
as **file paths read at reconcile time**, kept out of the world-readable Nix store — give an
absolute path, not a `./file`:

```nix
services.multica.agents.reviewer = {
  runtime = "Claude (myhost)";
  customEnvFile = "/var/lib/multica/reviewer.env.json";   # {"KEY":"value"}
  mcpConfigFile = "/var/lib/multica/reviewer.mcp.json";   # {"mcpServers":{…}}
};
```

Non-secret bits (`instructions`, `model`, `runtimeConfig`, `customArgs`) are fine inline.

## Declarative quick actions

Quick actions are named prompts that dispatch to an agent or squad. They reconcile after
agents/squads (so they can reference ones you declare), additively.

```nix
services.multica.quickActions.triage = {
  description = "Triage an issue";
  prompt = ''Triage this issue: label it and suggest next steps.'';
  assignee = "reviewer";        # an agent (default) or squad name/id
  # assigneeType = "squad";     # if the assignee is a squad
  # visibility = "public";      # default "private"
};
```

`assignee` resolves by name against agents (or squads, if `assigneeType = "squad"`). If it
doesn't exist yet (e.g. its runtime was unavailable so the agent wasn't created), the reconciler
logs a notice and skips that action rather than failing the rebuild. `visibility = "public"`
requires the assignee agent to be public; the default `"private"` works with any.

Quick actions have no CLI, so the reconciler drives Multica's REST API directly — no extra setup
beyond the token the reconciler already uses.

## Declarative autopilots

Autopilots are scheduled/triggered agent automations. They reconcile after agents/squads (so they
can reference agents you declare), additively — the attribute name *is* the autopilot's title.

```nix
services.multica.autopilots."Nightly triage" = {
  description = "Summarise and label new issues from the last day.";  # used as the run prompt
  agent = "reviewer";                    # assignee agent, by name or id
  mode = "create_issue";                 # or "run_only" (default)
  issueTitleTemplate = "Triage {{date}}"; # create_issue only; only {{date}} is interpolated
  # project = "…"; subscribers = [ "alice" ]; status = "active";  # all optional
  triggers.nightly = {
    cron = "0 9 * * *";
    timezone = "Australia/Sydney";       # default "UTC"
    # enabled = false;                   # default true
  };
};
```

Like quick actions, an autopilot dispatches to an `agent`, which needs a runtime — if the agent
doesn't exist yet the reconciler logs a notice and skips the autopilot rather than failing the
rebuild. Only **schedule (cron) triggers** are declarative here, keyed by label and upserted on
each reconcile; triggers you remove (or webhook triggers added with `multica autopilot
trigger-add`) are left untouched.

## Networking (round 1)

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

- Optional: prune-on-removal for skills (make reconciliation fully declarative), per-skill
  change detection to skip unchanged updates.
- Optional: build backend/web from source, home-manager module for the CLI, hardened networking.
