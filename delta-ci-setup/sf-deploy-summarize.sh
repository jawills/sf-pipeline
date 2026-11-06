#!/usr/bin/env bash
# Write Markdown deploy/validate summary to $GITHUB_STEP_SUMMARY, emit inline annotations for
# component errors / Apex test failures, and optionally write a detailed report for a PR comment.
# Usage: sf-deploy-summarize.sh <validate|deploy> <environment_label> <delta_dir_or_empty> [resume_result_json_or_empty] [pr_comment_md_out]
# Typical JSON path after jawills/sf-deploy@v2: resume-result.json
# SOURCE_DIR (default force-app) is searched to map failures back to files for annotations.

set -euo pipefail

MODE="$1"
ENV_LABEL="$2"
DELTA_DIR="${3:-}"
RESULT_JSON="${4:-}"
COMMENT_OUT="${5:-}"
SOURCE_DIR="${SOURCE_DIR:-force-app}"
MAX_ROWS=200

DELTA_COMPONENTS=0
DELTA_DESTRUCTIVE=0
PKG_XML=""
DES_XML=""

if [ -n "$DELTA_DIR" ] && [ -d "$DELTA_DIR" ]; then
  PKG_XML="$DELTA_DIR/package/package.xml"
  DES_XML="$DELTA_DIR/destructiveChanges/destructiveChanges.xml"
  if [ -f "$PKG_XML" ]; then
    DELTA_COMPONENTS="$(grep -c '<members>' "$PKG_XML" 2>/dev/null || true)"
  fi
  if [ -f "$DES_XML" ]; then
    DELTA_DESTRUCTIVE="$(grep -c '<members>' "$DES_XML" 2>/dev/null || true)"
  fi
fi
DELTA_COMPONENTS="${DELTA_COMPONENTS:-0}"
DELTA_DESTRUCTIVE="${DELTA_DESTRUCTIVE:-0}"

HAS_RESULT=false
if [ -n "$RESULT_JSON" ] && [ -f "$RESULT_JSON" ] && command -v jq &>/dev/null; then
  HAS_RESULT=true
fi

# Print "<type>\t<member>" for every member in a package.xml-style manifest.
manifest_members() {
  [ -f "$1" ] || return 0
  awk '
    /<members>/ { gsub(/.*<members>|<\/members>.*/, ""); m[++n] = $0 }
    /<name>/    { gsub(/.*<name>|<\/name>.*/, ""); for (i = 1; i <= n; i++) print $0 "\t" m[i]; n = 0 }
  ' "$1" | sort
}

# Shared jq helpers for reading resume-result.json.
JQ_LIB='
  def arr(x): if x == null then [] elif (x | type) == "array" then x elif x == {} then [] else [x] end;
  def rt: (.result.details.runTestResult // .result.runTestResult // {});
  def md: tostring | gsub("\\|"; "\\|") | gsub("\r?\n"; "<br>");
  def clip: tostring | if length > 500 then .[:500] + "…" else . end;
  def ann_esc: tostring | gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
  def prop_esc: ann_esc | gsub(":"; "%3A") | gsub(","; "%2C");
  def locate($suffix): if $suffix == null then null
    else ($files | map(select(. == $suffix or endswith("/" + $suffix))) | first) end;
  def test_line($cls): (.stackTrace // "") as $s
    | [$s | match("Class\\." + $cls + "\\.[^:\\n]*: line ([0-9]+)"; "g")] | first | .captures[0].string? // null;
  def annotation($level; $file; $line; $title; $msg):
    "::\($level) " + ([
      (if $file then "file=" + ($file | prop_esc) else empty end),
      (if $file and $line then "line=\($line)" else empty end),
      "title=" + ($title | prop_esc)
    ] | join(",")) + "::" + ($msg | ann_esc);
  def component_failures: arr(.result.details.componentFailures);
  def test_failures: arr(rt.failures);
  def coverage_warnings: arr(rt.codeCoverageWarnings);
'

run_jq() {
  local files_json
  files_json="$( (find "$SOURCE_DIR" -type f 2>/dev/null || true) | jq -R -s 'split("\n") | map(select(length > 0))')"
  jq -r --argjson files "$files_json" "$JQ_LIB $1" "$RESULT_JSON"
}

# ---------------------------------------------------------------------------
# Short summary (job summary + top of the PR comment)
# ---------------------------------------------------------------------------
OUT="$(mktemp)"
{
  STATUS=""
  if [ "$HAS_RESULT" = true ]; then
    STATUS="$(jq -r '(.result.status // .result.deployResult.status) // "n/a"' "$RESULT_JSON")"
  fi
  case "$STATUS" in
    Succeeded) ICON="✅ " ;;
    Failed|Canceled|SucceededPartial) ICON="❌ " ;;
    *) ICON="" ;;
  esac
  echo "## ${ICON}Salesforce $MODE — $ENV_LABEL"
  echo ""
  if [ -n "$DELTA_DIR" ]; then
    echo "- **Delta scope:** \`$DELTA_DIR\`"
    echo "- **Package members (add/change):** $DELTA_COMPONENTS"
    echo "- **Destructive members (delete):** $DELTA_DESTRUCTIVE"
    echo ""
  fi

  if [ -z "$RESULT_JSON" ] || [ ! -f "$RESULT_JSON" ]; then
    if [ "$DELTA_COMPONENTS" -eq 0 ] && [ "$DELTA_DESTRUCTIVE" -eq 0 ]; then
      echo "_No deploy result JSON (empty delta or skipped deploy)._"
    else
      echo "_No deploy result JSON ($MODE step may have failed before writing output)._"
    fi
    echo ""
  elif [ "$HAS_RESULT" != true ]; then
    echo "::warning::jq not found; cannot parse $RESULT_JSON"
  else
    echo "### Deploy result"
    echo ""
    DEPLOY_ID="$(jq -r '(.result.id // .result.deployId) // "n/a"' "$RESULT_JSON")"
    N_DEP="$(jq -r '.result.numberComponentsDeployed // empty' "$RESULT_JSON")"
    if [ -z "$N_DEP" ] || [ "$N_DEP" = "null" ]; then
      N_DEP="$(jq -r '(.result.deployedSource // []) | length' "$RESULT_JSON")"
    fi
    N_ERR="$(jq -r '.result.numberComponentErrors // 0' "$RESULT_JSON")"
    N_TESTS="$(jq -r '.result.numberTestsCompleted // 0' "$RESULT_JSON")"
    N_TEST_FAIL="$(jq -r '.result.numberTestFailures // 0' "$RESULT_JSON")"
    echo "- **Job / deploy id:** \`$DEPLOY_ID\`"
    echo "- **Status:** $STATUS"
    echo "- **Components deployed (reported):** $N_DEP"
    echo "- **Component errors:** $N_ERR"
    echo "- **Tests completed:** $N_TESTS"
    echo "- **Test failures:** $N_TEST_FAIL"
    echo ""
  fi
} > "$OUT"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$OUT" >> "$GITHUB_STEP_SUMMARY"
fi
cat "$OUT"

