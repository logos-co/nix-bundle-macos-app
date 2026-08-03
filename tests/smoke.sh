#!/usr/bin/env bash
# Smoke test for the macOS .app contract.
#
# This repo is the last step before an artifact reaches a user, and the ways it
# breaks are invisible to `nix build`: the derivation happily succeeds while
# producing an .app whose executable is missing, whose Info.plist is malformed,
# or — the classic — whose binary still resolves its libraries out of
# /nix/store and therefore runs only on the machine that built it.  Nothing
# here checks that the code is nice; every assertion is something a user would
# hit as "the app does not open".
#
# Subject: nixpkgs#hello, chosen because it is tiny, cached, and still links a
# non-system dylib (libiconv) — so the linkage rewrite it exercises is real.
# It is wrapped with the library entry point (lib.mkMacOSApp) rather than the
# `bundlers` mirror because the mirror insists the derivation ship its own
# icon and Info.plist; the test provides those from tests/ instead.
#
# Usage:  tests/smoke.sh [flake-ref]     (default: the checkout, ".")
set -uo pipefail

FLAKE="${1:-.}"
# Absolutise a local flake ref BEFORE cd-ing into the scratch dir, or "." would
# resolve to the scratch dir and nix would report "could not find a flake.nix".
# A ref containing ':' is a URL (github:, git+https:, path:) and is left alone.
case "$FLAKE" in
  *:*) ;;
  *)   FLAKE="$(cd "$FLAKE" 2>/dev/null && pwd)" || { echo "smoke: no such flake dir: ${1:-.}" >&2; exit 1; } ;;
esac
# The Info.plist template belongs to this script, not to the flake under test,
# so resolve it from the script's own directory — also before the cd.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST="$HERE/Info.plist.in"
[ -f "$PLIST" ] || { echo "smoke: missing $PLIST" >&2; exit 1; }

if [ "$(uname -s)" != "Darwin" ]; then
  echo "smoke: this bundler only produces .app bundles on macOS; nothing to assert"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
cd "$WORK"

