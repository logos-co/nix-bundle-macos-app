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

  nativeBuildInputs = [ pkgs.libxml2 pkgs.python3 pkgs.findutils ];

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
export QT_PLUGIN_PATH="\$DIR/../Resources/qt/plugins"
export QML2_IMPORT_PATH="\$DIR/../Resources/qt/qml"
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

    # Make everything writable — files copied from the Nix store are read-only
    chmod -R u+w "$appDir"

    # Create lib → Frameworks symlink so @loader_path/../lib/ references resolve
    ln -s Frameworks "$appDir/lib"

    # --- Notarization-ready fixups ---

    # (a) Move Qt resources out of Frameworks/ into Resources/
    #     Frameworks/ is deep-inspected by codesign — non-Mach-O files (QML JS,
    #     JSON, images) in there cause "code object is not signed" errors.
    if [ -d "$appDir/Frameworks/qt" ]; then
      mv "$appDir/Frameworks/qt" "$appDir/Resources/qt"
    fi
    # Move app QML module dirs (e.g. Logos/) into the qt/qml tree
    for qmldir in "$appDir/Frameworks"/*/; do
      qmldirname=$(basename "$qmldir")
      # Skip actual framework bundles and anything not a plain directory
      case "$qmldirname" in *.framework) continue;; esac
      if [ -d "$appDir/Resources/qt/qml" ]; then
        rm -rf "$appDir/Resources/qt/qml/$qmldirname"
        mv "$qmldir" "$appDir/Resources/qt/qml/$qmldirname"
      fi
    done

    # (b) Clean broken symlinks left over from moves
    find "$appDir/Resources" -type l ! -exec test -e {} \; -delete 2>/dev/null || true

    # (c) Fix @loader_path references in Resources/qt dylibs
    #     After moving from Frameworks/ to Resources/, the @loader_path refs in
    #     Qt plugin dylibs still point relative to Frameworks/. Rewrite them.
    find "$appDir/Resources/qt" -name "*.dylib" -type f | while read -r dylib; do
      otool -L "$dylib" 2>/dev/null | grep '@loader_path' | awk '{print $1}' | while read -r dep; do
        lib_name=$(basename "$dep")
        dylib_dir=$(dirname "$dylib")
        rel_path=$(python3 -c "import os; print(os.path.relpath('$appDir/Frameworks', '$dylib_dir'))")
        new_path="@loader_path/''${rel_path}/''${lib_name}"
        install_name_tool -change "$dep" "$new_path" "$dylib" 2>/dev/null || true
      done
    done

    # (d) Remove static libraries from Frameworks/
    find "$appDir/Frameworks" -name "*.a" -delete

    # (e) Fix Qt framework bundle structure
    #     Qt frameworks ship without Resources/Info.plist which makes codesign
    #     reject them as "bundle format unrecognized".
    for fw in "$appDir/Frameworks/"*.framework; do
      [ -d "$fw" ] || continue
      fw_name=$(basename "$fw" .framework)
      fw_resources="$fw/Versions/A/Resources"
      mkdir -p "$fw_resources"
      cat > "$fw_resources/Info.plist" <<FWEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>org.qt-project.''${fw_name}</string>
    <key>CFBundleName</key>
    <string>''${fw_name}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
FWEOF
      if [ ! -e "$fw/Resources" ]; then
        ln -s "Versions/Current/Resources" "$fw/Resources"
      fi
    done

    # (f) Strip extended attributes
    xattr -cr "$out/${name}.app" 2>/dev/null || true

    # Create qt.conf for Qt plugin/QML discovery (used when launched via `open`)
    cat > "$appDir/Resources/qt.conf" <<'EOF'
[Paths]
Prefix = ..
Plugins = Resources/qt/plugins
Qml2Imports = Resources/qt/qml
EOF

    # Copy icon
    cp ${icon} "$appDir/Resources/${iconBasename}"

    # Write PkgInfo
    echo -n "APPL????" > "$appDir/PkgInfo"

    # Ad-hoc code sign — sign Resources/qt dylibs first (--deep only covers Frameworks/)
    find "$appDir/Resources/qt" -name "*.dylib" -type f -exec \
      /usr/bin/codesign --force --sign - {} \; 2>/dev/null || true
    /usr/bin/codesign --force --deep --sign - "$out/${name}.app" 2>/dev/null || echo "Codesigning skipped (requires macOS)"

    # Re-sign the main executable with entitlements (must be after --deep signing)
    ${if entitlements != null then ''
    /usr/bin/codesign --force --sign - --entitlements ${entitlements} "$appDir/MacOS/$mainExec.bin" 2>/dev/null || echo "Entitlements signing skipped (requires macOS)"
    '' else ""}
  '';

  installPhase = "true";
}
