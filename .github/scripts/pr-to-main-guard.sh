#!/usr/bin/env bash
# pr-to-main-guard.sh  ->  put at .github/scripts/pr-to-main-guard.sh
#
# Required status check for pull requests into main, for the flow:
#   feature branch from main -> merge to develop (deploys STG) -> PR feature to main (PROD)
#
# Blocks the ways that flow ships the wrong thing:
#
#   1. LEAKAGE  the branch has absorbed develop -- branched from it, merged it in, or
#               used GitHub's "Resolve conflicts" button on the PR into develop (that
#               button merges the entire base branch into the head branch).
#   2. COPIES   the same, but hidden by a rebase: the branch carries copies of other
#               branches' commits under new SHAs, which check 1 can't see.
#   3. UNTESTED the exact commit being shipped was never merged to develop, so it
#               never ran on STG -- e.g. review fixes pushed after the develop merge.
#
# Requirements:
#   - full history (actions/checkout with fetch-depth: 0)
#   - develop takes MERGE COMMITS, not squash (squash gives the feature a new SHA on
#     develop, so check 3 can't see that it was tested)
#   - pass the PR head SHA, not HEAD: on pull_request events HEAD is GitHub's
#     synthetic merge commit, which is never on develop
#   - PR_LABELS: comma-separated PR labels (the workflow passes them)
#
# usage: pr-to-main-guard.sh <pr-head-sha>

set -euo pipefail
export LC_ALL=C   # comm/join/sort must agree on collation

HEAD_SHA=${1:?usage: pr-to-main-guard.sh <pr-head-sha>}
MAIN_REF=${MAIN_REF:-origin/main}
DEV_REF=${DEV_REF:-origin/develop}
OVERRIDE_LABEL=rebased-own-commits

show () { git log --no-walk --format='  %h  %an: %s' "$@" | head -20 || true; }

# --- 1. Leakage ---------------------------------------------------------------
# Nothing from develop's own first-parent history may appear in this PR. Feature
# commits merged INTO develop sit on its second-parent side, so a clean branch --
# or one stacked on another feature branch -- passes.
# shellcheck disable=SC2046
leaked=$(comm -12 <(git rev-list --first-parent "$DEV_REF" | sort) \
                  <(git rev-list "$MAIN_REF..$HEAD_SHA" | sort))
if [[ -n "$leaked" ]]; then
  echo "::error::This branch contains develop's history. Merging it would ship unreleased work from other branches:"
  # shellcheck disable=SC2086
  show $leaked
  cat <<'MSG'

Fix: take the develop merge back out of this branch.
  - merge is your latest commit:   git reset --hard HEAD^1 && git push --force-with-lease
  - you've committed since:        reset to the commit before the merge, cherry-pick your later commits back
  - branch was created from develop: new branch from main, cherry-pick only your own commits
  (A plain 'git rebase main' does NOT fix it -- it replays develop's commits too.)
Resolve conflicts with develop ON develop, locally -- never on the feature branch,
and never with GitHub's 'Resolve conflicts' button.
MSG
  exit 1
fi

# --- 2. Copies ----------------------------------------------------------------
# For each commit in this PR whose patch matches a commit on develop that is NOT
# part of this branch, decide which is the original by which reached develop first.
# Only the later one is a copy -- so an innocent branch isn't blocked just because
# someone else's copy of its work landed on develop afterwards.
# Rebasing your own branch after merging it to develop is flagged too (your new
# commits are copies of your old ones); the label is how a human says "all mine".
pid () { git log -p --no-merges --format='commit %H' "$@" | git patch-id --stable; }
fp_oldest_first=$(git rev-list --first-parent --reverse "$DEV_REF")
arrival () {  # oldest first-parent commit of develop containing $1; empty if not on develop
  grep -Fx -m1 -f <(git rev-list --ancestry-path "$1..$DEV_REF") <<<"$fp_oldest_first" || true
}
dupes=""
while read -r _ pr_commit dev_commit; do
  landed=$(arrival "$pr_commit")
  if [[ -z "$landed" ]] || git merge-base --is-ancestor "$dev_commit" "$landed^1"; then
    dupes+="$pr_commit"$'\n'     # develop had the other one first -> this PR carries the copy
  fi
done < <(join <(pid "$MAIN_REF..$HEAD_SHA" | sort) \
              <(pid "$HEAD_SHA..$DEV_REF" "^$MAIN_REF" | sort))
dupes=$(sort -u <<<"$dupes" | sed '/^$/d')
if [[ -n "$dupes" ]]; then
  if [[ ",${PR_LABELS:-}," == *",$OVERRIDE_LABEL,"* ]]; then
    echo "::warning::Contains copies of commits already on develop; allowed by label '$OVERRIDE_LABEL':"
    # shellcheck disable=SC2086
    show $dupes
  else
    echo "::error::This PR contains copies of commits already on develop under different SHAs."
    echo "If any of these aren't yours, another branch's work is leaking into this release:"
    # shellcheck disable=SC2086
    show $dupes
    cat <<MSG

- Not all yours: rebuild the branch from main and cherry-pick only your own commits.
- All yours (you rebased after merging to develop): add the label '$OVERRIDE_LABEL'.
  To avoid this next time, sync from main with 'git merge main', not rebase.
MSG
    exit 1
  fi
fi

# --- 3. Untested --------------------------------------------------------------
if ! git merge-base --is-ancestor "$HEAD_SHA" "$DEV_REF"; then
  echo "::error::Commit ${HEAD_SHA:0:7} has not been merged to develop, so it has not run on STG."
  echo "Fix: merge this branch to develop, let STG deploy, then re-run this check"
  echo "     (a merge into develop does not re-trigger checks on this PR)."
  exit 1
fi

echo "OK: branch is clean, and ${HEAD_SHA:0:7} has been through develop."
