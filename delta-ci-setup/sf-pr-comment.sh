#!/usr/bin/env bash
# Create or update a single "sticky" PR comment from a Markdown file.
# The comment is identified by a hidden marker, so re-runs edit it instead of adding new comments.
# Usage: sf-pr-comment.sh <pr_number> <marker_key> <body_md_file>
# Requires the gh CLI, GH_TOKEN with pull-requests: write, and GITHUB_REPOSITORY (set by Actions).

set -euo pipefail

PR="$1"
KEY="$2"
BODY_FILE="$3"
MARKER="<!-- $KEY -->"

PAYLOAD="$(mktemp)"
{ echo "$MARKER"; cat "$BODY_FILE"; } | jq -R -s '{ body: .[:65000] }' > "$PAYLOAD"

COMMENT_IDS="$(gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$PR/comments" \
  --jq ".[] | select(.user.login == \"github-actions[bot]\" and (.body | startswith(\"$MARKER\"))) | .id")"
COMMENT_ID="${COMMENT_IDS%%$'\n'*}"

if [ -n "$COMMENT_ID" ]; then
  gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$COMMENT_ID" --input "$PAYLOAD" > /dev/null
  echo "Updated PR #$PR comment $COMMENT_ID"
else
  gh api -X POST "repos/$GITHUB_REPOSITORY/issues/$PR/comments" --input "$PAYLOAD" > /dev/null
  echo "Created PR #$PR comment"
fi

rm -f "$PAYLOAD"
