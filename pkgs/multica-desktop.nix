# Multica desktop client — prebuilt Electron AppImage from upstream GitHub releases.
# AppImages expect an FHS runtime that NixOS does not provide, so we wrap it with
# appimageTools rather than running the raw binary.
#
# The packaged app defaults to Multica cloud; its only production hook for the server
# is `$HOME/.multica/desktop.json` (read at startup). To point it at the instance this
# flake installs, the launch wrapper seeds that file before exec — no per-user config.
{ lib
, stdenv
, appimageTools
, fetchurl
, makeWrapper
, symlinkJoin
, serverUrl ? "http://localhost:8080"
}:

let
  version = "0.4.41";

  # ws(s)://host:port/ws form of the backend server URL.
  wsUrl = "${lib.replaceStrings [ "http://" "https://" ] [ "ws://" "wss://" ] serverUrl}/ws";

  # system -> release asset name + hash. Linux only: mac ships a .dmg, not an AppImage.
  # These hashes are computed from the release assets (upstream's checksums.txt covers
  # the CLI only); re-verify on a version bump.
  platforms = {
    x86_64-linux = {
      asset = "x86_64";
      hash = "sha256-sNIfSxLYXxIa43oH0PiMU7RYaf94hW8bKW9goeSeQvE=";
    };
    aarch64-linux = {
      asset = "arm64";
      hash = "sha256-L4IQgJ3hkbMwyQgzTf6zYnLbuCqqHlMjuOMCfKsopvQ=";
    };
  };

  system = stdenv.hostPlatform.system;
  platform = platforms.${system}
    or (throw "multica-desktop: unsupported system ${system}");

  pname = "multica-desktop";

  src = fetchurl {
    url = "https://github.com/multica-ai/multica/releases/download/v${version}/multica-desktop-${version}-linux-${platform.asset}.AppImage";
    inherit (platform) hash;
  };

  # Extract the bundled .desktop entry and icons so the app shows up in launchers.
  contents = appimageTools.extractType2 { inherit pname version src; };

  unwrapped = appimageTools.wrapType2 {
    inherit pname version src;

    extraInstallCommands = ''
      install -Dm444 ${contents}/multica-desktop.desktop -t $out/share/applications
      substituteInPlace $out/share/applications/multica-desktop.desktop \
        --replace-quiet 'Exec=AppRun' 'Exec=multica-desktop'
      cp -r ${contents}/usr/share/icons $out/share/icons 2>/dev/null || true
    '';

    meta = {
      description = "Desktop client for Multica, a workspace for AI coding agents";
      homepage = "https://github.com/multica-ai/multica";
      license = lib.licenses.asl20;
      mainProgram = "multica-desktop";
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
      platforms = builtins.attrNames platforms;
    };
  };
in
# Wrap the launcher so it points the app at this instance before starting. The app reads
  # `$HOME/.multica/desktop.json` at startup (and never writes it), so overwriting on each
  # launch keeps it pinned to the installed server for whichever user runs it.
symlinkJoin {
  name = "multica-desktop-${version}";
  paths = [ unwrapped ];
  nativeBuildInputs = [ makeWrapper ];
  postBuild = ''
    rm $out/bin/multica-desktop
    makeWrapper ${unwrapped}/bin/multica-desktop $out/bin/multica-desktop \
      --run ${lib.escapeShellArg ''
        mkdir -p "$HOME/.multica"
        cat > "$HOME/.multica/desktop.json" <<'JSON'
        {"schemaVersion":1,"apiUrl":"${serverUrl}","wsUrl":"${wsUrl}"}
        JSON
      ''}
  '';
  inherit (unwrapped) meta;
}