pass=0; fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; fail=$((fail+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1" "${3:-}"; fi; }

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"

# Wrap nixpkgs#hello into an .app using one of nix-bundle-dir's bundlers.
build_app() {  # <nix-bundle-dir bundler attr> <out-link>
  nix build --impure --print-build-logs -o "$2" --expr "
    let
      flake   = builtins.getFlake \"$FLAKE\";
      system  = \"$SYSTEM\";
      pkgs    = flake.inputs.nixpkgs.legacyPackages.\${system};
      subject = pkgs.hello;
    in flake.lib.\${system}.mkMacOSApp {
      drv       = subject;
      name      = \"SmokeHello\";
      bundle    = flake.inputs.nix-bundle-dir.bundlers.\${system}.$1 subject;
      icon      = builtins.toFile \"smoke.icns\" \"smoke-placeholder\";
      infoPlist = $PLIST;
    }"
}

echo "== bundlers exposed for $SYSTEM =="
BUNDLERS="$(nix eval --raw "$FLAKE#bundlers.$SYSTEM" --apply 'b: builtins.concatStringsSep " " (builtins.attrNames b)' 2>/dev/null)"
echo "  $BUNDLERS"
# The .app bundlers are a 1:1 mirror of nix-bundle-dir's, so a bundler added
# upstream must appear here.  qtCliApp (headless Qt, guiApp = false) is the one
# the tracked nix-bundle-dir revision adds; if it is missing, this repo is
# pinned to an older nix-bundle-dir than it claims.
check "the mirror exposes qtCliApp (i.e. nix-bundle-dir is current)" \
      "printf '%s' '$BUNDLERS' | grep -qw qtCliApp" \
      "got: $BUNDLERS"

echo
echo "== building the .app (qtApp) =="
build_app qtApp app-gui || exit 1
APP="$(readlink -f app-gui)/SmokeHello.app"
C="$APP/Contents"

# CFBundleExecutable is what launchd actually execs; read it rather than
# assuming, so a plist/layout mismatch shows up here instead of in Finder.
EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$C/Info.plist" 2>/dev/null)"

echo
echo "== bundle contract =="
check "Contents/Info.plist exists" "[ -f '$C/Info.plist' ]"
check "Info.plist is well-formed (plutil -lint)" \
      "plutil -lint '$C/Info.plist'" \
      "$(plutil -lint "$C/Info.plist" 2>&1 | tail -1)"
check "Contents/MacOS/\$CFBundleExecutable exists and is executable" \
      "[ -n '$EXEC' ] && [ -x '$C/MacOS/$EXEC' ]" \
      "CFBundleExecutable=${EXEC:-<unset>}"
# mkMacOSApp renames the real program to <name>.bin and puts a tiny env
# wrapper in its place, so the Mach-O to inspect is the .bin.
MACHO="$C/MacOS/$EXEC.bin"
check "the program itself is a Mach-O executable" \
      "file -b '$MACHO' | grep -q '^Mach-O'" \
      "$(file -b "$MACHO" 2>&1)"
check "Contents/PkgInfo exists" "[ -f '$C/PkgInfo' ]"
check "Contents/Resources holds the icon" \
      "ls '$C/Resources' | grep -q '\.icns$'"

echo
echo "== it runs =="
out="$("$C/MacOS/$EXEC" 2>&1)"
check "Contents/MacOS/$EXEC executes and prints its greeting" \
      "printf '%s' \"\$out\" | grep -q 'Hello, world!'" \
      "output: ${out:-<none>}"

echo
echo "== portability: nothing resolves back into /nix/store =="
# The actual promise of a distributable .app.  otool -L on every Mach-O in the
# bundle, not just the main one: a single dylib that kept an absolute install
# name is enough to make the app fail to launch on a machine without Nix.
store_refs() { otool -L "$1" 2>/dev/null | tail -n +2 | grep '/nix/store' ; }
leaky=""
while IFS= read -r m; do
  file -b "$m" 2>/dev/null | grep -q 'Mach-O' || continue
  if store_refs "$m" | grep -q .; then leaky="$leaky $m"; fi
done < <(find "$C/MacOS" "$C/Frameworks" -type f 2>/dev/null)
check "no Mach-O in the .app links against /nix/store" \
      "[ -z '$leaky' ]" \
      "leaking:$leaky"
# An absolute store path in LC_RPATH is the same bug wearing a hat: otool -L
# then shows a clean @rpath/... name while the library is still found only on
# the build host.
check "no LC_RPATH entry points into /nix/store" \
      "! otool -l '$MACHO' | grep -A2 LC_RPATH | grep -q /nix/store" \
      "$(otool -l "$MACHO" | grep -A2 LC_RPATH | grep /nix/store | head -1)"
check "the wrapper script embeds no /nix/store path" \
      "! grep -q /nix/store '$C/MacOS/$EXEC'"

echo
echo "== linking layout =="
# Dylibs live in Contents/Frameworks with Contents/lib symlinked to it, so
# @loader_path/../lib resolves from Contents/MacOS.
check "Contents/lib -> Frameworks symlink is present" \
      "[ -L '$C/lib' ] && [ -d '$C/lib' ]"
check "the program's dylib deps resolve inside the bundle" \
      "! otool -L '$MACHO' | tail -n +2 | grep -vqE '@loader_path|@executable_path|@rpath|/usr/lib/|/System/'" \
      "$(otool -L "$MACHO" | tail -n +2 | grep -vE '@loader_path|@executable_path|@rpath|/usr/lib/|/System/' | head -1)"
# nix-bundle-dir now also gives every Mach-O a bare @loader_path rpath, so a
# plugin staged outside Contents/Frameworks still finds the companion dylibs
# sitting next to it.  Absent => the pinned nix-bundle-dir predates that fix.
check "LC_RPATH includes a bare @loader_path (sibling-dylib lookup)" \
      "otool -l '$MACHO' | grep -A2 LC_RPATH | grep -qE 'path @loader_path\$'" \
      "rpaths: $(otool -l "$MACHO" | grep -A2 LC_RPATH | grep 'path ' | tr -s ' ' | paste -sd, -)"

echo
echo "== no Linux bundling artifacts crossed over =="
# nix-bundle-dir's launcher/companion machinery is guarded to the Linux arm.
# If that guard ever slips, a macOS .app grows a hidden companion Mach-O and a
# shell launcher in Contents/MacOS and stops passing codesign.
check "no hidden .<name>.elf companion in Contents/MacOS" \
      "! ls -a '$C/MacOS' | grep -qE '^\.[^.]'" \
      "$(ls -a "$C/MacOS" | grep -E '^\.[^.]' | tr '\n' ' ')"
check "no libprocself_fix.so anywhere in the .app" \
      "! find '$APP' -name 'libprocself_fix.so' | grep -q ."
check "no ELF interpreter probing in the wrapper" \
      "! grep -qE 'ld-linux|INTERP_NAME|__BUNDLE_REAL_EXE' '$C/MacOS/$EXEC'"

echo
echo "== guiApp is inert on macOS =="
# guiApp only gates the Linux launcher, so the headless bundler must produce a
# byte-identical .app payload.  If this ever diverges, a Linux-only knob has
# started changing macOS output.
if build_app qtCliApp app-cli >/dev/null 2>&1; then
  CLI="$(readlink -f app-cli)/SmokeHello.app"
  check "qtCliApp and qtApp produce identical .app contents" \
        "diff -r '$APP' '$CLI'" \
        "$(diff -r "$APP" "$CLI" 2>&1 | head -3)"
else
  bad "qtCliApp bundle builds" "the pinned nix-bundle-dir has no qtCliApp bundler"
fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
