{ config, lib, pkgs, ... }:

let
  cfg = config.services.multica;

  # Referenced by tag (not digest): a docker-loaded imageFile tarball registers
  # under this tag, so the container must match it to run offline (tests) and to
  # avoid a registry pull. The pinned digest lives in the pullImage calls.
  defaultBackendImage = "ghcr.io/multica-ai/multica-backend:v0.4.41";

  cliPackage = pkgs.callPackage ../pkgs/multica-cli.nix { };
  desktopPkg = pkgs.callPackage ../pkgs/multica-desktop.nix { };
  devVerificationCode = "888888";

  # Opinionated single-host dev defaults, intentionally not configurable.
  host = "localhost";
  backendPort = 8080;
  dbName = "multica";
  dbUser = "multica";
  workspaceName = "Default";
  workspaceSlug = "default";

  backendUrl = "http://${host}:${toString backendPort}";
  # Sandboxes run on Docker's bridge network, so they reach the backend via a host address
  # the consumer supplies (not localhost).
  sandboxBackendUrl = "http://${cfg.sandboxBackendHost}:${toString backendPort}";

  databaseUrl = "postgres://${dbUser}@127.0.0.1:5432/${dbName}?sslmode=disable";

  # Host path of the persistent MULTICA_TOKEN env file (written by the backend container
  # into its bind-mounted /app/secrets); every sandbox gets it via --env-file.
  tokenEnvFile = "/var/lib/multica/secrets/multica.env";

  # Generate JWT_SECRET inside container on first run, persist via bind mount.
  # Uses #!/bin/sh for Alpine compatibility (Nix bash path doesn't exist in container).
  multicaBackendEntrypoint = pkgs.writeTextFile {
    name = "multica-backend-entrypoint";
    executable = true;
    text = ''
      #!/bin/sh
      set -eu
      SECRET_FILE=/app/secrets/jwt_secret
      if [ ! -s "$SECRET_FILE" ]; then
        head -c 32 /dev/urandom | xxd -p -c 256 > "$SECRET_FILE"
        chmod 600 "$SECRET_FILE"
      fi
      export JWT_SECRET="$(cat "$SECRET_FILE")"
      exec ./entrypoint.sh "$@"
    '';
  };

  mkSandboxImage = name: extraPkgs: pkgs.dockerTools.buildLayeredImage {
    name = "multica-sandbox-${name}";
    tag = "latest";
    contents = [
      pkgs.bash
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      pkgs.cacert
      pkgs.git
      cliPackage
      pkgs.claude-code
    ] ++ extraPkgs;
    extraCommands = ''
      mkdir -p app/workspace
      mkdir -p tmp
      chmod 1777 tmp
    '';
    config = {
      Cmd = [
        "sh" "-c"
        "multica login --token \"$MULTICA_TOKEN\" && exec multica daemon start --foreground"
      ];
      WorkingDir = "/app/workspace";
      Env = [ "HOME=/root" ];
    };
  };

  jsonFormat = pkgs.formats.json { };

  reconcileManifest = jsonFormat.generate "multica-reconcile.json" {
    skills = lib.mapAttrsToList
      (name: skill: {
        inherit name;
        inherit (skill) description;
        config = skill.settings;
        body = skill.text;
        files = lib.mapAttrsToList
          (path: file: { inherit path; content = file.text; })
          skill.files;
      })
      cfg.skills;

    agents = lib.mapAttrsToList
      (name: agent: {
        inherit name;
        inherit (agent) description runtime model skills instructions env thinking;
      })
      cfg.agents;

    squads = lib.mapAttrsToList
      (name: squad: {
        inherit name;
        inherit (squad) description leader instructions;
        members = lib.mapAttrsToList
          (agentName: m: { agent = agentName; inherit (m) role; })
          squad.members;
      })
      cfg.squads;

    quickActions = lib.mapAttrsToList
      (name: qa: {
        inherit name;
        inherit (qa) description prompt assignee;
      })
      cfg.quickActions;

    autopilots = lib.mapAttrsToList
      (title: ap: {
        inherit title;
        inherit (ap) description agent mode;
        triggers = lib.mapAttrsToList
          (label: t: { inherit label; inherit (t) cron timezone enabled; })
          ap.triggers;
      })
      cfg.autopilots;
  };

  reconcile = pkgs.writeShellApplication {
    name = "multica-reconcile";
    runtimeInputs = [ cliPackage pkgs.jq pkgs.curl pkgs.coreutils ];
    text = ''
      manifest="$1"

      for _ in $(seq 1 60); do
        if curl -fsS "''${MULTICA_SERVER_URL}/health" >/dev/null 2>&1; then
          break
        fi
        sleep 2
      done

      if [ -z "''${MULTICA_TOKEN:-}" ]; then
        sent=0
        # send-code is rate-limited per email (~1/min); retry long enough to outlast
        # one window in case another login (or a prior reconcile) just used the quota.
        for _ in $(seq 1 12); do
          status=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
            -d ${lib.escapeShellArg (builtins.toJSON { email = cfg.devLoginEmail; })} \
            "''${MULTICA_SERVER_URL}/auth/send-code")
          if [ "$status" = "200" ]; then sent=1; break; fi
          sleep 10
        done
        if [ "$sent" != "1" ]; then
          echo "multica-reconcile: could not request a dev login code (rate limited?); skipping." >&2
          exit 0
        fi
        jwt=$(curl -fsS -X POST -H 'Content-Type: application/json' \
          -d ${lib.escapeShellArg (builtins.toJSON { email = cfg.devLoginEmail; code = devVerificationCode; })} \
          "''${MULTICA_SERVER_URL}/auth/verify-code" | jq -r '.token // empty')
        if [ -z "$jwt" ]; then
          echo "multica-reconcile: dev login failed (no token in verify-code response)." >&2
          exit 1
        fi
        MULTICA_TOKEN="$jwt"
        export MULTICA_TOKEN
      fi

      if [ -z "''${MULTICA_WORKSPACE_ID:-}" ]; then
        count=$(multica workspace list --output json | jq 'length')
        if [ "$count" = "0" ]; then
          echo "multica-reconcile: creating workspace ${workspaceName}"
          multica workspace create \
            --name ${lib.escapeShellArg workspaceName} \
            --slug ${lib.escapeShellArg workspaceSlug} \
            --output json >/dev/null
          count=$(multica workspace list --output json | jq 'length')
        fi
        if [ "$count" != "1" ]; then
          echo "multica-reconcile: token sees $count workspaces (expected exactly one)." >&2
          exit 1
        fi
        MULTICA_WORKSPACE_ID=$(multica workspace list --output json | jq -r '.[0].id')
        export MULTICA_WORKSPACE_ID
      fi

      existing=$(multica skill list --output json)

      jq -c '.skills[]' "$manifest" | while read -r skill; do
        name=$(jq -r '.name' <<<"$skill")
        description=$(jq -r '.description' <<<"$skill")
        body=$(jq -r '.body' <<<"$skill")
        config=$(jq -c '.config' <<<"$skill")

        body_tmp=$(mktemp)
        printf '%s' "$body" > "$body_tmp"
        args=(--description "$description" --content-file "$body_tmp")
        if [ "$config" != "{}" ] && [ "$config" != "null" ]; then
          args+=(--config "$config")
        fi

        id=$(jq -r --arg n "$name" 'map(select(.name == $n)) | (.[0].id // empty)' <<<"$existing")

        if [ -n "$id" ]; then
          echo "multica-reconcile: updating $name ($id)"
          multica skill update "$id" "''${args[@]}" >/dev/null
        else
          echo "multica-reconcile: creating $name"
          id=$(multica skill create --name "$name" "''${args[@]}" --output json | jq -r '.id')
        fi
        rm -f "$body_tmp"

        jq -c '.files[]' <<<"$skill" | while read -r file; do
          path=$(jq -r '.path' <<<"$file")
          content=$(jq -r '.content' <<<"$file")
          content_tmp=$(mktemp)
          printf '%s' "$content" > "$content_tmp"
          echo "multica-reconcile: upserting file $name/$path"
          multica skill files upsert "$id" --path "$path" --content-file "$content_tmp" >/dev/null
          rm -f "$content_tmp"
        done
      done

      reconcile_agents_squads() {
        want_agents=$(jq '.agents | length' "$manifest")
        want_squads=$(jq '.squads | length' "$manifest")
        if [ "$want_agents" = "0" ] && [ "$want_squads" = "0" ]; then
          return 0
        fi

        runtimes=$(multica runtime list --output json)
        rt_count=$(jq 'length' <<<"$runtimes")
        if [ "$rt_count" = "0" ]; then
          echo "multica-reconcile: no runtimes registered; waiting for daemon to start..." >&2
          for i in $(seq 1 30); do
            sleep 10
            runtimes=$(multica runtime list --output json)
            rt_count=$(jq 'length' <<<"$runtimes")
            if [ "$rt_count" != "0" ]; then
              echo "multica-reconcile: runtime registered after $((i * 10))s; proceeding with agents/squads." >&2
              break
            fi
          done
          if [ "$rt_count" = "0" ]; then
            echo "multica-reconcile: no runtimes registered (start a multica daemon); skipping agents and squads." >&2
            return 0
          fi
        fi

        skills_all=$(multica skill list --output json)
        existing_agents=$(multica agent list --output json)

        jq -c '.agents[]' "$manifest" | while read -r agent; do
          name=$(jq -r '.name' <<<"$agent")

          rt=$(jq -r '.runtime // empty' <<<"$agent")
          if [ -n "$rt" ]; then
            # Sandbox runtimes match on daemon_id = sandbox-<name>.
            # Host runtimes match on daemon_id = host-<name> or id/name fields.
            # This allows runtime names like "hermes" to resolve to their daemon registration.
            rtid=$(jq -r --arg r "$rt" 'map(select(.daemon_id == ("sandbox-" + $r) or .daemon_id == ("host-" + $r) or .id == $r or .name == $r)) | sort_by(.status != "online") | (.[0].id // empty)' <<<"$runtimes")
          elif [ "$rt_count" = "1" ]; then
            rtid=$(jq -r '.[0].id' <<<"$runtimes")
          else
            echo "multica-reconcile: agent $name has no runtime set and $rt_count runtimes exist; set services.multica.agents.$name.runtime." >&2
            exit 1
          fi
          if [ -z "$rtid" ]; then
            echo "multica-reconcile: agent $name runtime '$rt' not found." >&2
            exit 1
          fi

          args=(--visibility workspace)
          v=$(jq -r '.description' <<<"$agent");            [ -n "$v" ] && args+=(--description "$v")
          v=$(jq -r '.instructions // empty' <<<"$agent");  [ -n "$v" ] && args+=(--instructions "$v")
          v=$(jq -r '.model // empty' <<<"$agent");         [ -n "$v" ] && args+=(--model "$v")
          v=$(jq -r '.thinking // empty' <<<"$agent");      [ -n "$v" ] && args+=(--thinking-level "$v")

          id=$(jq -r --arg n "$name" 'map(select(.name == $n)) | (.[0].id // empty)' <<<"$existing_agents")
          if [ -n "$id" ]; then
            echo "multica-reconcile: updating agent $name ($id)"
            multica agent update "$id" --runtime-id "$rtid" "''${args[@]}" >/dev/null
          else
            all_agents=$(multica agent list --include-archived --output json)
            archived_id=$(jq -r --arg n "$name" 'map(select(.name == $n)) | (.[0].id // empty)' <<<"$all_agents")
            if [ -n "$archived_id" ]; then
              echo "multica-reconcile: restoring archived agent $name ($archived_id)"
              multica agent restore "$archived_id" >/dev/null
              id="$archived_id"
              multica agent update "$id" --runtime-id "$rtid" "''${args[@]}" >/dev/null
            else
              echo "multica-reconcile: creating agent $name"
              id=$(multica agent create --name "$name" --runtime-id "$rtid" "''${args[@]}" --output json | jq -r '.id')
            fi
          fi

          skill_ids=$(jq -r --slurpfile all <(printf '%s' "$skills_all") '[ .skills[] as $n | ($all[0][] | select(.name == $n) | .id) ] | join(",")' <<<"$agent")
          multica agent skills set "$id" --skill-ids "$skill_ids" >/dev/null

          env_want=$(jq -c '.env // {}' <<<"$agent")
          if [ "$env_want" != "{}" ]; then
            env_current=$(multica agent env get "$id" --output json | jq -c '.custom_env // {}')
            env_merged=$(jq -c -n --argjson cur "$env_current" --argjson want "$env_want" '$cur * $want')
            env_tmp=$(mktemp)
            printf '%s' "$env_merged" > "$env_tmp"
            echo "multica-reconcile: setting custom env for agent $name ($id)"
            multica agent env set "$id" --custom-env-file "$env_tmp" >/dev/null
            rm -f "$env_tmp"
          fi
        done

        existing_agents=$(multica agent list --output json)
        existing_squads=$(multica squad list --output json)

        jq -c '.squads[]' "$manifest" | while read -r squad; do
          name=$(jq -r '.name' <<<"$squad")
          leader=$(jq -r '.leader' <<<"$squad")
          leader_id=$(jq -r --arg l "$leader" 'map(select(.name == $l or .id == $l)) | (.[0].id // empty)' <<<"$existing_agents")
          if [ -z "$leader_id" ]; then
            echo "multica-reconcile: squad $name leader '$leader' not found." >&2
            exit 1
          fi
          description=$(jq -r '.description' <<<"$squad")
          instr=$(jq -r '.instructions // empty' <<<"$squad")

          sid=$(jq -r --arg n "$name" 'map(select(.name == $n)) | (.[0].id // empty)' <<<"$existing_squads")
          if [ -n "$sid" ]; then
            echo "multica-reconcile: updating squad $name ($sid)"
            uargs=(--leader "$leader_id")
            [ -n "$description" ] && uargs+=(--description "$description")
            [ -n "$instr" ] && uargs+=(--instructions "$instr")
            multica squad update "$sid" "''${uargs[@]}" >/dev/null
          else
            echo "multica-reconcile: creating squad $name"
            cargs=(--name "$name" --leader "$leader_id")
            [ -n "$description" ] && cargs+=(--description "$description")
            sid=$(multica squad create "''${cargs[@]}" --output json | jq -r '.id')
            [ -n "$instr" ] && multica squad update "$sid" --instructions "$instr" >/dev/null
          fi

          current=$(multica squad member list "$sid" --output json)
          jq -c '.members[]' <<<"$squad" | while read -r m; do
            magent=$(jq -r '.agent' <<<"$m")
            mrole=$(jq -r '.role' <<<"$m")
            maid=$(jq -r --arg a "$magent" 'map(select(.name == $a or .id == $a)) | (.[0].id // empty)' <<<"$existing_agents")
            if [ -z "$maid" ]; then
              echo "multica-reconcile: squad $name member '$magent' not found." >&2
              exit 1
            fi
            [ "$maid" = "$leader_id" ] && continue
            cur_role=$(jq -r --arg id "$maid" 'map(select(.member_id == $id)) | (.[0].role // empty)' <<<"$current")
            if [ -z "$cur_role" ]; then
              echo "multica-reconcile: squad $name add member $magent"
              multica squad member add "$sid" --member-id "$maid" --role "$mrole" --type agent >/dev/null
            elif [ "$cur_role" != "$mrole" ]; then
              multica squad member set-role "$sid" --member-id "$maid" --role "$mrole" --member-type agent >/dev/null
            fi
          done
        done
      }
      reconcile_agents_squads

      want_qa=$(jq '.quickActions | length' "$manifest")
      if [ "$want_qa" != "0" ]; then
        qa_agents=$(multica agent list --output json)
        qa_squads=$(multica squad list --output json)
        qa_existing=$(curl -fsS \
          -H "Authorization: Bearer $MULTICA_TOKEN" \
          -H "X-Workspace-Id: $MULTICA_WORKSPACE_ID" \
          "$MULTICA_SERVER_URL/api/quick-actions" | jq '.quick_actions // []')

        jq -c '.quickActions[]' "$manifest" | while read -r qa; do
          name=$(jq -r '.name' <<<"$qa")
          desc=$(jq -r '.description' <<<"$qa")
          prompt=$(jq -r '.prompt' <<<"$qa")
          assignee=$(jq -r '.assignee' <<<"$qa")
          vis="private"

          aid=$(jq -r --arg a "$assignee" 'map(select(.name == $a or .id == $a)) | (.[0].id // empty)' <<<"$qa_agents")
          if [ -n "$aid" ]; then
            atype="agent"
          else
            aid=$(jq -r --arg a "$assignee" 'map(select(.name == $a or .id == $a)) | (.[0].id // empty)' <<<"$qa_squads")
            atype="squad"
          fi
          if [ -z "$aid" ]; then
            echo "multica-reconcile: quick action $name assignee '$assignee' not found; skipping." >&2
            continue
          fi

          body=$(jq -n --arg n "$name" --arg d "$desc" --arg p "$prompt" \
            --arg aid "$aid" --arg at "$atype" --arg v "$vis" \
            '{name:$n, description:$d, prompt:$p, assignee_id:$aid, assignee_type:$at, visibility:$v}')

          id=$(jq -r --arg n "$name" 'map(select(.name == $n)) | (.[0].id // empty)' <<<"$qa_existing")
          if [ -n "$id" ]; then
            echo "multica-reconcile: updating quick action $name ($id)"
            resp=$(curl -sS -w '\n%{http_code}' -X PATCH \
              -H "Authorization: Bearer $MULTICA_TOKEN" \
              -H "X-Workspace-Id: $MULTICA_WORKSPACE_ID" \
              -H 'Content-Type: application/json' \
              -d "$body" "$MULTICA_SERVER_URL/api/quick-actions/$id")
            code=$(tail -n1 <<<"$resp")
            if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
              echo "multica-reconcile: failed to update quick action $name (HTTP $code): $(sed '$d' <<<"$resp")" >&2
            fi
          else
            echo "multica-reconcile: creating quick action $name"
            resp=$(curl -sS -w '\n%{http_code}' -X POST \
              -H "Authorization: Bearer $MULTICA_TOKEN" \
              -H "X-Workspace-Id: $MULTICA_WORKSPACE_ID" \
              -H 'Content-Type: application/json' \
              -d "$body" "$MULTICA_SERVER_URL/api/quick-actions")
            code=$(tail -n1 <<<"$resp")
            if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
              echo "multica-reconcile: failed to create quick action $name (HTTP $code): $(sed '$d' <<<"$resp")" >&2
            fi
          fi
        done
      fi

      want_ap=$(jq '.autopilots | length' "$manifest")
      if [ "$want_ap" != "0" ]; then
        ap_agents=$(multica agent list --output json)
        ap_existing=$(multica autopilot list --output json | jq '.autopilots // .')

        jq -c '.autopilots[]' "$manifest" | while read -r ap; do
          title=$(jq -r '.title' <<<"$ap")
          description=$(jq -r '.description' <<<"$ap")
          agent=$(jq -r '.agent' <<<"$ap")
          mode=$(jq -r '.mode' <<<"$ap")

          aid=$(jq -r --arg a "$agent" 'map(select(.name == $a or .id == $a)) | (.[0].id // empty)' <<<"$ap_agents")
          if [ -z "$aid" ]; then
            echo "multica-reconcile: autopilot $title agent '$agent' not found; skipping." >&2
            continue
          fi

          args=(--description "$description" --agent "$aid" --mode "$mode")

          id=$(jq -r --arg t "$title" 'map(select(.title == $t)) | (.[0].id // empty)' <<<"$ap_existing")
          if [ -n "$id" ]; then
            echo "multica-reconcile: updating autopilot $title ($id)"
            multica autopilot update "$id" --title "$title" "''${args[@]}" >/dev/null
          else
            echo "multica-reconcile: creating autopilot $title"
            id=$(multica autopilot create --title "$title" "''${args[@]}" --output json | jq -r '.id')
          fi

          existing_triggers=$(multica autopilot trigger-list "$id" --output json | jq '.triggers // .')
          jq -c '.triggers[]' <<<"$ap" | while read -r tr; do
            label=$(jq -r '.label' <<<"$tr")
            cron=$(jq -r '.cron' <<<"$tr")
            tz=$(jq -r '.timezone' <<<"$tr")
            enabled=$(jq -r '.enabled' <<<"$tr")
            if [ "$enabled" = "true" ]; then eflag=--enabled; else eflag=--enabled=false; fi

            tid=$(jq -r --arg l "$label" 'map(select(.label == $l)) | (.[0].id // empty)' <<<"$existing_triggers")
            if [ -n "$tid" ]; then
              echo "multica-reconcile: updating autopilot $title trigger $label"
              multica autopilot trigger-update "$id" "$tid" \
                --cron "$cron" --timezone "$tz" --label "$label" "$eflag" >/dev/null
            else
              echo "multica-reconcile: adding autopilot $title trigger $label"
              multica autopilot trigger-add "$id" --kind schedule \
                --cron "$cron" --timezone "$tz" --label "$label" >/dev/null
              if [ "$enabled" != "true" ]; then
                tid=$(multica autopilot trigger-list "$id" --output json \
                  | jq -r --arg l "$label" '(.triggers // .) | map(select(.label == $l)) | (.[0].id // empty)')
                [ -n "$tid" ] && multica autopilot trigger-update "$id" "$tid" --enabled=false >/dev/null
              fi
            fi
          done

        done
      fi

      # Provision per-sandbox authentication tokens. Each sandbox gets a unique real PAT
      # (personal access token) that it reads from its own env file before starting the daemon.
      # This runs after dev-mode login (so $MULTICA_TOKEN is a valid JWT) and creates
      # sandbox tokens only once per rebuild, named sandbox-<name> to match the convention.
      if [ -n "''${MULTICA_TOKEN:-}" ] && [ -n "''${MULTICA_SANDBOX_NAMES:-}" ]; then
        echo "multica-reconcile: provisioning sandbox tokens for: $MULTICA_SANDBOX_NAMES"
        for sandbox_name in $MULTICA_SANDBOX_NAMES; do
          token_file="/var/lib/multica/secrets/sandbox-$sandbox_name.env"
          token_id_marker="/var/lib/multica/secrets/.sandbox-$sandbox_name.id"

          # Check if we already have a valid token for this sandbox (to avoid creating
          # a new one on every rebuild, which would clutter the token list).
          if [ -f "$token_file" ] && [ -f "$token_id_marker" ]; then
            echo "multica-reconcile: sandbox $sandbox_name token already provisioned (skipping)."
            continue
          fi

          echo "multica-reconcile: provisioning token for sandbox $sandbox_name"

          # Create a real PAT via the backend's token API using the dev JWT.
          # The response includes the full token string (only returned on creation, not on GET).
          token_response=$(curl -fsS -X POST \
            -H "Authorization: Bearer $MULTICA_TOKEN" \
            -H "X-Workspace-Id: $MULTICA_WORKSPACE_ID" \
            -H 'Content-Type: application/json' \
            -d "{\"name\":\"sandbox-$sandbox_name\"}" \
            "''${MULTICA_SERVER_URL}/api/tokens")

          token=$(jq -r '.token // empty' <<<"$token_response")
          token_id=$(jq -r '.id // empty' <<<"$token_response")

          if [ -z "$token" ] || [ -z "$token_id" ]; then
            echo "multica-reconcile: failed to create token for sandbox $sandbox_name" >&2
            echo "Response: $token_response" >&2
            continue
          fi

          # Write the token to a file the sandbox container will read via environmentFile.
          # Use mode 600 to match the security of the old shared token file.
          printf 'MULTICA_TOKEN=%s\n' "$token" > "$token_file"
          chmod 600 "$token_file"

          # Mark this sandbox as provisioned so we don't create a new token on next rebuild.
          echo "$token_id" > "$token_id_marker"
          chmod 600 "$token_id_marker"
        done
      fi

      echo "multica-reconcile: reconcile complete"
    '';
  };