# ---------------------------------------------------------------------------
# Inline annotations (shown on the PR "Files changed" tab and the checks page)
# ---------------------------------------------------------------------------
if [ "$HAS_RESULT" = true ]; then
  run_jq '
    (component_failures[]
      | annotation(
          (if .problemType == "Warning" then "warning" else "error" end);
          locate(.fileName); .lineNumber;
          "\(.componentType // "Component") \(.fullName // "") failed";
          .problem // "Unknown error")),
    (test_failures[]
      | (.name // "") as $cls
      | annotation("error"; locate($cls + ".cls"); test_line($cls);
          "Apex test failed: \($cls).\(.methodName // "")";
          (.message // "") + (if (.stackTrace // "") != "" then "\n\n" + .stackTrace else "" end))),
    (coverage_warnings[]
      | annotation("warning";
          (if (.name | type) == "string" then locate(.name + ".cls") else null end); null;
          "Code coverage" + (if (.name | type) == "string" then ": " + .name else "" end);
          .message // ""))
  ' || echo "::warning::Could not emit annotations from $RESULT_JSON"
fi

# ---------------------------------------------------------------------------
# Detailed PR comment
# ---------------------------------------------------------------------------
if [ -n "$COMMENT_OUT" ]; then
  {
    cat "$OUT"

    if [ "$HAS_RESULT" = true ]; then
      FAIL_ROWS="$(run_jq "[component_failures[] | \"| \(.componentType // \"—\" | md) | \(.fullName // \"—\" | md) | \(.lineNumber // \"—\") | \(.problem // \"\" | clip | md) |\"] | .[:$MAX_ROWS] | .[]")"
      if [ -n "$FAIL_ROWS" ]; then
        echo "### ❌ Component failures"
        echo ""
        echo "| Type | Component | Line | Problem |"
        echo "| --- | --- | --- | --- |"
        echo "$FAIL_ROWS"
        echo ""
      fi

      TEST_ROWS="$(run_jq "[test_failures[] | \"| \(.name // \"—\" | md) | \(.methodName // \"—\" | md) | \(.message // \"\" | clip | md) | \(.stackTrace // \"\" | clip | md) |\"] | .[:$MAX_ROWS] | .[]")"
      if [ -n "$TEST_ROWS" ]; then
        echo "### ❌ Apex test failures"
        echo ""
        echo "| Test class | Method | Message | Stack trace |"
        echo "| --- | --- | --- | --- |"
        echo "$TEST_ROWS"
        echo ""
      fi

      COV_ROWS="$(run_jq "[coverage_warnings[] | \"| \(.name // \"(org-wide)\" | md) | \(.message // \"\" | clip | md) |\"] | .[:$MAX_ROWS] | .[]")"
      if [ -n "$COV_ROWS" ]; then
        echo "### ⚠️ Code coverage warnings"
        echo ""
        echo "| Class | Message |"
        echo "| --- | --- |"
        echo "$COV_ROWS"
        echo ""
      fi
    fi

    CHANGES="$( { manifest_members "$PKG_XML" | sed 's/$/\tAdded \/ changed/'; manifest_members "$DES_XML" | sed 's/$/\tDeleted/'; } || true)"
    if [ -n "$CHANGES" ]; then
      TOTAL="$(printf '%s\n' "$CHANGES" | wc -l | tr -d ' ')"
      echo "<details><summary><strong>Changed components ($TOTAL)</strong></summary>"
      echo ""
      echo "| Type | Component | Change |"
      echo "| --- | --- | --- |"
      printf '%s\n' "$CHANGES" | head -n "$MAX_ROWS" | awk -F '\t' '{ gsub(/\|/, "\\|"); print "| " $1 " | " $2 " | " $3 " |" }'
      if [ "$TOTAL" -gt "$MAX_ROWS" ]; then
        echo ""
        echo "_Showing first $MAX_ROWS of $TOTAL components._"
      fi
      echo ""
      echo "</details>"
      echo ""
    fi

    if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
      echo "[View workflow run]($GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID)"
    fi
  } > "$COMMENT_OUT"
fi

rm -f "$OUT"
