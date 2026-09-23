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
  name = "multica-integration";

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

      package = pkgs.callPackage ../pkgs/multica-cli.nix { };
      desktopPackage = pkgs.callPackage ../pkgs/multica-desktop.nix { serverUrl = "http://localhost:8080"; };
      installDesktop = false;

      host = "localhost";
      backendPort = 8080;
      openFirewall = false;

      environmentFile = "/etc/multica/secret.env";
      backendImageFile = backendImage;
      backendImage = "ghcr.io/multica-ai/multica-backend:v0.4.41";
      extraBackendEnvironment = { };

      database.createLocally = true;
      database.name = "multica";
      database.user = "multica";

      devMode = true;
      devVerificationCode = "888888";
      devLoginEmail = "admin@multica.local";
      workspaceName = "Test";
      workspaceSlug = "test";
      workspaceId = null;

      sandboxExtraPackages = [ ];

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
        runtime = null;
        model = null;
        thinkingLevel = null;
        visibility = null;
        maxConcurrentTasks = null;
        skills = [ "pr-review" ];
        customArgs = [ ];
        runtimeConfig = { };
        customEnvFile = null;
        mcpConfigFile = null;
      };

      squads.delivery = {
        description = "Ships the roadmap";
        leader = "reviewer";
      };

      quickActions.triage = {
        description = "Triage issues";
        prompt = "Triage this issue.";
        assignee = "reviewer";
        assigneeType = "agent";
        visibility = "private";
      };

      autopilots.nightly = {
        description = "Summarise open issues each night.";
        agent = "reviewer";
        mode = "run_only";
        project = null;
        issueTitleTemplate = null;
        subscribers = [ ];
        status = null;
        triggers.nightly = {
          cron = "0 9 * * *";
          timezone = "UTC";
          enabled = true;
        };
      };

      sandboxes = { };
    };
  };

  testScript = ''
    machine.start()

    machine.wait_for_unit("postgresql.service")
    machine.wait_for_unit("multica-db-init.service")
    machine.succeed(
        "sudo -u postgres psql -d multica -tAc "
        "\"select 1 from pg_extension where extname = 'vector'\" | grep -q 1"
    )

    machine.wait_for_unit("docker-multica-backend.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:8080/health", timeout=180)

    machine.succeed("multica --version | grep -q 0.4.41")

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

    machine.wait_for_unit("multica-reconcile.service")
    machine.succeed("journalctl -u multica-reconcile.service | grep -q 'creating pr-review'")

    machine.succeed(
        "sudo -u postgres psql -d multica -tAc "
        "\"select 1 from skill where name = 'pr-review'\" | grep -q 1"
    )

    machine.succeed(
        "journalctl -u multica-reconcile.service | grep -q 'no runtimes registered'"
    )
    machine.succeed(
        "sudo -u postgres psql -d multica -tAc "
        "\"select count(*) from agent\" | grep -q '^0$'"
    )

    machine.succeed(
        "journalctl -u multica-reconcile.service "
        "| grep -q \"quick action triage assignee agent 'reviewer' not found\""
    )
    machine.succeed(
        "sudo -u postgres psql -d multica -tAc "
        "\"select count(*) from quick_action\" | grep -q '^0$'"
    )

    machine.succeed(
        "journalctl -u multica-reconcile.service "
        "| grep -q \"autopilot nightly agent 'reviewer' not found\""
    )
  '';
}
