#!/usr/bin/env bash
#
# scripts/check-purity.sh
#
# Mechanical enforcement of CONTRIBUTING.md red lines for entelecheia-product:
#   #1 — No `from entelecheia ...` imports anywhere (product never imports engine)
#   #2 — No business / domain / product names as string literals in packages/platform-*
#        and apps/* (those words live only in packages/verticals/<id>/ and docs/)
#   #3 — Verticals do not import each other
#   #4 — Platform features do not bypass studio-client (no raw URLs to studio in
#        packages/platform-features/* or apps/api/*)
#   #5 — The deprecated word "roundtable" / "Roundtable" appears nowhere in code
#        (the deliberation feature is named `agora`)
#
# Exits 0 if zero violations; exits 1 if any. Patterns are intentionally
# loose enough to catch obvious problems and tight enough to avoid noise.
#
# Run locally before pushing:
#   bash scripts/check-purity.sh
#
# CI runs the same script.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VIOLATIONS=0

red()    { printf "\033[31m%s\033[0m" "$1"; }
yellow() { printf "\033[33m%s\033[0m" "$1"; }
green()  { printf "\033[32m%s\033[0m" "$1"; }

# ─── Helper: scan code in a glob excluding tests ──────────────────────
scan_paths() {
  # $1 = description
  # $2 = grep pattern (extended regex)
  # $3 = paths (space-separated globs to scan)
  # $4 = (optional) include extension filter, default *.py
  # $5 = (optional) extra exclusion regex (combined with the standard one)
  local desc="$1" pattern="$2" paths="$3" include="${4:-*.py}" extra_excl="${5:-}"

  # Check if any of the paths actually exist (and have files matching `include`)
  local any_exists=0
  for p in $paths; do
    if compgen -G "$p" > /dev/null 2>&1; then
      any_exists=1
      break
    fi
  done

  if [ "$any_exists" -eq 0 ]; then
    printf "  %s %s (no source dirs yet — Day 0)\n" "$(yellow "·")" "$desc"
    return 0
  fi

  local exclude_pattern="(__pycache__|\.pyc|/tests/|test_|conftest\.py|/\.venv/|/node_modules/|/dist/)"
  if [ -n "$extra_excl" ]; then
    exclude_pattern="${exclude_pattern}|${extra_excl}"
  fi

  local found
  found=$(grep -rEn "$pattern" $paths \
            --include="$include" 2>/dev/null \
          | grep -vE "$exclude_pattern" || true)

  if [ -n "$found" ]; then
    printf "  %s %s\n" "$(red "✗")" "$desc"
    printf "%s\n" "$found" | head -10 | sed 's/^/    /'
    local count
    count=$(printf "%s\n" "$found" | wc -l | tr -d ' ')
    if [ "$count" -gt 10 ]; then
      printf "    ... and %d more\n" "$((count - 10))"
    fi
    VIOLATIONS=$((VIOLATIONS + count))
  else
    printf "  %s %s\n" "$(green "✓")" "$desc"
  fi
}

printf "\n══════════════════════════════════════════════════════════════════\n"
printf " Entelecheia-product purity check\n"
printf " Date: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "══════════════════════════════════════════════════════════════════\n\n"

# ─── Red line #1: no engine imports anywhere ──────────────────────────
printf "── Red line #1: product never imports engine ────────────────────\n"
# Forbidden: from entelecheia import X  /  import entelecheia
# Allowed: nothing — product talks to studio, not engine.
scan_paths \
  "no 'from entelecheia ...' or 'import entelecheia' (use studio-client instead)" \
  "^(from[[:space:]]+entelecheia([[:space:]]|\.|$)|import[[:space:]]+entelecheia([[:space:]]|\.|$))" \
  "packages apps"
printf "\n"

# ─── Red line #2: no business words in platform-* ─────────────────────
printf "── Red line #2: no business / domain words in packages/platform-* + apps/* ──\n"
# Specific business-domain word lists. Strings only (in quotes), so the rule
# rejects e.g. "investment" but tolerates the word in comments/identifiers
# (which still flow through reviewer judgment).
scan_paths \
  "specific business domains as string literals in platform-shell" \
  "['\"](investment|legal|medical|policy|due_diligence|investment_research|risk_management)['\"]" \
  "packages/platform-shell"
scan_paths \
  "specific business domains as string literals in platform-features" \
  "['\"](investment|legal|medical|policy|due_diligence|investment_research|risk_management)['\"]" \
  "packages/platform-features"
scan_paths \
  "specific business domains as string literals in apps" \
  "['\"](investment|legal|medical|policy|due_diligence|investment_research|risk_management)['\"]" \
  "apps"
scan_paths \
  "specific product names as string literals (Magellan etc.)" \
  "['\"](Magellan|magellan|BP)['\"]" \
  "packages/platform-shell packages/platform-features apps"
scan_paths \
  "specific business agent role names as string literals" \
  "['\"](RiskAssessor|DCFAnalyst|CaseLawAnalyst|MarketAnalyst|ContrarianAnalyst|FinancialExpert|MacroEconomist|ESGAnalyst|SentimentAnalyst|QuantStrategist|LegalAdvisor)['\"]" \
  "packages/platform-shell packages/platform-features apps"

# Same checks against frontend (.ts/.vue) — the platform shell + features
# also live there.
scan_paths \
  "specific business domains as string literals in frontend platform code" \
  "['\"](investment|legal|medical|policy|due_diligence)['\"]" \
  "packages/platform-shell packages/platform-features apps/frontend/src" \
  "*.ts"
