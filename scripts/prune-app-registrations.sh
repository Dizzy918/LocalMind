#!/bin/bash
#
# Removes duplicate LocalMind entries from the LaunchServices database.
#
# Why this is needed: Xcode runs `lsregister` on every build, so each Debug and
# Release product — and each DerivedData folder, and any stale ./build output —
# becomes its own registered application. They all share one bundle identifier
# but sit at different paths, and Spotlight lists paths, so typing "LocalMind"
# starts returning several identical-looking results. Deleting the folders
# afterwards doesn't help: the registration outlives the bundle and becomes a
# dangling entry.
#
# This only affects machines that build the app. A user who installs LocalMind
# from a release has exactly one copy and never sees it.
#
# Usage:
#   ./scripts/prune-app-registrations.sh          # show what would change
#   ./scripts/prune-app-registrations.sh --apply  # actually prune
#
set -euo pipefail

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY=false
[[ "${1:-}" == "--apply" ]] && APPLY=true

if [[ ! -x "$LSREGISTER" ]]; then
  echo "lsregister not found — nothing to do." >&2
  exit 0
fi

# Every registered LocalMind.app, excluding the nested Sparkle updater (which
# is a legitimate helper inside the bundle, not a duplicate of the app).
#
# Read with a while loop rather than `mapfile`: macOS ships bash 3.2, where
# mapfile doesn't exist, and this script has to run on a stock machine.
REGISTERED=()
while IFS= read -r line; do
  [[ -n "$line" ]] && REGISTERED+=("$line")
done < <(
  "$LSREGISTER" -dump 2>/dev/null \
    | grep "path:.*LocalMind\.app (" \
    | grep -v "Sparkle" \
    | sed -E 's/^[[:space:]]*path:[[:space:]]*//; s/ \(0x[0-9a-f]+\)$//' \
    | sort -u
)

if [[ ${#REGISTERED[@]} -le 1 ]]; then
  echo "✓ ${#REGISTERED[@]} registration — nothing to prune."
  [[ ${#REGISTERED[@]} -eq 1 ]] && echo "  ${REGISTERED[0]}"
  exit 0
fi

# Keep whichever copy the developer actually runs: an installed app if there is
# one, otherwise the current DerivedData Debug build.
KEEP=""
for candidate in "${REGISTERED[@]}"; do
  if [[ "$candidate" == /Applications/* ]]; then KEEP="$candidate"; break; fi
done
if [[ -z "$KEEP" ]]; then
  for candidate in "${REGISTERED[@]}"; do
    if [[ "$candidate" == *"/Build/Products/Debug/LocalMind.app" && -d "$candidate" ]]; then
      KEEP="$candidate"; break
    fi
  done
fi
[[ -z "$KEEP" ]] && KEEP="${REGISTERED[0]}"

echo "Found ${#REGISTERED[@]} registrations."
echo "Keeping: $KEEP"
echo

for candidate in "${REGISTERED[@]}"; do
  [[ "$candidate" == "$KEEP" ]] && continue
  if $APPLY; then
    "$LSREGISTER" -u "$candidate" 2>/dev/null || true
    echo "  unregistered  $candidate"
  else
    echo "  would unregister  $candidate"
  fi
done

# An in-repo ./build directory is the usual source of an extra copy — it comes
# from running xcodebuild without a scheme, and it is not used by CI or by the
# release process.
if [[ -d "$REPO_ROOT/build" ]]; then
  echo
  if $APPLY; then
    rm -rf "$REPO_ROOT/build"
    echo "  removed stale $REPO_ROOT/build"
  else
    echo "  would remove stale $REPO_ROOT/build ($(du -sh "$REPO_ROOT/build" 2>/dev/null | cut -f1))"
  fi
fi

echo
$APPLY && echo "Done. Spotlight may take a moment to catch up." \
       || echo "Dry run. Re-run with --apply to make these changes."
