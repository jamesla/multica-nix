{ config, lib, pkgs, ... }:

let
  cfg = config.services.multica;

  defaultBackendImage = "ghcr.io/multica-ai/multica-backend@sha256:a1c1053fc014b967ae33404eae5a6f725a4befa416e5c9fc657a4b6103f34723";

  backendUrl = "http://${cfg.host}:${toString cfg.backendPort}";

  databaseUrl = "postgres://${cfg.database.user}@127.0.0.1:5432/${cfg.database.name}?sslmode=disable";

  # Entrypoint wrapper for multica-backend: generates JWT_SECRET inside the
  # container on first run (stored at /app/secrets/jwt_secret), idempotently
  # reuses it on subsequent starts (via persistent bind mount).
  # Uses #!/bin/sh shebang for Alpine container compatibility.
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

  jsonFormat = pkgs.formats.json { };

  bodyPath = name: entry:
    if entry.source != null
    then entry.source
    else pkgs.writeText "multica-skill-${name}" entry.text;

  textFile = name: s: pkgs.writeText name s;

  reconcileManifest = jsonFormat.generate "multica-reconcile.json" {
    skills = lib.mapAttrsToList
      (name: skill: {
        inherit name;
        inherit (skill) description;
        config = skill.settings;
        body = bodyPath name skill;
        files = lib.mapAttrsToList
          (path: file: { inherit path; content = bodyPath "${name}-file" file; })
          skill.files;
      })
      cfg.skills;

    agents = lib.mapAttrsToList
      (name: agent: {
        inherit name;
        inherit (agent) description runtime model thinkingLevel visibility
          maxConcurrentTasks skills customArgs runtimeConfig customEnvFile mcpConfigFile;
        instructions =
          if agent.instructions != null
          then textFile "multica-agent-${name}-instructions" agent.instructions
          else null;
      })
      cfg.agents;

    squads = lib.mapAttrsToList
      (name: squad: {
        inherit name;
        inherit (squad) description leader;
        instructions =
          if squad.instructions != null
          then textFile "multica-squad-${name}-instructions" squad.instructions
          else null;
        members = lib.mapAttrsToList
          (agentName: m: { agent = agentName; inherit (m) role; })
          squad.members;
      })
      cfg.squads;

    quickActions = lib.mapAttrsToList
      (name: qa: {
        inherit name;
        inherit (qa) description prompt assignee assigneeType visibility;
      })
      cfg.quickActions;

    autopilots = lib.mapAttrsToList
      (title: ap: {
        inherit title;
        inherit (ap) description agent mode project issueTitleTemplate subscribers status;
        triggers = lib.mapAttrsToList
          (label: t: { inherit label; inherit (t) cron timezone enabled; })
          ap.triggers;
      })
      cfg.autopilots;
  };

  reconcile = pkgs.writeShellApplication {
    name = "multica-reconcile";
    runtimeInputs = [ cfg.package pkgs.jq pkgs.curl pkgs.coreutils ];
    text = ''
      manifest="$1"
      dev_mode=${if cfg.devMode then "1" else "0"}

      for _ in $(seq 1 60); do
        if curl -fsS "''${MULTICA_SERVER_URL}/health" >/dev/null 2>&1; then
          break
        fi
        sleep 2
      done

      if [ -z "''${MULTICA_TOKEN:-}" ]; then
        if [ "$dev_mode" = "1" ]; then
          sent=0
          for _ in $(seq 1 6); do
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
            -d ${lib.escapeShellArg (builtins.toJSON { email = cfg.devLoginEmail; code = cfg.devVerificationCode; })} \
            "''${MULTICA_SERVER_URL}/auth/verify-code" | jq -r '.token // empty')
          if [ -z "$jwt" ]; then
            echo "multica-reconcile: dev login failed (no token in verify-code response)." >&2
            exit 1
          fi
          MULTICA_TOKEN="$jwt"
          export MULTICA_TOKEN
        else
          echo "multica-reconcile: MULTICA_TOKEN not set — add a mul_… PAT to environmentFile to enable skill reconciliation. Skipping." >&2
          exit 0
        fi
      fi

      if [ -z "''${MULTICA_WORKSPACE_ID:-}" ]; then
        count=$(multica workspace list --output json | jq 'length')
        if [ "$count" = "0" ]; then
          if [ "$dev_mode" = "1" ]; then
            echo "multica-reconcile: creating workspace ${cfg.workspaceName}"
            multica workspace create \
              --name ${lib.escapeShellArg cfg.workspaceName} \
              --slug ${lib.escapeShellArg cfg.workspaceSlug} \
              --output json >/dev/null
            count=$(multica workspace list --output json | jq 'length')
          else
            echo "multica-reconcile: token has no workspaces." >&2
            exit 1
          fi
        fi
        if [ "$count" != "1" ]; then
          echo "multica-reconcile: token sees $count workspaces; set services.multica.workspaceId." >&2
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

        args=(--description "$description" --content-file "$body")
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

        jq -c '.files[]' <<<"$skill" | while read -r file; do
          path=$(jq -r '.path' <<<"$file")
          content=$(jq -r '.content' <<<"$file")
          echo "multica-reconcile: upserting file $name/$path"
          multica skill files upsert "$id" --path "$path" --content-file "$content" >/dev/null
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
          if [ "$dev_mode" = "1" ]; then
            echo "multica-reconcile: no runtimes registered; waiting for daemon to start (dev mode)..." >&2
            for i in $(seq 1 30); do
              sleep 10
              runtimes=$(multica runtime list --output json)
              rt_count=$(jq 'length' <<<"$runtimes")
              if [ "$rt_count" != "0" ]; then
                echo "multica-reconcile: runtime registered after $((i * 10))s; proceeding with agents/squads." >&2
                break
              fi
            done
          fi
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
            rtid=$(jq -r --arg r "$rt" 'map(select(.id == $r or .name == $r)) | (.[0].id // empty)' <<<"$runtimes")
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

          args=()
          v=$(jq -r '.description' <<<"$agent");            [ -n "$v" ] && args+=(--description "$v")
          v=$(jq -r '.instructions // empty' <<<"$agent");  [ -n "$v" ] && args+=(--instructions "$(cat "$v")")
          v=$(jq -r '.model // empty' <<<"$agent");         [ -n "$v" ] && args+=(--model "$v")
          v=$(jq -r '.thinkingLevel // empty' <<<"$agent"); [ -n "$v" ] && args+=(--thinking-level "$v")
          v=$(jq -r '.visibility // empty' <<<"$agent");    [ -n "$v" ] && args+=(--visibility "$v")
          v=$(jq -r '.maxConcurrentTasks // empty' <<<"$agent"); [ -n "$v" ] && args+=(--max-concurrent-tasks "$v")
          v=$(jq -c '.customArgs' <<<"$agent");    [ "$v" != "[]" ] && [ "$v" != "null" ] && args+=(--custom-args "$v")
          v=$(jq -c '.runtimeConfig' <<<"$agent"); [ "$v" != "{}" ] && [ "$v" != "null" ] && args+=(--runtime-config "$v")
          v=$(jq -r '.customEnvFile // empty' <<<"$agent"); [ -n "$v" ] && args+=(--custom-env-file "$v")
          v=$(jq -r '.mcpConfigFile // empty' <<<"$agent"); [ -n "$v" ] && args+=(--mcp-config-file "$v")

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
            [ -n "$instr" ] && uargs+=(--instructions "$(cat "$instr")")
            multica squad update "$sid" "''${uargs[@]}" >/dev/null
          else
            echo "multica-reconcile: creating squad $name"
            cargs=(--name "$name" --leader "$leader_id")
            [ -n "$description" ] && cargs+=(--description "$description")
            sid=$(multica squad create "''${cargs[@]}" --output json | jq -r '.id')
            [ -n "$instr" ] && multica squad update "$sid" --instructions "$(cat "$instr")" >/dev/null
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

          keep=$(jq -r --slurpfile agents <(printf '%s' "$existing_agents") '[ .members[].agent as $a | ($agents[0][] | select(.name == $a or .id == $a) | .id) ] | join(" ")' <<<"$squad")
          keep=" $leader_id $keep "
          jq -r '.[] | select(.role != "leader") | .member_id' <<<"$current" | while read -r mid; do
            case "$keep" in
              *" $mid "*) : ;;
              *)
                echo "multica-reconcile: squad $name remove member $mid"
                multica squad member remove "$sid" --member-id "$mid" --type agent >/dev/null
                ;;
            esac
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
          vis=$(jq -r '.visibility' <<<"$qa")
          atype=$(jq -r '.assigneeType' <<<"$qa")
          assignee=$(jq -r '.assignee' <<<"$qa")

          if [ "$atype" = "squad" ]; then pool="$qa_squads"; else pool="$qa_agents"; fi
          aid=$(jq -r --arg a "$assignee" 'map(select(.name == $a or .id == $a)) | (.[0].id // empty)' <<<"$pool")
          if [ -z "$aid" ]; then
            echo "multica-reconcile: quick action $name assignee $atype '$assignee' not found; skipping." >&2
            continue
          fi

          body=$(jq -n --arg n "$name" --arg d "$desc" --arg p "$prompt" \
            --arg aid "$aid" --arg at "$atype" --arg v "$vis" \
            '{name:$n, description:$d, prompt:$p, assignee_id:$aid, assignee_type:$at, visibility:$v}')

          id=$(jq -r --arg n "$name" 'map(select(.name == $n)) | (.[0].id // empty)' <<<"$qa_existing")
          if [ -n "$id" ]; then
            echo "multica-reconcile: updating quick action $name ($id)"
            curl -fsS -X PATCH \
              -H "Authorization: Bearer $MULTICA_TOKEN" \
              -H "X-Workspace-Id: $MULTICA_WORKSPACE_ID" \
              -H 'Content-Type: application/json' \
              -d "$body" "$MULTICA_SERVER_URL/api/quick-actions/$id" >/dev/null
          else
            echo "multica-reconcile: creating quick action $name"
            curl -fsS -X POST \
              -H "Authorization: Bearer $MULTICA_TOKEN" \
              -H "X-Workspace-Id: $MULTICA_WORKSPACE_ID" \
              -H 'Content-Type: application/json' \
              -d "$body" "$MULTICA_SERVER_URL/api/quick-actions" >/dev/null
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
          project=$(jq -r '.project // empty' <<<"$ap")
          tmpl=$(jq -r '.issueTitleTemplate // empty' <<<"$ap")
          status=$(jq -r '.status // empty' <<<"$ap")

          aid=$(jq -r --arg a "$agent" 'map(select(.name == $a or .id == $a)) | (.[0].id // empty)' <<<"$ap_agents")
          if [ -z "$aid" ]; then
            echo "multica-reconcile: autopilot $title agent '$agent' not found; skipping." >&2
            continue
          fi

          args=(--description "$description" --agent "$aid" --mode "$mode")
          [ -n "$project" ] && args+=(--project "$project")
          [ -n "$tmpl" ] && args+=(--issue-title-template "$tmpl")
          while read -r sub; do
            [ -n "$sub" ] && args+=(--subscriber "$sub")
          done < <(jq -r '.subscribers[]?' <<<"$ap")

          id=$(jq -r --arg t "$title" 'map(select(.title == $t)) | (.[0].id // empty)' <<<"$ap_existing")
          if [ -n "$id" ]; then
            echo "multica-reconcile: updating autopilot $title ($id)"
            uargs=("''${args[@]}")
            [ -n "$status" ] && uargs+=(--status "$status")
            multica autopilot update "$id" --title "$title" "''${uargs[@]}" >/dev/null
          else
            echo "multica-reconcile: creating autopilot $title"
            id=$(multica autopilot create --title "$title" "''${args[@]}" --output json | jq -r '.id')
            [ -n "$status" ] && multica autopilot update "$id" --status "$status" >/dev/null
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

          want_labels=$(jq -r '.triggers[].label' <<<"$ap")
          while IFS=$'\t' read -r tid tlabel; do
            [ -n "$tid" ] || continue
            if printf '%s\n' "$want_labels" | grep -Fxq -- "$tlabel"; then continue; fi
            echo "multica-reconcile: pruning autopilot $title trigger $tlabel ($tid)"
            multica autopilot trigger-delete "$id" "$tid" >/dev/null \
              || echo "multica-reconcile: prune of trigger $tlabel failed" >&2
          done < <(jq -r '.[] | [.id, .label] | @tsv' <<<"$existing_triggers")
        done
      fi

      prune_kind() {
        local idfield="$1" live="$2" key="$3" delfn="$4"
        local want
        want=$(jq -r --arg k "$key" --arg f "$idfield" '.[$k][]? | .[$f]' "$manifest")
        while IFS=$'\t' read -r rid ident; do
          [ -n "$rid" ] || continue
          if printf '%s\n' "$want" | grep -Fxq -- "$ident"; then continue; fi
          echo "multica-reconcile: pruning $key '$ident' ($rid)"
          "$delfn" "$rid" \
            || echo "multica-reconcile: prune of $key '$ident' failed; will retry on next change" >&2
        done < <(jq -r --arg f "$idfield" '.[] | [.id, .[$f]] | @tsv' <<<"$live")
      }

      del_ap()    { multica autopilot delete "$1" >/dev/null; }
      del_qa()    { curl -fsS -X DELETE \
                      -H "Authorization: Bearer $MULTICA_TOKEN" \
                      -H "X-Workspace-Id: $MULTICA_WORKSPACE_ID" \
                      "$MULTICA_SERVER_URL/api/quick-actions/$1" >/dev/null; }
      del_squad() { multica squad delete "$1" >/dev/null; }
      del_agent() { multica agent archive "$1" >/dev/null; }
      del_skill() { multica skill delete "$1" --yes >/dev/null; }

      live_aps=$(multica autopilot list --output json | jq '.autopilots // .')
      live_qas=$(curl -fsS \
        -H "Authorization: Bearer $MULTICA_TOKEN" \
        -H "X-Workspace-Id: $MULTICA_WORKSPACE_ID" \
        "$MULTICA_SERVER_URL/api/quick-actions" | jq '.quick_actions // []')
      live_squads=$(multica squad list --output json)
      live_agents=$(multica agent list --output json)
      live_skills=$(multica skill list --output json)

      prune_kind title "$live_aps"    autopilots   del_ap
      prune_kind name  "$live_qas"    quickActions del_qa
      prune_kind name  "$live_squads" squads       del_squad
      prune_kind name  "$live_agents" agents       del_agent
      prune_kind name  "$live_skills" skills       del_skill

      echo "multica-reconcile: reconcile complete"
    '';
  };