scan_paths \
  "specific business domains as string literals in Vue templates" \
  "['\"](investment|legal|medical|policy|due_diligence)['\"]" \
  "packages/platform-shell packages/platform-features apps/frontend/src" \
  "*.vue"
printf "\n"

# ─── Red line #3: verticals do not import each other ──────────────────
printf "── Red line #3: verticals are independent ───────────────────────\n"
if compgen -G "packages/verticals/*" > /dev/null 2>&1; then
  # Find python files under each vertical that import another vertical.
  found=""
  for vd in packages/verticals/*/; do
    [ -d "$vd" ] || continue
    vid=$(basename "$vd")
    [ "$vid" = "_template" ] && continue
    # Find imports referencing other verticals
    others=$(grep -rEn \
                "from[[:space:]]+entelecheia_vertical_[a-z_]+|from[[:space:]]+packages\.verticals\.[a-z_]+|import[[:space:]]+entelecheia_vertical_[a-z_]+" \
                "$vd" --include="*.py" 2>/dev/null \
              | grep -vE "(__pycache__|/tests/|test_)" \
              | grep -vE "entelecheia_vertical_${vid}|packages\.verticals\.${vid}" || true)
    if [ -n "$others" ]; then
      found+="$others"$'\n'
    fi
  done
  if [ -n "$found" ]; then
    printf "  %s a vertical imports another vertical — FORBIDDEN\n" "$(red "✗")"
    printf "%s" "$found" | sed 's/^/    /'
    count=$(printf "%s" "$found" | grep -c '' || true)
    VIOLATIONS=$((VIOLATIONS + count))
  else
    printf "  %s verticals do not import each other\n" "$(green "✓")"
  fi
else
  printf "  %s no verticals yet (Day 0)\n" "$(yellow "·")"
fi

# Verticals also must not import platform-shell internals (only its public API)
if compgen -G "packages/verticals/*" > /dev/null 2>&1; then
  found=$(grep -rEn \
            "from[[:space:]]+entelecheia_platform_shell\.[a-z_]+\.[a-z_]+|from[[:space:]]+packages\.platform_shell\.[a-z_]+\._" \
            packages/verticals/* --include="*.py" 2>/dev/null \
          | grep -vE "(__pycache__|/tests/|test_)") || true
  if [ -n "$found" ]; then
    printf "  %s vertical imports platform-shell internals (use the public surface)\n" "$(red "✗")"
    printf "%s\n" "$found" | sed 's/^/    /'
    count=$(printf "%s\n" "$found" | wc -l | tr -d ' ')
    VIOLATIONS=$((VIOLATIONS + count))
  else
    printf "  %s verticals use only platform-shell's public surface\n" "$(green "✓")"
  fi
fi
printf "\n"

# ─── Red line #4: features must go through studio-client ──────────────
printf "── Red line #4: platform-features and apps/api use studio-client ──\n"
# Forbidden: hardcoded studio URLs / direct httpx clients pointing at studio
# in packages/platform-features/* or apps/api/* (anywhere outside studio-client).
scan_paths \
  "raw studio URL string literals (use StudioClient Protocol)" \
  "['\"]https?://[^'\"]*studio[^'\"]*['\"]" \
  "packages/platform-features apps" \
  "*.py" \
  "studio_client"
scan_paths \
  "raw studio URL string literals (Vue / TS)" \
  "['\"]https?://[^'\"]*studio[^'\"]*['\"]" \
  "packages/platform-features apps/frontend/src" \
  "*.ts" \
  "studio_client|studio-client"
printf "\n"

# ─── Red line #5: no 'roundtable' literal anywhere ────────────────────
printf "── Red line #5: 'roundtable' is deprecated; use 'agora' ──────────\n"
scan_paths \
  "deprecated 'roundtable' / 'Roundtable' as string literal" \
  "['\"](roundtable|Roundtable)['\"]" \
  "packages apps" \
  "*.py"
scan_paths \
  "deprecated 'roundtable' as string literal in TS" \
  "['\"](roundtable|Roundtable)['\"]" \
  "packages apps" \
  "*.ts"
scan_paths \
  "deprecated 'roundtable' as string literal in Vue" \
  "['\"](roundtable|Roundtable)['\"]" \
  "packages apps" \
  "*.vue"
# Also reject directory or file naming
if compgen -G "packages/**/roundtable*" > /dev/null 2>&1 \
   || compgen -G "apps/**/roundtable*" > /dev/null 2>&1; then
  printf "  %s a path uses 'roundtable' — rename to 'agora'\n" "$(red "✗")"
  find packages apps -iname "*roundtable*" 2>/dev/null | sed 's/^/    /'
  VIOLATIONS=$((VIOLATIONS + 1))
else
  printf "  %s no path component uses 'roundtable'\n" "$(green "✓")"
fi
printf "\n"

# ─── Wrap up ──────────────────────────────────────────────────────────
printf "══════════════════════════════════════════════════════════════════\n"
if [ "$VIOLATIONS" -eq 0 ]; then
  printf " %s Product pure — zero red-line violations.\n" "$(green "✓")"
  printf "══════════════════════════════════════════════════════════════════\n\n"
  exit 0
else
  printf " %s %d red-line violations found.\n" "$(red "✗")" "$VIOLATIONS"
  printf "══════════════════════════════════════════════════════════════════\n\n"
  printf "Read CONTRIBUTING.md §\"The red lines\" for what each rule means.\n\n"
  exit 1
fi
