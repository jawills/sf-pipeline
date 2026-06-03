#!/usr/bin/env bash
# Write Markdown deploy/validate summary to $GITHUB_STEP_SUMMARY.
# Usage: sf-deploy-summarize.sh <validate|deploy> <environment_label> <delta_dir_or_empty> [resume_result_json_or_empty]
# Typical JSON path after jawills/sf-deploy@v2: resume-result.json

set -euo pipefail

MODE="$1"
ENV_LABEL="$2"
DELTA_DIR="${3:-}"
RESULT_JSON="${4:-}"

DELTA_COMPONENTS=0
DELTA_DESTRUCTIVE=0

if [ -n "$DELTA_DIR" ] && [ -d "$DELTA_DIR" ]; then
  PKG_XML="$DELTA_DIR/package/package.xml"
  DES_XML="$DELTA_DIR/destructiveChanges/destructiveChanges.xml"
  if [ -f "$PKG_XML" ]; then
    DELTA_COMPONENTS="$(grep -c '<members>' "$PKG_XML" 2>/dev/null || echo 0)"
  fi
  if [ -f "$DES_XML" ]; then
    DELTA_DESTRUCTIVE="$(grep -c '<members>' "$DES_XML" 2>/dev/null || echo 0)"
  fi
fi

OUT="$(mktemp)"
{
  echo "## Salesforce $MODE — $ENV_LABEL"
  echo ""
  if [ -n "$DELTA_DIR" ]; then
    echo "- **Delta scope:** \`$DELTA_DIR\`"
    echo "- **Package members (add/change):** $DELTA_COMPONENTS"
    echo "- **Destructive members (delete):** $DELTA_DESTRUCTIVE"
    echo ""
  fi

  if [ -z "$RESULT_JSON" ] || [ ! -f "$RESULT_JSON" ]; then
    echo "_No deploy result JSON (empty delta or skipped deploy)._"
    echo ""
  else
    if ! command -v jq &>/dev/null; then
      echo "::warning::jq not found; cannot parse $RESULT_JSON"
    else
      echo "### Deploy result"
      echo ""
      DEPLOY_ID="$(jq -r '(.result.id // .result.deployId) // "n/a"' "$RESULT_JSON")"
      RES_STATUS="$(jq -r '(.result.status // .result.deployResult.status) // "n/a"' "$RESULT_JSON")"
      N_DEP="$(jq -r '.result.numberComponentsDeployed // empty' "$RESULT_JSON")"
      if [ -z "$N_DEP" ] || [ "$N_DEP" = "null" ]; then
        N_DEP="$(jq -r '(.result.deployedSource // []) | length' "$RESULT_JSON")"
      fi
      N_ERR="$(jq -r '.result.numberComponentErrors // 0' "$RESULT_JSON")"
      N_TESTS="$(jq -r '.result.numberTestsCompleted // 0' "$RESULT_JSON")"
      N_TEST_FAIL="$(jq -r '.result.numberTestFailures // 0' "$RESULT_JSON")"
      echo "- **Job / deploy id:** \`$DEPLOY_ID\`"
      echo "- **Status:** $RES_STATUS"
      echo "- **Components deployed (reported):** $N_DEP"
      echo "- **Component errors:** $N_ERR"
      echo "- **Tests completed:** $N_TESTS"
      echo "- **Test failures:** $N_TEST_FAIL"
      echo ""
    fi
  fi
} > "$OUT"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$OUT" >> "$GITHUB_STEP_SUMMARY"
fi
cat "$OUT"
rm -f "$OUT"