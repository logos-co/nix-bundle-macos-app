{ pkgs }:

{ drv
, name ? drv.pname or drv.name or "App"
, bundle
, icon
, infoPlist
, entitlements ? null
, version ? drv.version or "1.0.0"
, buildNumber ? "1"
}:

let
  iconPath = builtins.toString icon;
  iconBasename = builtins.baseNameOf iconPath;
in

pkgs.stdenv.mkDerivation {
  pname = "${name}-macos-app";
  inherit version;

  src = null;
  dontUnpack = true;
  dontFixup = true;

  nativeBuildInputs = [ pkgs.libxml2 ];

  buildPhase = ''
    appDir="$out/${name}.app/Contents"
    mkdir -p "$appDir/MacOS" "$appDir/Frameworks" "$appDir/Resources"

    # Process Info.plist template first (we need CFBundleExecutable)
    sed -e "s/@VERSION@/${version}/g" \
        -e "s/@BUILD_NUMBER@/${buildNumber}/g" \
        ${infoPlist} > "$appDir/Info.plist"

    # Extract CFBundleExecutable from Info.plist
    mainExec=$(xmllint --xpath '//dict/key[text()="CFBundleExecutable"]/following-sibling::string[1]/text()' "$appDir/Info.plist")

    # Copy binaries from bundle (excluding qt.conf)
    for f in ${bundle}/bin/*; do
      fname=$(basename "$f")
      if [ "$fname" != "qt.conf" ]; then
        if [ "$fname" = "$mainExec" ]; then
          # Rename main executable so the wrapper can take its name
          cp -a "$f" "$appDir/MacOS/$fname.bin"
          chmod +x "$appDir/MacOS/$fname.bin"
        else
          cp -a "$f" "$appDir/MacOS/"
          chmod +x "$appDir/MacOS/$fname" 2>/dev/null || true
        fi
      fi
    done

    # Create wrapper script for the main executable
    cat > "$appDir/MacOS/$mainExec" <<WRAPPER
#!/usr/bin/env bash
DIR="\$(cd "\$(dirname "\$0")" && pwd)"
export QT_PLUGIN_PATH="\$DIR/../Frameworks/qt/plugins"
export QML2_IMPORT_PATH="\$DIR/../Frameworks/qt/qml"
exec "\$DIR/$mainExec.bin" "\$@"
WRAPPER
    chmod +x "$appDir/MacOS/$mainExec"

    # Copy libraries from bundle
    if [ -d "${bundle}/lib" ]; then
      cp -a ${bundle}/lib/. "$appDir/Frameworks/"
    fi

    # Copy extra dirs from the bundle (e.g., preinstall/)
    for dir in ${bundle}/*/; do
      dirname=$(basename "$dir")
      if [ "$dirname" != "bin" ] && [ "$dirname" != "lib" ]; then
        cp -a "$dir" "$appDir/$dirname"
      fi
    done

    # Create lib → Frameworks symlink so @loader_path/../lib/ references resolve
    ln -s Frameworks "$appDir/lib"

    # Create qt.conf for Qt plugin/QML discovery (used when launched via `open`)
    cat > "$appDir/Resources/qt.conf" <<'EOF'
[Paths]
Prefix = ..
Plugins = Frameworks/qt/plugins
Qml2Imports = Frameworks/qt/qml
EOF

    # Copy icon
    cp ${icon} "$appDir/Resources/${iconBasename}"

    # Write PkgInfo
    echo -n "APPL????" > "$appDir/PkgInfo"

    # Ad-hoc code sign
    /usr/bin/codesign --force --deep --sign - "$out/${name}.app" 2>/dev/null || echo "Codesigning skipped (requires macOS)"

    # Re-sign the main executable with entitlements (must be after --deep signing)
    ${if entitlements != null then ''
    /usr/bin/codesign --force --sign - --entitlements ${entitlements} "$appDir/MacOS/$mainExec.bin" 2>/dev/null || echo "Entitlements signing skipped (requires macOS)"
    '' else ""}
  '';

  installPhase = "true";
}