in
{
  options.services.multica = {
    enable = lib.mkEnableOption "the self-hosted Multica server";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/multica-cli.nix { };
      defaultText = lib.literalExpression "multica-cli";
      description = "The Multica CLI package to put on PATH (used to administer the server).";
    };

    desktopPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/multica-desktop.nix {
        serverUrl = backendUrl;
      };
      defaultText = lib.literalExpression "multica-desktop";
      description = "The Multica desktop client (Electron AppImage) to put on PATH. Linux only.";
    };

    installDesktop = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to put the Multica desktop client on PATH. Linux only.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "localhost";
      description = ''
        Public host used to reach this server (drives the backend URL seeded into
        the desktop client). Set to the machine's hostname/IP if you access Multica
        from another machine.
      '';
    };

    backendPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port the backend API listens on.";
    };

    backendImage = lib.mkOption {
      type = lib.types.str;
      default = defaultBackendImage;
      description = "OCI image reference for the Multica backend (digest-pinned by default).";
    };

    backendImageFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Optional pre-fetched backend image tarball (e.g. from `dockerTools.pullImage`)
        to load instead of pulling from the registry. Used by the offline test.
      '';
    };

    database = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Provision a local PostgreSQL database with pgvector for Multica.";
      };
      name = lib.mkOption {
        type = lib.types.str;
        default = "multica";
        description = "Database name.";
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "multica";
        description = "Database user (owns the database; loopback trust auth).";
      };
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/multica/env";
      description = ''
        Path to an env file (KEY=VALUE lines) read at runtime, kept OUT of the Nix
        store. JWT_SECRET is auto-generated inside the backend container.
        Use this file for any other secrets/integration vars (e.g. MULTICA_TOKEN).
      '';
      example = "/var/lib/multica/env";
    };

    extraBackendEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for the backend container (integrations, S3, OAuth, ...).";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the backend port in the firewall for access from other machines.";
    };

    devMode = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run the backend in development mode: enables passwordless login with a
        fixed verification code and lets the skills reconciler mint its own token
        automatically (see `skills`). Local/dev only — never expose such a backend.
        Set false for a production backend, where you must supply `MULTICA_TOKEN`.
      '';
    };

    devVerificationCode = lib.mkOption {
      type = lib.types.str;
      default = "888888";
      description = "Fixed login code accepted for any email while `devMode` is on.";
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

    workspaceId = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Workspace to reconcile `skills` into. If null, the reconciler uses the
        token's sole workspace (creating one in `devMode` if none exist) and fails
        if the token can see more than one.
      '';
    };

    workspaceName = lib.mkOption {
      type = lib.types.str;
      default = "Default";
      description = "Name for the workspace auto-created in `devMode` when none exists.";
    };

    workspaceSlug = lib.mkOption {
      type = lib.types.str;
      default = "default";
      description = "Slug for the workspace auto-created in `devMode` (lowercase, digits, hyphens).";
    };

    skills = lib.mkOption {
      default = { };
      description = ''
        Declarative Multica skills. The attribute name is the skill's name (its
        identity). The workspace is fully owned by this config: declared skills are
        created or updated to match; skills not declared here are **deleted** from
        the workspace on the next rebuild.

        Requires a personal access token (`mul_…`) in `environmentFile` as
        `MULTICA_TOKEN`; without it, reconciliation is skipped.
      '';
      example = lib.literalExpression ''
        {
          pr-review = {
            description = "How we review pull requests";
            text = '''
              # PR review
              Check tests, scope, and a rollback plan before approving.
            ''';
          };
        }
      '';
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          description = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Skill description shown in Multica.";
          };
          text = lib.mkOption {
            type = lib.types.nullOr lib.types.lines;
            default = null;
            description = "Inline SKILL.md markdown body. Mutually exclusive with `source`.";
          };
          source = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "File providing the SKILL.md body. Mutually exclusive with `text`.";
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
              options = {
                text = lib.mkOption {
                  type = lib.types.nullOr lib.types.lines;
                  default = null;
                  description = "Inline file body. Mutually exclusive with `source`.";
                };
                source = lib.mkOption {
                  type = lib.types.nullOr lib.types.path;
                  default = null;
                  description = "File providing the body. Mutually exclusive with `text`.";
                };
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
      example = lib.literalExpression ''
        {
          reviewer = {
            description = "Reviews pull requests";
            runtime = "Claude (myhost)";
            model = "claude-sonnet-4-6";
            instructions = "Be thorough and terse.";
            skills = [ "pr-review" ];
          };
        }
      '';
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          description = lib.mkOption {
            type = lib.types.str;
            default = "";
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
              Runtime to run the agent on, by display name or id (see `multica runtime
              list`). Null uses the sole runtime, and fails if there is more than one.
            '';
          };
          model = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Model identifier (e.g. claude-sonnet-4-6). Null = runtime default.";
          };
          thinkingLevel = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Reasoning/effort level (runtime-specific, e.g. low|medium|high).";
          };
          visibility = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum [ "private" "workspace" ]);
            default = null;
            description = "Invocation visibility: private (owner) or workspace (all members).";
          };
          maxConcurrentTasks = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.positive;
            default = null;
            description = "Maximum concurrent runs (1-50). Null = server default.";
          };
          skills = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = ''
              Skill names to assign to this agent (from `skills` or already in the
              workspace). The set is replaced to match on each reconcile.
            '';
          };
          customArgs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Custom CLI arguments for the agent's runtime.";
          };
          runtimeConfig = lib.mkOption {
            type = jsonFormat.type;
            default = { };
            description = "Runtime config, serialised to JSON (the CLI's --runtime-config).";
          };
          customEnvFile = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Path to a JSON file of custom env vars (secret material) read at reconcile
              time. Kept OUT of the Nix store — use an absolute path, not a `./file`.
            '';
          };
          mcpConfigFile = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Path to a JSON MCP server config (often carries tokens) read at reconcile
              time. Kept OUT of the Nix store — use an absolute path, not a `./file`.
            '';
          };
        };
      }));
    };

    squads = lib.mkOption {
      default = { };
      description = ''
        Declarative Multica squads, reconciled after agents. The attribute name is the
        squad's name. The workspace is fully owned by this config: declared squads are
        created or updated; squads not declared here are **archived** on the next
        rebuild. Members are replaced to match the declared set. The leader is
        automatically a member — do not list it under `members`.

        Note: archived squads cannot be restored via the CLI; re-declaring an archived
        squad name creates a new squad with the same name.
      '';
      example = lib.literalExpression ''
        {
          delivery = {
            description = "Ships the roadmap";
            leader = "reviewer";
            members.builder.role = "member";
          };
        }
      '';
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          description = lib.mkOption {
            type = lib.types.str;
            default = "";
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
                default = "member";
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
        The workspace is fully owned by this config: declared actions are created or
        updated; quick actions not declared here are **deleted** on the next rebuild.

        Quick actions have no CLI, so the reconciler drives the REST API directly.
      '';
      example = lib.literalExpression ''
        {
          triage = {
            prompt = "Triage this issue: label it and suggest next steps.";
            assignee = "reviewer";   # an agent (or squad) name
          };
        }
      '';
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          description = lib.mkOption {
            type = lib.types.str;
            default = "";
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
          assigneeType = lib.mkOption {
            type = lib.types.enum [ "agent" "squad" ];
            default = "agent";
            description = "Whether `assignee` names an agent or a squad.";
          };
          visibility = lib.mkOption {
            type = lib.types.enum [ "private" "public" ];
            default = "private";
            description = ''
              Who can trigger it: private (you) or public (all members). A public action
              requires its assignee agent to be public.
            '';
          };
        };
      }));
    };

    autopilots = lib.mkOption {
      default = { };
      description = ''
        Declarative Multica autopilots — scheduled/triggered agent automations.
        Reconciled after agents/squads (so they can reference agents you declare).
        The attribute name is the autopilot's title (its identity). The workspace is
        fully owned by this config: declared autopilots are created or updated;
        autopilots not declared here are **deleted** on the next rebuild.

        Each autopilot dispatches to an assignee `agent`, which needs a runtime
        (registered by a running `multica daemon`). Without the agent present,
        the autopilot is skipped, just like quick actions.

        Only schedule (cron) triggers are declarative here; webhook triggers are
        managed manually with `multica autopilot trigger-add`. Declared triggers are
        upserted by label; triggers not declared are **deleted** (full ownership).
      '';
      example = lib.literalExpression ''
        {
          "Nightly triage" = {
            description = "Summarise and label new issues from the last day.";
            agent = "reviewer";           # an agent name or id
            mode = "create_issue";
            issueTitleTemplate = "Triage {{date}}";
            triggers.nightly = { cron = "0 9 * * *"; timezone = "Australia/Sydney"; };
          };
        }
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
            default = "run_only";
            description = ''
              Execution mode: `run_only` just runs the agent; `create_issue` files an
              issue for each run (see `issueTitleTemplate`).
            '';
          };
          project = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Project id to associate runs/issues with. Null = none.";
          };
          issueTitleTemplate = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Title template for issues created in `create_issue` mode. Only `{{date}}`
              (UTC, YYYY-MM-DD) is interpolated. Requires `mode = "create_issue"`.
            '';
          };
          subscribers = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = ''
              Members to notify for issues this autopilot creates, by name or user id.
              The set is replaced to match on each reconcile.
            '';
          };
          status = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum [ "active" "paused" ]);
            default = null;
            description = "Desired status. Null leaves the server default / current value.";
          };
          triggers = lib.mkOption {
            default = { };
            description = ''
              Schedule (cron) triggers, keyed by label (the label is the identity).
              Upserted on each reconcile; triggers not listed here are deleted.
            '';
            type = lib.types.attrsOf (lib.types.submodule {
              options = {
                cron = lib.mkOption {
                  type = lib.types.str;
                  description = "Cron expression for the schedule (required).";
                };
                timezone = lib.mkOption {
                  type = lib.types.str;
                  default = "UTC";
                  description = "IANA timezone the cron expression is evaluated in.";
                };
                enabled = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Whether the trigger is enabled.";
                };
              };
            });
          };
        };
      }));
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ]
      ++ lib.optional (cfg.installDesktop && pkgs.stdenv.hostPlatform.isLinux) cfg.desktopPackage;

    services.postgresql = lib.mkIf cfg.database.createLocally {
      enable = true;
      package = pkgs.postgresql_17;
      extensions = ps: [ ps.pgvector ];
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [{
        name = cfg.database.user;
        ensureDBOwnership = true;
      }];
      authentication = lib.mkAfter ''
        host ${cfg.database.name} ${cfg.database.user} 127.0.0.1/32 trust
        host ${cfg.database.name} ${cfg.database.user} ::1/128      trust
      '';
    };

    systemd.services.multica-db-init = lib.mkIf cfg.database.createLocally {
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
        ${config.services.postgresql.package}/bin/psql -d ${cfg.database.name} \
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

    virtualisation.oci-containers.containers.multica-backend = {
      image = cfg.backendImage;
      imageFile = cfg.backendImageFile;
      entrypoint = "/entrypoint-wrapper.sh";
      environment = {
        DATABASE_URL = databaseUrl;
        PORT = toString cfg.backendPort;
      } // lib.optionalAttrs cfg.devMode {
        APP_ENV = "development";
        MULTICA_DEV_VERIFICATION_CODE = cfg.devVerificationCode;
      } // cfg.extraBackendEnvironment;
      environmentFiles = [ cfg.environmentFile ];
      volumes = [
        "${multicaBackendEntrypoint}:/entrypoint-wrapper.sh:ro"
        "/var/lib/multica/secrets:/app/secrets"
        "/var/lib/multica/uploads:/app/data/uploads"
      ];
      extraOptions = [ "--network=host" ];
    };

    systemd.services.docker-multica-backend = {
      after = [ "postgresql.service" "multica-db-init.service" ];
      requires = [ "postgresql.service" "multica-db-init.service" ];
    };

    networking.firewall.allowedTCPPorts =
      lib.mkIf cfg.openFirewall [ cfg.backendPort ];

    assertions =
      lib.mapAttrsToList
        (name: skill: {
          assertion = (skill.text == null) != (skill.source == null);
          message = "services.multica.skills.${name}: set exactly one of `text` or `source`.";
        })
        cfg.skills
      ++ lib.concatLists (lib.mapAttrsToList
        (name: skill: lib.mapAttrsToList
          (path: file: {
            assertion = (file.text == null) != (file.source == null);
            message = ''services.multica.skills.${name}.files."${path}": set exactly one of `text` or `source`.'';
          })
          skill.files)
        cfg.skills)
      ++ lib.mapAttrsToList
        (title: ap: {
          assertion = ap.issueTitleTemplate == null || ap.mode == "create_issue";
          message = ''services.multica.autopilots."${title}": `issueTitleTemplate` requires `mode = "create_issue"`.'';
        })
        cfg.autopilots;

    systemd.services.multica-reconcile = {
      description = "Reconcile declarative Multica resources (prunes undeclared ones)";
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
        ] ++ lib.optional (cfg.workspaceId != null) "MULTICA_WORKSPACE_ID=${cfg.workspaceId}";
      };
      script = "${lib.getExe reconcile} ${reconcileManifest}";
    };
  };
}
