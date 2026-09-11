# Prune test: verify that removing a declared resource from the config causes the
# reconciler to delete it from the workspace on the next rebuild.
#
# Strategy: declare one skill (pr-review) in the base config. A `specialisation`
# removes it. After switching to the specialisation the reconciler re-runs
# (restartTriggers fires because the manifest store path changed) and must delete
# the skill row. A second assertion creates a skill out-of-band (simulating a
# UI-created resource) and verifies it too is deleted, proving full ownership.
#
# The switch is driven by `switch-to-configuration test` against the specialisation
# toplevel — the canonical NixOS pattern (see nixos/tests/home-assistant.nix).
# All assertions read postgres directly to avoid a second /auth/send-code round-trip
# (the backend rate-limits that endpoint per email).
{ pkgs, self }:
let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  arch = { x86_64-linux = "amd64"; aarch64-linux = "arm64"; }.${system};

  fakeHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  imageSha = {
    backend = {
      aarch64-linux = "sha256-TvvNtb8ZVQ8dXcyzocippiBHJmyzrSUVu2vd7ViaVQE=";
      x86_64-linux = fakeHash;
    };
  };

  backendImage = pkgs.dockerTools.pullImage {
    imageName = "ghcr.io/multica-ai/multica-backend";
    imageDigest = "sha256:a1c1053fc014b967ae33404eae5a6f725a4befa416e5c9fc657a4b6103f34723";
    finalImageName = "ghcr.io/multica-ai/multica-backend";
    finalImageTag = "v0.4.41";
    sha256 = imageSha.backend.${system};
    os = "linux";
    inherit arch;
  };
in
pkgs.testers.runNixOSTest {
  name = "multica-prune";

  nodes.machine = { ... }: {
    imports = [ self.nixosModules.multica ];

    virtualisation = {
      memorySize = 4096;
      diskSize = 8192;
      cores = 2;
    };

    environment.etc."multica/secret.env".text = ''
      JWT_SECRET=testsecret0123456789testsecret0123456789
    '';

    services.multica = {
      enable = true;
      environmentFile = "/etc/multica/secret.env";
      backendImageFile = backendImage;
      backendImage = "ghcr.io/multica-ai/multica-backend:v0.4.41";
      # Config 1: declare one skill. The reconciler creates it.
      skills.pr-review = {
        description = "How we review PRs";
        text = ''
          # PR review
          Check tests, scope, and a rollback plan.
        '';
      };
    };

    # Config 2: remove the declared skill. The reconciler must delete it.
    # lib.mkForce is required to override the parent's skills.pr-review.
    specialisation.pruned.configuration = {
      services.multica.skills = lib.mkForce { };
    };
  };

  testScript = { nodes, ... }:
    let
      prunedSwitch =
        "${nodes.machine.system.build.toplevel}/specialisation/pruned/bin/switch-to-configuration test";
    in ''
      machine.start()

      # Bring the stack up.
      machine.wait_for_unit("postgresql.service")
      machine.wait_for_unit("multica-db-init.service")
      machine.wait_for_unit("docker-multica-backend.service")
      machine.wait_until_succeeds("curl -fsS http://127.0.0.1:8080/health", timeout=180)

      # CONFIG 1: reconciler creates pr-review.
      machine.wait_for_unit("multica-reconcile.service")
      machine.succeed("journalctl -u multica-reconcile.service | grep -q 'creating pr-review'")
      machine.succeed(
          "sudo -u postgres psql -d multica -tAc "
          "\"select 1 from skill where name = 'pr-review'\" | grep -q 1"
      )
      # Confirm the terminal log line so the cursor approach below works reliably.
      machine.succeed("journalctl -u multica-reconcile.service | grep -q 'reconcile complete'")

      # Create a skill out-of-band (simulating a UI/CLI-created resource not in config).
      # Config 2 declares no skills, so this must also be pruned (full ownership).
      token_json = machine.succeed(
          "curl -fsS -X POST -H 'Content-Type: application/json' "
          "-d '{\"email\":\"admin@multica.local\",\"code\":\"888888\"}' "
          "http://127.0.0.1:8080/auth/verify-code"
      )
      import json
      token = json.loads(token_json)["token"]
      ws_json = machine.succeed(
          f"MULTICA_TOKEN={token} MULTICA_SERVER_URL=http://127.0.0.1:8080 "
          "multica workspace list --output json"
      )
      ws_id = json.loads(ws_json)[0]["id"]
      machine.succeed(
          f"MULTICA_TOKEN={token} MULTICA_SERVER_URL=http://127.0.0.1:8080 "
          f"MULTICA_WORKSPACE_ID={ws_id} "
          "multica skill create --name ui-created --description 'Created in UI' "
          "--content-file /dev/stdin --output json <<<'# ui skill'"
      )
      machine.succeed(
          "sudo -u postgres psql -d multica -tAc "
          "\"select 1 from skill where name = 'ui-created'\" | grep -q 1"
      )

      # Capture a journal cursor so we can scope assertions to the NEXT reconcile run.
      cursor = machine.succeed(
          "journalctl -u multica-reconcile.service -n 0 --show-cursor | grep -oP '(?<=cursor: ).*'"
      ).strip()

      # CONFIG 2: switch to the specialisation that removes the skill.
      # This changes the manifest store path → restartTriggers fires → reconciler re-runs.
      machine.succeed("${prunedSwitch}")

      # Wait for the new reconcile run to complete (RemainAfterExit means wait_for_unit
      # would pass immediately on the already-active instance; use the terminal log line).
      machine.wait_until_succeeds(
          f"journalctl -u multica-reconcile.service --after-cursor='{cursor}' "
          "| grep -q 'reconcile complete'",
          timeout=120
      )

      # The prune log must have fired for both skills.
      machine.succeed(
          f"journalctl -u multica-reconcile.service --after-cursor='{cursor}' "
          "| grep -q \"pruning skills 'pr-review'\""
      )
      machine.succeed(
          f"journalctl -u multica-reconcile.service --after-cursor='{cursor}' "
          "| grep -q \"pruning skills 'ui-created'\""
      )

      # Both skill rows must be gone.
      machine.succeed(
          "sudo -u postgres psql -d multica -tAc "
          "\"select count(*) from skill\" | grep -q '^0$'"
      )
    '';
}
