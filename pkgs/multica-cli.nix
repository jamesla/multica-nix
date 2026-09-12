{ lib, stdenvNoCC, fetchurl }:

let
  version = "0.4.41";

  platforms = {
    x86_64-linux = {
      asset = "linux-amd64";
      hash = "sha256-tmbvfsImeA2wS0W47Du9SARQm23I7wZ5HKft9kP42Hc=";
    };
    aarch64-linux = {
      asset = "linux-arm64";
      hash = "sha256-T95yG/S4VwxPPZ2D87rak4YngRWEnwhHnzyyHAhoHNE=";
    };
    x86_64-darwin = {
      asset = "darwin-amd64";
      hash = "sha256-JUfLJ8n9VvV/T4rwXI7TtDF3L+BjQ99w5hYML8pySq4=";
    };
    aarch64-darwin = {
      asset = "darwin-arm64";
      hash = "sha256-WyKDKxIAJRWZmyU3rekCJW/L2YdmCJ6zCFUr4ze/7rw=";
    };
  };

  plat = platforms.${stdenvNoCC.hostPlatform.system}
    or (throw "multica-cli: unsupported system ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "multica-cli";
  inherit version;

  src = fetchurl {
    url = "https://github.com/multica-ai/multica/releases/download/v${version}/multica-cli-${version}-${plat.asset}.tar.gz";
    inherit (plat) hash;
  };

  sourceRoot = ".";

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 multica $out/bin/multica
    install -Dm644 LICENSE $out/share/doc/multica-cli/LICENSE
    install -Dm644 NOTICE  $out/share/doc/multica-cli/NOTICE
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/multica --version | grep -q "${version}"
  '';

  meta = {
    description = "CLI client for Multica, a workspace for AI coding agents";
    homepage = "https://github.com/multica-ai/multica";
    license = lib.licenses.asl20;
    mainProgram = "multica";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames platforms;
  };
}
