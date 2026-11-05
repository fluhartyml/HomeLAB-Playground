#!/bin/sh
# Installs this repo's git hooks. Run ONCE per clone, per machine.
#
# Git deliberately does not copy hooks when a repository is cloned, so a hook that lives
# only in .git/hooks is one machine away from not existing at all. Keeping the real copy
# in Scripts/ and installing from there means the behaviour travels with the repository.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cp "$ROOT/Scripts/post-commit" "$ROOT/.git/hooks/post-commit"
chmod +x "$ROOT/.git/hooks/post-commit"
chmod +x "$ROOT/Scripts/stamp-build.sh"

# ⚠️ PROVE IT RUNS. Installing a hook and never firing it is how the first version of
# this went unnoticed through twelve commits. Do not report success on a copy alone.
if "$ROOT/.git/hooks/post-commit"; then
    echo "installed and verified: .git/hooks/post-commit"
else
    echo "INSTALLED BUT FAILED TO RUN — exit $? — build number will NOT update" >&2
    exit 1
fi
