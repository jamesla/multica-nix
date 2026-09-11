# Integration test: boot a NixOS VM with the Multica module, using the REAL pinned
# backend image (fetched hermetically into the store via dockerTools.pullImage so the
# sandboxed VM needs no network), and assert the stack actually comes up:
#   * postgres + pgvector ready
#   * backend /health returns 200
#   * the multica CLI is on PATH
#   * passwordless dev login works
#
# The pulled-image sha256 is architecture-specific, so it is keyed by system. Fill a
# new arch with:  nix build .#checks.<system>.integration  (it prints the expected hash).
{ pkgs, self }:
let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  arch = { x86_64-linux = "amd64"; aarch64-linux = "arm64"; }.${system};

  # Per-arch sha256 of the repacked image tarball. x86_64 is a placeholder: the first
  # run on that arch fails with the expected hash — paste it in.
  fakeHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  imageSha = {
    backend = {
      aarch64-linux = "sha256-TvvNtb8ZVQ8dXcyzocippiBHJmyzrSUVu2vd7ViaVQE=";
      x86_64-linux = fakeHash; # TODO: fill on first x86_64 run
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
  name = "multica-integration";

  nodes.machine = { ... }: {
    imports = [ self.nixosModules.multica ];

    # The web image is large and migrations need headroom.
    virtualisation = {
      memorySize = 4096;
      diskSize = 8192;
      cores = 2;
    };

    # Throwaway secret for the test only.
    environment.etc."multica/secret.env".text = ''
      JWT_SECRET=testsecret0123456789testsecret0123456789
    '';

    services.multica = {
      enable = true;
      environmentFile = "/etc/multica/secret.env";
      # Load the pinned image from the store instead of the registry.
      backendImageFile = backendImage;
      backendImage = "ghcr.io/multica-ai/multica-backend:v0.4.41";
      # Exercise the reconciler. No MULTICA_TOKEN in the throwaway secret.env, so it
      # dev-logs-in and pushes the skill. The VM has no daemon (hence no runtime), so
      # the agent/squad below can't be created — the reconciler must skip them cleanly.
      skills.pr-review = {
        description = "How we review PRs";
        text = ''
          # PR review
          Check tests, scope, and a rollback plan.
        '';
      };
      agents.reviewer = {
        description = "Reviews PRs";
        instructions = "Be terse.";
        skills = [ "pr-review" ];
      };
      squads.delivery = {
        description = "Ships the roadmap";
        leader = "reviewer";
      };
      quickActions.triage = {
        prompt = "Triage this issue.";
        assignee = "reviewer";
      };
      autopilots.nightly = {
        description = "Summarise open issues each night.";
        agent = "reviewer";
        triggers.nightly = { cron = "0 9 * * *"; };
      };
    };
  };

  testScript = ''
    machine.start()

    # Database up and pgvector installed.
    machine.wait_for_unit("postgresql.service")
    machine.wait_for_unit("multica-db-init.service")
    machine.succeed(
        "sudo -u postgres psql -d multica -tAc "
        "\"select 1 from pg_extension where extname = 'vector'\" | grep -q 1"
    )

    # Backend comes up and answers /health.
    machine.wait_for_unit("docker-multica-backend.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:8080/health", timeout=180)

    # CLI is installed.
    machine.succeed("multica --version | grep -q 0.4.41")

    # Passwordless login with the fixed dev code works and creates the user.
    machine.succeed(
        "curl -fsS -X POST -H 'Content-Type: application/json' "
        "-d '{\"email\":\"test@example.com\"}' http://127.0.0.1:8080/auth/send-code"
    )
    machine.succeed(
        "curl -fsS -X POST -H 'Content-Type: application/json' "
        "-d '{\"email\":\"test@example.com\",\"code\":\"888888\"}' "
        "http://127.0.0.1:8080/auth/verify-code"
    )
    machine.succeed(
        "sudo -u postgres psql -d multica -tAc "
        "\"select 1 from \\\"user\\\" where email = 'test@example.com'\" | grep -q 1"
    )

    # The reconciler dev-logs-in, creates a workspace, and pushes the declared skill.
    # The oneshot runs `set -euo pipefail`, so wait_for_unit passing already proves
    # `skill create` returned success. Confirm it landed by reading the row straight
    # from postgres (no second login, which the backend would rate-limit).
    machine.wait_for_unit("multica-reconcile.service")
    machine.succeed("journalctl -u multica-reconcile.service | grep -q 'creating pr-review'")

    machine.succeed(
        "sudo -u postgres psql -d multica -tAc "
        "\"select 1 from skill where name = 'pr-review'\" | grep -q 1"
    )

    # Agents/squads need a runtime, which only a running daemon registers. This VM has
    # none, so the reconciler must skip them cleanly (and not create the agent row).
    machine.succeed(
        "journalctl -u multica-reconcile.service | grep -q 'no runtimes registered'"
    )
    machine.succeed(
        "sudo -u postgres psql -d multica -tAc "
        "\"select count(*) from agent\" | grep -q '^0$'"
    )

    # Quick action's assignee (the reviewer agent) couldn't be created without a
    # runtime, so the reconciler skips it cleanly and creates no quick_action row.
    machine.succeed(
        "journalctl -u multica-reconcile.service "
        "| grep -q \"quick action triage assignee agent 'reviewer' not found\""
    )
    machine.succeed(
        "sudo -u postgres psql -d multica -tAc "
        "\"select count(*) from quick_action\" | grep -q '^0$'"
    )

    # Autopilots dispatch to an agent too, so with no runtime the reviewer agent
    # doesn't exist and the reconciler skips the autopilot cleanly. The skip log
    # proves creation was never attempted, so no autopilot could have been made.
    machine.succeed(
        "journalctl -u multica-reconcile.service "
        "| grep -q \"autopilot nightly agent 'reviewer' not found\""
    )
  '';
}