in
{
  options.services.multica = {
    enable = lib.mkEnableOption "the self-hosted Multica server";

    installDesktop = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to put the Multica desktop client on PATH. Linux only.";
    };

    sandboxBackendHost = lib.mkOption {
      type = lib.types.str;
      example = "192.168.1.10";
      description = ''
        Host address the sandbox containers use to reach the backend. Sandboxes run on
        Docker's bridge network, so this must be an address of the host that is reachable
        from containers (e.g. its LAN IP) — not localhost. Required when `sandboxes` is set.
      '';
    };

    backendImageFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Optional pre-fetched backend image tarball (e.g. from `dockerTools.pullImage`)
        to load instead of pulling from the registry. Used by tests for offline operation
        (tests run in sandboxed VMs with no network access and need this to avoid pull failures).
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/multica/env";
      description = ''
        Path to an env file (KEY=VALUE lines) read at runtime, kept OUT of the Nix
        store. JWT_SECRET is auto-generated inside the backend container.
        Use this file for any other secrets/integration vars (e.g. MULTICA_TOKEN).
      '';
    };

    devLoginEmail = lib.mkOption {
      type = lib.types.str;
      default = "admin@multica.local";
      description = ''
        Identity the skills reconciler logs in as (via `devMode` login) to obtain a
        token when `MULTICA_TOKEN` is unset. Log in to the desktop app with this
        same email to see the workspace and skills it manages.
      '';
    };

    skills = lib.mkOption {
      default = { };
      description = ''
        Declarative Multica skills. The attribute name is the skill's name (its
        identity). Declared skills are created or updated to match on each rebuild;
        deletion is left to the user.

        Reconciliation authenticates via passwordless dev-mode login (see
        `devLoginEmail`).
      '';
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          description = lib.mkOption {
            type = lib.types.str;
            description = "Skill description shown in Multica.";
          };
          text = lib.mkOption {
            type = lib.types.lines;
            description = "Inline SKILL.md markdown body.";
          };
          settings = lib.mkOption {
            type = jsonFormat.type;
            default = { };
            description = "Optional skill config, serialised to JSON (the CLI's --config).";
          };
          files = lib.mkOption {
            default = { };
            description = "Extra files bundled with the skill, keyed by their path within the skill.";
            type = lib.types.attrsOf (lib.types.submodule {
              options.text = lib.mkOption {
                type = lib.types.lines;
                description = "Inline file body.";
              };
            });
          };
        };
      }));
    };

    agents = lib.mkOption {
      default = { };
      description = ''
        Declarative Multica agents, reconciled into the workspace on rebuild (after
        skills). The attribute name is the agent's name. The workspace is fully owned
        by this config: declared agents are created or updated; agents not declared
        here are **archived** from the workspace on the next rebuild. Archived agents
        can be re-declared (they are restored rather than duplicated).

        Agents need a runtime, which is registered by a running `multica daemon` (not
        declarative). Reference one with `runtime`; if the workspace has exactly one,
        it is used automatically. With no runtimes, agents and squads are skipped.
      '';
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          description = lib.mkOption {
            type = lib.types.str;
            description = "Agent description.";
          };
          instructions = lib.mkOption {
            type = lib.types.nullOr lib.types.lines;
            default = null;
            description = "System instructions for the agent.";
          };
          runtime = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Runtime to run the agent on: a sandbox name from `sandboxes` (matched on the
              daemon id that sandbox registers with), or a runtime display name / id from
              `multica runtime list`. Null uses the sole runtime, and fails if there is more
              than one.
            '';
          };
          model = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Model identifier (e.g. claude-sonnet-4-6). Null = runtime default.";
          };
          thinking = lib.mkOption {
            type = lib.types.enum [ "low" "medium" "high" "xhigh" "max" ];
            default = "low";
            description = ''
              Reasoning/effort level for the agent's runtime, passed as
              `--thinking-level`. Claude-specific levels only (low|medium|high|xhigh|max);
              other runtimes may reject this value. Defaults to the lowest level.
            '';
          };
          skills = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = ''
              Skill names to assign to this agent (from `skills` or already in the
              workspace). Declared skills are added or updated; removal is manual.
            '';
          };
          env = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = ''
              Per-agent environment variables, reconciled into this agent's Multica
              `custom_env` (visible and editable in the Multica desktop app under the
              agent's settings) rather than baked into the sandbox container's OS
              environment at container-start time. Multica injects `custom_env` into
              the actual process environment of tasks the agent runs, so values are
              live at runtime the same way container env vars were, but changes take
              effect via reconcile (e.g. `make rebuild`) rather than requiring a
              container restart. The reconciler merges these values into any existing
              custom_env the agent already has (e.g. its `MULTICA_TOKEN`) rather than
              replacing it outright; keys declared here always win over the same key
              in the existing custom_env.

              Values are read from the current shell environment via builtins.getEnv,
              so use direnv or export variables before running `nix flake show` or `make rebuild`.
              Example: { MY_VAR = builtins.getEnv "MY_VAR"; ANOTHER_VAR = "literal-value"; }
            '';
          };
        };
      }));
    };

    squads = lib.mkOption {
      default = { };
      description = ''
        Declarative Multica squads, reconciled after agents. The attribute name is the
        squad's name. Declared squads are created or updated on each rebuild; squad
        deletion and archival are left to the user. Members are added or updated to
        match the declared set. The leader is automatically a member — do not list it
        under `members`.
      '';
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          description = lib.mkOption {
            type = lib.types.str;
            description = "Squad description.";
          };
          instructions = lib.mkOption {
            type = lib.types.nullOr lib.types.lines;
            default = null;
            description = "Squad instructions.";
          };
          leader = lib.mkOption {
            type = lib.types.str;
            description = "Leader agent, by name or id (required).";
          };
          members = lib.mkOption {
            default = { };
            description = "Squad members, keyed by agent name (excluding the leader).";
            type = lib.types.attrsOf (lib.types.submodule {
              options.role = lib.mkOption {
                type = lib.types.str;
                description = "Member's role in the squad.";
              };
            });
          };
        };
      }));
    };

    quickActions = lib.mkOption {
      default = { };
      description = ''
        Declarative Multica quick actions — named prompts that dispatch to an agent or
        squad. Reconciled after agents/squads (so they can reference ones you declare).
        Declared quick actions are created or updated on each rebuild; deletion is left
        to the user.

        Quick actions have no CLI, so the reconciler drives the REST API directly.
      '';
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          description = lib.mkOption {
            type = lib.types.str;
            description = "Quick action description.";
          };
          prompt = lib.mkOption {
            type = lib.types.lines;
            description = "The prompt run when the action is triggered (required).";
          };
          assignee = lib.mkOption {
            type = lib.types.str;
            description = "Agent or squad that runs the action, by name or id (required).";
          };
        };
      }));
    };

    autopilots = lib.mkOption {
      default = { };
      description = ''
        Declarative Multica autopilots — scheduled/triggered agent automations.
        Reconciled after agents/squads (so they can reference agents you declare).
        The attribute name is the autopilot's title (its identity). Declared
        autopilots are created or updated on each rebuild; deletion is left to the
        user.

        Each autopilot dispatches to an assignee `agent`, which needs a runtime
        (registered by a running `multica daemon`). Without the agent present,
        the autopilot is skipped, just like quick actions.

        Only schedule (cron) triggers are declarative here; webhook triggers are
        managed manually with `multica autopilot trigger-add`. Declared triggers are
        upserted by label; removal is manual.
      '';
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          description = lib.mkOption {
            type = lib.types.lines;
            description = "Autopilot description, used as the run prompt (required).";
          };
          agent = lib.mkOption {
            type = lib.types.str;
            description = "Assignee agent that runs the autopilot, by name or id (required).";
          };
          mode = lib.mkOption {
            type = lib.types.enum [ "create_issue" "run_only" ];
            description = ''
              Execution mode: `run_only` just runs the agent; `create_issue` files an
              issue for each run.
            '';
          };
          triggers = lib.mkOption {
            description = ''
              Schedule (cron) triggers, keyed by label (the label is the identity).
              Upserted on each reconcile; removal is manual.
            '';
            type = lib.types.attrsOf (lib.types.submodule {
              options = {
                cron = lib.mkOption {
                  type = lib.types.str;
                  description = "Cron expression for the schedule (required).";
                };
                timezone = lib.mkOption {
                  type = lib.types.str;
                  description = "IANA timezone the cron expression is evaluated in.";
                };
                enabled = lib.mkOption {
                  type = lib.types.bool;
                  description = "Whether the trigger is enabled.";
                };
              };
            });
          };
        };
      }));
    };

    sandboxes = lib.mkOption {
      default = { };
      description = ''
        Declarative isolated agent-runtime sandboxes. Attribute name is the sandbox name.
        Each sandbox runs in its own OCI container with Claude Code installed and a running
        `multica daemon`, which auto-registers as a runtime with the backend. Agents can then
        reference sandboxes by name via their `runtime` field.

        Process and filesystem isolation is provided by container boundaries.
        Networking is shared with the host (`--network=host`), so sandboxes are
        not network-isolated from the host or each other.
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          extraPackages = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = [ ];
            description = ''
              Additional Nix packages to install in this sandbox's image
              (e.g., [ pkgs.gh pkgs.jq ]).
            '';
          };
          volumeMounts = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = ''
              Docker-style bind mounts ("host:container" or "host:container:ro"), passed
              to the oci-container's volumes list for persistent workspace storage.
            '';
          };
          environmentFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = ''
              Path to a file containing environment variables to pass to the sandbox container.
              Used for secrets that should not be baked into the Nix store.
            '';
          };
          environment = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
            description = ''
              Environment variables to pass to the sandbox container.
              These are merged with any variables from environmentFile.
            '';
          };
        };
      });
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      environment.systemPackages = [ cliPackage ]
        ++ lib.optional (cfg.installDesktop && pkgs.stdenv.hostPlatform.isLinux) desktopPkg;

      services.postgresql = {
        enable = true;
        package = pkgs.postgresql_17;
        extensions = ps: [ ps.pgvector ];
        ensureDatabases = [ dbName ];
        ensureUsers = [{
          name = dbUser;
          ensureDBOwnership = true;
        }];
        authentication = lib.mkAfter ''
          host ${dbName} ${dbUser} 127.0.0.1/32 trust
          host ${dbName} ${dbUser} ::1/128      trust
        '';
      };

      systemd.services.multica-db-init = {
        description = "Create pgvector extension for Multica";
        after = [ "postgresql.service" "postgresql-setup.service" ];
        requires = [ "postgresql.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          RemainAfterExit = true;
        };
        script = ''
          ${config.services.postgresql.package}/bin/psql -d ${dbName} \
            -tAc "CREATE EXTENSION IF NOT EXISTS vector;"
        '';
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/multica 0750 root root -"
        "d /var/lib/multica/uploads 0750 root root -"
        "d /var/lib/multica/secrets 0700 root root -"
        "f /var/lib/multica/env 0644 root root -"
      ];

      virtualisation.oci-containers.backend = "docker";

      virtualisation.oci-containers.containers = {
          multica-backend = {
            image = defaultBackendImage;
            imageFile = cfg.backendImageFile;
            entrypoint = "/entrypoint-wrapper.sh";
            environment = {
              DATABASE_URL = databaseUrl;
              PORT = toString backendPort;
              APP_ENV = "development";
              MULTICA_DEV_MODE = "1";
              # Pin the dev login code; the backend otherwise generates a random one
              # per run, which would break the reconciler's passwordless dev login.
              MULTICA_DEV_VERIFICATION_CODE = devVerificationCode;
            };
            environmentFiles = [ cfg.environmentFile ];
            volumes = [
              "${multicaBackendEntrypoint}:/entrypoint-wrapper.sh:ro"
              "/var/lib/multica/secrets:/app/secrets"
              "/var/lib/multica/uploads:/app/data/uploads"
              "tmp:/tmp"
            ];
            extraOptions = [ "--network=host" ];
          };
        } // lib.mapAttrs'
          (name: sandbox:
            lib.nameValuePair "multica-sandbox-${name}" {
              image = "multica-sandbox-${name}:latest";
              imageFile = mkSandboxImage name sandbox.extraPackages;
              environment = {
                MULTICA_SERVER_URL = sandboxBackendUrl;
                MULTICA_DAEMON_DEVICE_NAME = name;
                MULTICA_DAEMON_ID = "sandbox-${name}";
                MULTICA_AGENT_RUNTIME_NAME = name;
                IS_SANDBOX = "1";
              } // sandbox.environment;
              # MULTICA_TOKEN is provisioned per-sandbox by the reconcile script into
              # /var/lib/multica/secrets/sandbox-<name>.env before sandboxes start.
              environmentFiles = [ "/var/lib/multica/secrets/sandbox-${name}.env" ]
                ++ lib.optional (sandbox.environmentFile != null) sandbox.environmentFile;
              volumes = [ "tmp-${name}:/tmp" ] ++ sandbox.volumeMounts;
            }
          )
          cfg.sandboxes;

      systemd.services.docker-multica-backend = {
        after = [ "postgresql.service" "multica-db-init.service" ];
        requires = [ "postgresql.service" "multica-db-init.service" ];
      };

      systemd.services.multica-reconcile = {
        description = "Reconcile declarative Multica resources (create-or-update only)";
        after = [ "docker-multica-backend.service" ];
        requires = [ "docker-multica-backend.service" ];
        wantedBy = [ "multi-user.target" ];
        restartTriggers = [ reconcileManifest ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          EnvironmentFile = cfg.environmentFile;
          StateDirectory = "multica-reconcile";
          Environment = [
            "HOME=%S/multica-reconcile"
            "MULTICA_SERVER_URL=${backendUrl}"
            "MULTICA_SANDBOX_NAMES=${lib.concatStringsSep " " (lib.attrNames cfg.sandboxes)}"
          ];
          Restart = "on-failure";
          RestartSec = 15;
        };
        script = "${lib.getExe reconcile} ${reconcileManifest}";
      };
    }
    (lib.mkIf (cfg.sandboxes != { }) {
      systemd.services = lib.mapAttrs'
        (name: _sandbox:
          lib.nameValuePair "docker-multica-sandbox-${name}" {
            after = [ "docker-multica-backend.service" "multica-reconcile.service" ];
            requires = [ "docker-multica-backend.service" "multica-reconcile.service" ];
          }
        )
        cfg.sandboxes;
    })
  ]);
}
