#!/usr/bin/env bash
# Build ~/Applications/Aerc Mailto.app and make it the handler for mailto:
# links, so a mailto: link opens a composer in aerc. bootstrap.sh runs this;
# running it again rebuilds the app.
#
# The app is an AppleScript applet that only passes the link, as one quoted
# argument, to ~/.config/aerc/mailto-aerc (stowed from aerc/). That script
# does the work; see its docstring. Output of the script:
# ~/Library/Logs/aerc-mailto.log.
#
# Undo: make Mail the handler again, then delete the app:
#   osascript -l JavaScript -e 'ObjC.import("CoreServices");
#     $.LSSetDefaultHandlerForURLScheme($("mailto"), $("com.apple.mail"))'
#   rm -rf ~/Applications/"Aerc Mailto.app"
set -euo pipefail

APP="$HOME/Applications/Aerc Mailto.app"
ID=dev.achere.aerc-mailto
PLIST="$APP/Contents/Info.plist"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

src=$(mktemp -d)
trap 'rm -rf "$src"' EXIT
cat >"$src/main.applescript" <<'EOF'
-- Aerc Mailto: the macOS handler for mailto: links. Built by
-- ~/dotfiles/apps/aerc-mailto/build.sh. All logic is in
-- ~/.config/aerc/mailto-aerc; the link goes to it as one quoted argument.
on open location theURL
	runHandler(quoted form of theURL)
end open location

-- Opened without a link (Finder, Spotlight): start or show aerc.
on run
	runHandler("")
end run

on runHandler(args)
	set homeDir to POSIX path of (path to home folder)
	set cmd to quoted form of (homeDir & ".config/aerc/mailto-aerc")
	set logFile to quoted form of (homeDir & "Library/Logs/aerc-mailto.log")
	-- In the background, so the applet quits at once while aerc starts.
	do shell script cmd & " " & args & " >>" & logFile & " 2>&1 &"
end runHandler
EOF

mkdir -p "$HOME/Applications"
rm -rf "$APP"
osacompile -o "$APP" "$src/main.applescript"

pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
# osacompile writes no CFBundleIdentifier; macOS needs one to name the handler.
pb "Delete :CFBundleIdentifier" 2>/dev/null || true
pb "Add :CFBundleIdentifier string $ID"
pb "Delete :CFBundleURLTypes" 2>/dev/null || true
pb "Add :CFBundleURLTypes array"
pb "Add :CFBundleURLTypes:0 dict"
pb "Add :CFBundleURLTypes:0:CFBundleURLName string Email Address URL"
pb "Add :CFBundleURLTypes:0:CFBundleURLSchemes array"
pb "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string mailto"
# No Dock icon: the applet runs for a moment only.
pb "Delete :LSUIElement" 2>/dev/null || true
pb "Add :LSUIElement bool true"

# Editing Info.plist breaks osacompile's ad-hoc signature, and macOS on
# Apple silicon does not start an app with a broken signature. Sign again.
codesign --force --deep --sign - "$APP"
"$LSREGISTER" -f "$APP"

osascript -l JavaScript -e "ObjC.import('CoreServices');
  \$.LSSetDefaultHandlerForURLScheme(\$('mailto'), \$('$ID'))" >/dev/null
handler=$(osascript -l JavaScript -e "ObjC.import('CoreServices');
  ObjC.castRefToObject(\$.LSCopyDefaultHandlerForURLScheme(\$('mailto'))).js")
if [ "$handler" != "$ID" ]; then
  echo "mailto: handler is $handler, not $ID. Accept the macOS prompt, or" \
       "pick Aerc Mailto in Mail > Settings > General > Default email reader." >&2
  exit 1
fi
echo "mailto: links now open in aerc ($APP)"
