#!/usr/bin/env bash
#
# aibars installer.
#
#   curl -fsSL https://raw.githubusercontent.com/AndrxwWxng/aibars/main/install.sh | bash
#
# it builds from source on purpose. an app you built yourself never picks up a
# quarantine attribute, so you never meet gatekeeper, and there is no developer
# id here to imitate — the build signs the app to run locally and that is all.
#
# written for bash 3.2, which is the bash macos ships.

set -euo pipefail

REPO_URL="https://github.com/AndrxwWxng/aibars.git"
APP_DEST="/Applications/aibars.app"
BUNDLE_ID="dev.aibars.app"
MIN_MACOS_MAJOR=13
# xcode 16 is the floor because xcodegen 2.45 and later write the project in a
# format earlier xcode cannot open. see the readme.
MIN_XCODE_MAJOR=16

WORK=""
LOG=""
# the staged bundle in /Applications while the swap is in flight. cleared by
# hand in the one branch where removing it would destroy the only copy of the
# app left on the machine.
STAGE=""

say() { printf '%s\n' "$*"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

cleanup() {
	status=$?
	# taken back so the exit below cannot re-enter this. nothing here has to run
	# twice, and a cleanup that can recurse is one more thing to reason about.
	trap - EXIT INT TERM HUP
	if [ -n "$WORK" ] && [ -d "$WORK" ]; then rm -rf "$WORK"; fi
	if [ -n "$STAGE" ] && [ -e "$STAGE" ]; then rm -rf "$STAGE"; fi
	# the build log is the only thing worth keeping, and only when it failed.
	if [ "$status" -eq 0 ] && [ -n "$LOG" ] && [ -f "$LOG" ]; then rm -f "$LOG"; fi
	exit "$status"
}
# ctrl-c during a two-minute build is the ordinary way this ends early, and bash
# does not run an EXIT trap for a signal it was never told about — so on EXIT
# alone the derived data, several hundred megabytes of it, and any bundle staged
# in /Applications would both survive the interrupt.
trap cleanup EXIT INT TERM HUP

# a version component is only compared when it really is a number; an unexpected
# sw_vers or xcodebuild format should not stop an install that would have worked.
is_number() {
	case "$1" in
	'' | *[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

# --- what this machine has -------------------------------------------------

if [ "$(uname -s)" != "Darwin" ]; then
	fail "aibars is a macos menu bar app, and this is $(uname -s). nothing to install here."
fi

MACOS_MAJOR="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"
if is_number "$MACOS_MAJOR" && [ "$MACOS_MAJOR" -lt "$MIN_MACOS_MAJOR" ]; then
	fail "aibars needs macos $MIN_MACOS_MAJOR or later. this is macos $(sw_vers -productVersion)."
fi

if ! command -v git >/dev/null 2>&1; then
	fail "git is missing. it comes with xcode, so installing xcode below fixes this too."
fi

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
case "$DEV_DIR" in
'' | *CommandLineTools*)
	fail "aibars is built with xcodebuild, which needs a full xcode — the command line
tools alone are not enough.

  1. install xcode from the app store, or from developer.apple.com/download
  2. open it once and let it finish installing components
  3. point the tools at it:
       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

then run this installer again."
	;;
esac

XCB_OUT="$(xcodebuild -version 2>&1 || true)"
case "$XCB_OUT" in
Xcode*) ;;
*)
	fail "xcodebuild is there but will not run. it said:

$XCB_OUT

if that is about the licence, run: sudo xcodebuild -license accept"
	;;
esac

XCODE_MAJOR="$(printf '%s\n' "$XCB_OUT" | awk 'NR == 1 { print $2 }' | cut -d. -f1)"
if is_number "$XCODE_MAJOR" && [ "$XCODE_MAJOR" -lt "$MIN_XCODE_MAJOR" ]; then
	fail "aibars needs xcode $MIN_XCODE_MAJOR or later to open the generated project. this is xcode $XCODE_MAJOR.
