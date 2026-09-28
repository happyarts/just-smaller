# Sourced by the build and test scripts: points DEVELOPER_DIR at a full Xcode.
# SwiftPM needs one for the string catalogs; the Command Line Tools are not
# enough. A DEVELOPER_DIR that is already set wins, then xcode-select if it
# points at an Xcode, then Xcode.app before Xcode-beta.app, /Applications
# before ~/Applications. DEVELOPER_DIR avoids `sudo xcode-select`.
if [ -z "${DEVELOPER_DIR:-}" ]; then
	case "$(xcode-select -p 2>/dev/null || true)" in
		*.app/Contents/Developer) DEVELOPER_DIR=$(xcode-select -p) ;;
		*)
			for xcode in /Applications/Xcode.app "$HOME/Applications/Xcode.app" \
				/Applications/Xcode-beta.app "$HOME/Applications/Xcode-beta.app"; do
				[ -x "$xcode/Contents/Developer/usr/bin/xcodebuild" ] && { DEVELOPER_DIR="$xcode/Contents/Developer"; break; }
			done ;;
	esac
fi
[ -n "${DEVELOPER_DIR:-}" ] || { echo >&2 "error: no Xcode found; set DEVELOPER_DIR"; exit 1; }
export DEVELOPER_DIR
# An SDKROOT from the Command Line Tools would override Xcode's SDK.
case "${SDKROOT:-}" in /Library/Developer/CommandLineTools/*) unset SDKROOT ;; esac
