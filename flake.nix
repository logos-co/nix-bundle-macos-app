{
  description = "Bundle Nix derivations into macOS .app bundles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-bundle-dir = {
      url = "github:logos-co/nix-bundle-dir";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nix-bundle-dir }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        inherit system;
        pkgs = nixpkgs.legacyPackages.${system};
      });
    in
    {
      lib = forAllSystems ({ pkgs, system, ... }: {
        mkMacOSApp = import ./mkMacOSApp.nix { inherit pkgs; };
      });

      bundlers = forAllSystems ({ pkgs, system, ... }:
        let
          mkMacOSApp = import ./mkMacOSApp.nix { inherit pkgs; };
          bundleDirBundlers = nix-bundle-dir.bundlers.${system};

          # Build a bundler that uses a specific nix-bundle-dir bundler variant
          mkBundler = bundleDirBundler: drv:
            let
              name = drv.pname or drv.name or "App";
              bundle = bundleDirBundler drv;

              # Find icon in the derivation
              iconSearchDirs = [
                "${drv}/share/icons/hicolor/512x512/apps"
                "${drv}/share/icons/hicolor/256x256/apps"
                "${drv}/share/icons/hicolor/128x128/apps"
                "${drv}/share/icons"
                "${drv}/share/pixmaps"
              ];

              findIcon = dirs:
                if dirs == []
                then throw ''
                  nix-bundle-macos-app: No icon found in ${drv}/share/icons/ or ${drv}/share/pixmaps/.
                  Use the mkMacOSApp library function directly to specify a custom icon:
                    nix-bundle-macos-app.lib.''${system}.mkMacOSApp {
                      drv = <your-derivation>;
                      name = "YourApp";
                      bundle = <your-bundle>;
                      icon = ./your-icon.icns;
                      infoPlist = ./Info.plist.in;
                    }
                ''
                else
                  let
                    dir = builtins.head dirs;
                    rest = builtins.tail dirs;
                    exists = builtins.pathExists dir;
                    files = if exists then builtins.attrNames (builtins.readDir dir) else [];
                    iconFiles = builtins.filter
                      (f: pkgs.lib.hasSuffix ".icns" f
                        || pkgs.lib.hasSuffix ".png" f)
                      files;
                  in
                    if iconFiles != []
                    then "${dir}/${builtins.head iconFiles}"
                    else findIcon rest;

              iconFile = findIcon iconSearchDirs;

              # Find Info.plist in the derivation
              appDir = "${drv}/share/applications";
              appDirExists = builtins.pathExists appDir;
              plistFiles =
                if appDirExists
                then builtins.filter
                  (f: pkgs.lib.hasSuffix ".plist" f || pkgs.lib.hasSuffix ".plist.in" f || f == "Info.plist")
                  (builtins.attrNames (builtins.readDir appDir))
                else [];
              infoPlist =
                if plistFiles == []
                then throw ''
                  nix-bundle-macos-app: No Info.plist found in ${appDir}.
                  Use the mkMacOSApp library function directly to specify a custom Info.plist:
                    nix-bundle-macos-app.lib.''${system}.mkMacOSApp {
                      drv = <your-derivation>;
                      name = "YourApp";
                      bundle = <your-bundle>;
                      icon = ./your-icon.icns;
                      infoPlist = ./Info.plist.in;
                    }
                ''
                else "${appDir}/${builtins.head plistFiles}";
            in
              mkMacOSApp {
                inherit drv name bundle infoPlist;
                icon = iconFile;
              };
        in
          # Mirror each nix-bundle-dir bundler variant as a macOS .app bundler
          builtins.mapAttrs (_name: mkBundler) bundleDirBundlers
      );
    };
}