xcode $MIN_XCODE_MAJOR itself needs macos 14.5 or later, so on an older macos there is no
way to build this from source. the app runs on macos $MIN_MACOS_MAJOR once built."
fi

# checked before the build rather than after it, so a machine that cannot
# install fails in a second instead of in two minutes.
if [ ! -w /Applications ]; then
	fail "your account cannot write to /Applications, so aibars cannot be installed there.
log in as an administrator and run this again."
fi

if ! command -v xcodegen >/dev/null 2>&1; then
	if ! command -v brew >/dev/null 2>&1; then
		fail "aibars needs xcodegen to generate its xcode project, and homebrew is not installed
either. install homebrew from https://brew.sh and then run:

  brew install xcodegen"
	fi
	# piped into bash, stdin is the script itself, so there is nobody to ask —
	# and an installer that installs unasked-for software is not one to trust.
	if [ -t 0 ]; then
		printf 'xcodegen is missing. install it with homebrew now? [y/N] '
		reply=""
		read -r reply || true
		case "$reply" in
		y | Y | yes | Yes) brew install xcodegen ;;
		*) fail "nothing installed. when you want it: brew install xcodegen" ;;
		esac
	else
		fail "aibars needs xcodegen to generate its xcode project, and this installer will not
install software you did not ask for. run this first:

  brew install xcodegen

then run the installer again."
	fi
fi

# --- source ----------------------------------------------------------------

WORK="$(mktemp -d -t aibars-install)"

SRC=""
TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$TOP" ] && [ -f "$TOP/project.yml" ] && grep -q '^name: aibars$' "$TOP/project.yml"; then
	SRC="$TOP"
	say "you are inside an aibars checkout, so this builds $SRC rather than cloning."
	if [ -n "$(git -C "$SRC" status --porcelain 2>/dev/null)" ]; then
		say "it has uncommitted changes — nothing is pulled, and what is on disk is what gets built."
	elif git -C "$SRC" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
		say "updating it with git pull --ff-only."
		git -C "$SRC" pull --ff-only --quiet || say "the pull did not go through; building the commit you already have."
	fi
	say "this regenerates aibars.xcodeproj there, the same as make build does."
else
	SRC="$WORK/aibars"
	git clone --depth 1 --quiet "$REPO_URL" "$SRC" ||
		fail "could not clone $REPO_URL. check your network, then try again."
fi

# --- build -----------------------------------------------------------------

# mktemp rather than a pid-derived name: /tmp is world-writable, the pid space is
# small enough to carpet, and a symlink waiting at a guessable path would have
# this script truncate whatever it points at.
LOG="$(mktemp -t aibars-install)"
# the derived data lives in $WORK, which cleanup removes, so every run is a full
# build. saying "the first time" would promise a cache that is not kept.
say "building aibars in release. this takes a minute or two."

if ! (
	cd "$SRC" &&
		xcodegen generate &&
		xcodebuild \
			-project aibars.xcodeproj \
			-scheme aibars \
			-configuration Release \
			-destination 'platform=macOS' \
			-derivedDataPath "$WORK/build" \
			build
) >"$LOG" 2>&1; then
	say ""
	say "the build failed. the last of it:"
	say ""
	tail -n 40 "$LOG" >&2 || true
	fail "
full log: $LOG
if this looks like a bug rather than a missing tool, that log is what to attach to
https://github.com/AndrxwWxng/aibars/issues"
fi

APP="$WORK/build/Build/Products/Release/aibars.app"
[ -d "$APP" ] || fail "the build reported success but produced no app at $APP. full log: $LOG"

# --- install ---------------------------------------------------------------

if [ -e "$APP_DEST" ]; then
	say "replacing the existing $APP_DEST."
fi
if pgrep -x aibars >/dev/null 2>&1; then
	say "quitting the copy of aibars that is running."
	pkill -x aibars || true
	sleep 1
fi

