#!/bin/sh
# stamp-build.sh — set this app's BUILD NUMBER to the repository's commit count.
#
# ─── THE STANDARD ───────────────────────────────────────────────────────────────
# Michael, 2026-09-04: "lets make that number the build number of the app from now on
# so it is uniform viewable in the app in xcode and app store connect. legally without
# it being a debugging artifact that flags rejection."
#
#     CURRENT_PROJECT_VERSION = git rev-list --count HEAD
#
# WHY THE COMMIT COUNT AND NOT THE SHA. CFBundleVersion must be period-separated
# non-negative integers, and App Store Connect requires every upload to be numerically
# HIGHER than the last in its version train. A SHA is a hash — 0x68c0c9d is 109841565,
# but the next commit could hash lower and Apple would refuse the upload. The commit
# count increments by one per commit, never goes down on a branch, is an integer, and
# names a commit. Michael got this right when I had steered away from it: "githubs
# number has to increase and not go down becaue it has to be a counter number."
#
# It is ordinary version metadata. No review risk.
#
# ─── WHY NOT AN XCODE BUILD PHASE ───────────────────────────────────────────────
# Projects created by recent Xcode set ENABLE_USER_SCRIPT_SANDBOXING = YES, and a
# sandboxed Run Script phase cannot read .git or write into the built product. Turning
# that off to gain a version label trades a real security boundary for a convenience.
# So the stamp is written before the build instead of during it, by a post-commit hook.
#
# ─── PROJECT-AGNOSTIC ───────────────────────────────────────────────────────────
# Finds the .xcodeproj itself, so one copy works in every repo including future ones.
# If the project has a BuildStamp.swift it fills that in too; if not, the build number
# alone still works and the in-app display is the only thing missing.
#
# Absolute path to git: a hook does not inherit an interactive shell's PATH.
set -e
GIT=/usr/bin/git
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

PBX=$(find "$ROOT" -maxdepth 2 -name project.pbxproj -not -path "*/Pods/*" | head -1)
if [ -z "$PBX" ]; then
    echo "stamp-build: no .xcodeproj found under $ROOT — nothing to stamp" >&2
    exit 0
fi

BUILD_NUMBER=$($GIT rev-list --count HEAD 2>/dev/null || echo 1)

# ── THE COUNT CAN REPEAT, SO THE COUNT ALONE IS NOT A NAME ────────────────────────
#
# Michael, 2026-09-07: "use 84.2 to resolve conflict in names."
#
# `rev-list --count` names the commit only while history moves forward. Discard a build
# and commit over it — his own Shell Citadel rule, "any edits after we discard back to
# the current build" — and the NEXT commit lands on the same count as the one thrown
# away. That happened this morning: the rolled-back 84 and its replacement were both
# "build 84", which is exactly the confusion the whole standard exists to end.
#
# Discarded builds are not deleted here, they are TAGGED (broken-84, stable-83), so the
# collision is already recorded in the repository and does not need to be remembered.
# Count the tags that sit at this same commit-count on a DIFFERENT commit; if any do,
# this is the (k+1)th build to wear the number and it says so: 84 -> 84.2.
#
# ⛔ NOT HAND-STAMPED, AND THAT IS THE POINT. A number typed in once "just this once" is
# the complacency he named. This is derived, so it stays right on its own.
# CFBundleVersion allows period-separated integers, so 84.2 is valid where a SHA is not.
HEAD_SHA=$($GIT rev-parse HEAD 2>/dev/null || echo "")
COLLISIONS=0
if [ -n "$HEAD_SHA" ]; then
    for tag in $($GIT tag -l 2>/dev/null); do
        tag_sha=$($GIT rev-list -n 1 "$tag" 2>/dev/null || echo "")
        [ -z "$tag_sha" ] && continue
        [ "$tag_sha" = "$HEAD_SHA" ] && continue
        tag_count=$($GIT rev-list --count "$tag" 2>/dev/null || echo 0)
        [ "$tag_count" = "$BUILD_NUMBER" ] && COLLISIONS=$((COLLISIONS + 1))
    done
fi
if [ "$COLLISIONS" -gt 0 ]; then
    BUILD_NUMBER="${BUILD_NUMBER}.$((COLLISIONS + 1))"
fi
COMMIT=$($GIT rev-parse --short HEAD 2>/dev/null || echo "nogit")
BRANCH=$($GIT rev-parse --abbrev-ref HEAD 2>/dev/null || echo "nogit")
BUILT=$(date "+%Y-%m-%d %H:%M")

# Every target with its own BuildStamp.swift gets stamped (the phone's, and the Apple TV's in Rep Crew TV/,
# added 2026-10-27), so each app on a device names the same commit.
STAMPS=$(find "$ROOT" -maxdepth 3 -name BuildStamp.swift)

# A dirty tree means the binary is that commit PLUS something unrecorded. Say so — a
# stamp claiming a clean commit it isn't is worse than no stamp. The files this script
# rewrites must not count as dirt.
DIRT=$($GIT status --porcelain 2>/dev/null \
        | grep -v "project.pbxproj" \
        | grep -v "BuildStamp.swift" || true)
if [ -n "$DIRT" ]; then
    COMMIT="${COMMIT}+"
fi

/usr/bin/sed -i '' \
    -e "s|CURRENT_PROJECT_VERSION = .*;|CURRENT_PROJECT_VERSION = $BUILD_NUMBER;|" \
    "$PBX"

if [ -n "$STAMPS" ]; then
    echo "$STAMPS" | while IFS= read -r STAMP; do
        /usr/bin/sed -i '' \
            -e "s|static let commit = \".*\"|static let commit = \"$COMMIT\"|" \
            -e "s|static let branch = \".*\"|static let branch = \"$BRANCH\"|" \
            -e "s|static let built = \".*\"|static let built = \"$BUILT\"|" \
            "$STAMP"
    done
    echo "build number: $BUILD_NUMBER   commit: $COMMIT ($BRANCH)"
else
    echo "build number: $BUILD_NUMBER   commit: $COMMIT ($BRANCH)   [no BuildStamp.swift — in-app display not wired]"
fi
