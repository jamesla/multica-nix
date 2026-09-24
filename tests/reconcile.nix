{ pkgs, self }:
let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  arch = { x86_64-linux = "amd64"; aarch64-linux = "arm64"; }.${system};

  imageSha = {
    backend = {
      aarch64-linux = "sha256-TvvNtb8ZVQ8dXcyzocippiBHJmyzrSUVu2vd7ViaVQE=";
      x86_64-linux = "sha256-I4VpZcF5Zzzpb4zs0y7eimVQ62Zy+Jaqx8sxiyli81s=";
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
  name = "multica-reconcile";

  nodes.machine = { ... }: {
    imports = [ self.nixosModules.multica ];

    virtualisation = {
      memorySize = 8192;
      diskSize = 16384;
      cores = 4;
    };

    environment.etc."multica/secret.env".text = ''
      JWT_SECRET=testsecret0123456789testsecret0123456789
    '';

    services.multica = {
      enable = true;
      environmentFile = "/etc/multica/secret.env";
      backendImageFile = backendImage;
      installDesktop = false;
      devLoginEmail = "admin@multica.local";
      skills.pr-review = {
        description = "How we review PRs";
        text = ''
          # PR review
          Check tests, scope, and a rollback plan.
        '';
      };
    };

    specialisation.pruned.configuration = {
      services.multica.skills = lib.mkForce { };
    };
  };

  testScript = { nodes, ... }:
    let
      prunedSwitch =
        "${nodes.machine.system.build.toplevel}/specialisation/pruned/bin/switch-to-configuration test";
    in
    ''
      machine.start()

      machine.wait_for_unit("multi-user.target", timeout=120)
      machine.wait_for_unit("postgresql.service", timeout=120)
      machine.wait_for_unit("multica-db-init.service")
      machine.wait_for_unit("docker-multica-backend.service")
      machine.wait_until_succeeds("curl -fsS http://127.0.0.1:8080/health", timeout=180)

      machine.wait_for_unit("multica-reconcile.service")
      machine.succeed("journalctl -u multica-reconcile.service | grep -q 'creating pr-review'")
      machine.succeed(
          "sudo -u postgres psql -d multica -tAc "
          "\"select 1 from skill where name = 'pr-review'\" | grep -q 1"
      )
      machine.succeed("journalctl -u multica-reconcile.service | grep -q 'reconcile complete'")

      # Request a fresh dev login code before verifying (the reconciler consumed
      # the previous one); the code is pinned to 888888 via MULTICA_DEV_VERIFICATION_CODE.
      # send-code is rate-limited per email and the reconciler just used it, so
      # retry until the window clears.
      machine.succeed(
          "for _ in $(seq 1 12); do "
          "code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "
          "-H 'Content-Type: application/json' "
          "-d '{\"email\":\"admin@multica.local\"}' "
          "http://127.0.0.1:8080/auth/send-code); "
          "[ \"$code\" = 200 ] && exit 0; sleep 10; done; exit 1"
      )
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

      cursor = machine.succeed(
          "journalctl -u multica-reconcile.service -n 0 --show-cursor | grep -oP '(?<=cursor: ).*'"
      ).strip()

      machine.succeed("${prunedSwitch}")

      machine.wait_until_succeeds(
          f"journalctl -u multica-reconcile.service --after-cursor='{cursor}' "
          "| grep -q 'reconcile complete'",
          timeout=240
      )

      machine.succeed(
          f"journalctl -u multica-reconcile.service --after-cursor='{cursor}' "
          "| grep -q \"pruning skills 'pr-review'\""
      )
      machine.succeed(
          f"journalctl -u multica-reconcile.service --after-cursor='{cursor}' "
          "| grep -q \"pruning skills 'ui-created'\""
      )

      machine.succeed(
          "sudo -u postgres psql -d multica -tAc "
          "\"select count(*) from skill\" | grep -q '^0$'"
      )
    '';
}