# copy alongside first and swap, so a copy that fails half way through leaves the
# working install where it was. deleting first and then discovering the disk is
# full is how an installer takes away something it cannot give back.
STAGE="$APP_DEST.installing"
rm -rf "$STAGE"
# the failure branches below do not remove $STAGE themselves — cleanup does it
# on the way out, from one place, so a branch added later cannot forget to.
#
# ditto rather than cp, because it keeps the bundle's metadata and so the
# ad-hoc signature the build applied stays valid.
if ! /usr/bin/ditto "$APP" "$STAGE"; then
	fail "could not copy the app into /Applications, so nothing was changed.
$( [ -e "$APP_DEST" ] && printf '%s' "the copy you already had is still there." )"
fi
if [ -e "$APP_DEST" ] && ! rm -rf "$APP_DEST"; then
	fail "could not replace $APP_DEST. it may belong to another account; nothing was changed."
fi
if ! mv "$STAGE" "$APP_DEST"; then
	# the old copy is gone by this line, so the staged one is now the only aibars
	# on the machine. cleaning it up here would be the installer taking away
	# something it cannot give back — which is the whole reason for staging — so
	# it stays, and the user is told where it is.
	KEEP="$STAGE"
	STAGE=""
	fail "could not move the new app into place at $APP_DEST.
the app that was built is at $KEEP, and it is the only copy you have. move it:

  mv \"$KEEP\" \"$APP_DEST\""
fi

open "$APP_DEST" || fail "installed to $APP_DEST, but could not launch it. open it from /Applications."

say ""
say "installed to $APP_DEST and running."
say "look in your MENU BAR, top right of the screen. aibars has no dock icon and no window —"
say "the bars up there are the app. click them for your usage, the gear for settings."
say ""
# everything aibars can leave behind, and where each line was derived from. the
# list used to name two of the six and claim that was all of them, which is how
# 400 days of usage rollups came to survive an uninstall:
#
#   $APP_DEST                       this script's own copy.
#   Preferences/$BUNDLE_ID.plist    UserDefaults.standard, read and written from
#                                   about thirty places. `defaults delete` and
#                                   not rm: cfprefsd holds the domain in memory
#                                   and writes a deleted plist straight back.
#   keychain, service $BUNDLE_ID    KeychainStore.service, Auth/KeychainStore.swift.
#   Application Support/aibars      UsageHistoryStore.defaultDirectory(),
#                                   History/UsageHistoryStore.swift — history.sqlite
#                                   and its two wal sidecars, holding up to the
#                                   400 days that store retains.
#   Caches, WebKit, HTTPStorages    nothing in the sources writes these. macos
#                                   makes them for a bundled app that talks to
#                                   the network and names them after the bundle
#                                   id, so they were found by looking at a machine
#                                   that had run aibars rather than by grepping —
#                                   which is why they need a line here and cannot
#                                   have one in a test.
#   launch at login                 SMAppService, System/LoginItem.swift. the
#                                   registration belongs to macos, so deleting
#                                   the bundle orphans the entry rather than
#                                   removing it, and no command undoes it for
#                                   one app — only the switch does.
#
# printed, never executed. this script is advertised as `curl | bash`, where a
# --uninstall flag could not be reached anyway, and an rm -rf under $HOME driven
# by a script piped in over the network is worse than the drift it would prevent.
say "to uninstall: quit aibars from the menu bar, then rm -rf $APP_DEST"
say "quitting first matters: a copy still running writes its settings back out."
say ""
say "that leaves your settings, any api keys you pasted, and up to 400 days of usage"
say "history. to remove those as well:"
say "  defaults delete $BUNDLE_ID"
say "  security delete-generic-password -s $BUNDLE_ID"
say "  rm -rf \"\$HOME/Library/Application Support/aibars\""
say "  rm -rf \"\$HOME/Library/Caches/$BUNDLE_ID\" \"\$HOME/Library/WebKit/$BUNDLE_ID\""
say "  rm -f \"\$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies\""
say ""
say "and if you switched launch at login on, switch it off before deleting the app."
say "macos holds that registration, not aibars, so a deleted app leaves a dead entry"
say "behind in system settings → general → login items."
