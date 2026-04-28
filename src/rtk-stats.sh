#!/usr/bin/env bash
# RTK Stats Bridge: reads RTK history.db and writes pre-computed stats
# to ~/.config/model-selector/rtk-stats.json for ModelSelector P6 consumption.
#
# Usage:
#   rtk-stats.sh                    # refresh stats (silent)
#   rtk-stats.sh --verbose          # show stats to stdout
#   rtk-stats.sh --json             # output raw JSON to stdout
#   rtk-stats.sh --adapt-limits 0   # adjust RTK limits for T0 (aggressive)
#   rtk-stats.sh --adapt-limits 4   # adjust RTK limits for T4 (relaxed)

set -uo pipefail

VERBOSE=false
JSON_STDOUT=false
ADAPT_TIER=""
for arg in "$@"; do
    case "$arg" in
        --verbose) VERBOSE=true ;;
        --json) JSON_STDOUT=true ;;
        --adapt-limits) ADAPT_TIER="next" ;;
        *)
            if [[ "$ADAPT_TIER" == "next" ]]; then
                ADAPT_TIER="$arg"
            fi
            ;;
    esac
done

# ── Adaptive limits mode ──
# Adjusts ~/.config/rtk/config.toml [limits] based on model tier.
# Lower tiers (smaller context) get more aggressive compression.
if [[ -n "$ADAPT_TIER" ]] && [[ "$ADAPT_TIER" != "next" ]]; then
    RTK_CONFIG_DIR="${HOME}/.config/rtk"
    RTK_CONFIG="${RTK_CONFIG_DIR}/config.toml"

    # Define limits per tier
    # T0 (8K):  aggressive - minimize output to fit small context
    # T1 (128K): moderate
    # T2 (200K): standard (RTK defaults)
    # T3 (200K): relaxed
    # T4 (1M):  minimal compression - let model see more
    case "$ADAPT_TIER" in
        0) grep_max=50;  grep_per_file=10; status_max=5;  untracked_max=5;  passthrough=500  ;;
        1) grep_max=100; grep_per_file=15; status_max=10; untracked_max=8;  passthrough=1000 ;;
        2) grep_max=150; grep_per_file=20; status_max=12; untracked_max=10; passthrough=1500 ;;
        3) grep_max=200; grep_per_file=25; status_max=15; untracked_max=10; passthrough=2000 ;;
        4) grep_max=300; grep_per_file=40; status_max=25; untracked_max=15; passthrough=3000 ;;
        *) exit 0 ;; # unknown tier, skip
    esac

    # Only write if RTK config dir exists (RTK is installed)
    if command -v rtk >/dev/null 2>&1; then
        # Read existing config, replace [limits] section, preserve other sections
        if [[ -f "$RTK_CONFIG" ]]; then
            # Remove existing [limits] section and rewrite
            python3 -c "
import sys

config_path = '$RTK_CONFIG'
limits_block = '''[limits]
grep_max_results = $grep_max
grep_max_per_file = $grep_per_file
status_max_files = $status_max
status_max_untracked = $untracked_max
passthrough_max_chars = $passthrough
# Auto-managed by ModelSelector (tier=$ADAPT_TIER)
'''

with open(config_path, 'r') as f:
    content = f.read()

# Remove existing [limits] section
import re
content = re.sub(r'\[limits\].*?(?=\n\[|\Z)', '', content, flags=re.DOTALL)
content = content.rstrip() + '\n\n' + limits_block

with open(config_path, 'w') as f:
    f.write(content)
" 2>/dev/null
        else
            # No config exists, create minimal one with just [limits]
            mkdir -p "$RTK_CONFIG_DIR"
            RTK_TMP=$(mktemp "${RTK_CONFIG}.XXXXXX")
            cat > "$RTK_TMP" <<LIMITS
[limits]
grep_max_results = $grep_max
grep_max_per_file = $grep_per_file
status_max_files = $status_max
status_max_untracked = $untracked_max
passthrough_max_chars = $passthrough
# Auto-managed by ModelSelector (tier=$ADAPT_TIER)
LIMITS
            mv -f "$RTK_TMP" "$RTK_CONFIG"
        fi
        $VERBOSE && echo "RTK limits adjusted for T${ADAPT_TIER}: grep=${grep_max}, status=${status_max}, passthrough=${passthrough}"
    fi
    exit 0
fi

MS_CONFIG_DIR="${HOME}/.config/model-selector"
STATS_FILE="${MS_CONFIG_DIR}/rtk-stats.json"

# Locate RTK history.db
# Priority: $RTK_DB_PATH > ~/Library/Application Support/rtk/history.db > ~/.local/share/rtk/history.db
if [[ -n "${RTK_DB_PATH:-}" ]] && [[ -f "$RTK_DB_PATH" ]]; then
    RTK_DB="$RTK_DB_PATH"
elif [[ -f "${HOME}/Library/Application Support/rtk/history.db" ]]; then
    RTK_DB="${HOME}/Library/Application Support/rtk/history.db"
elif [[ -f "${HOME}/.local/share/rtk/history.db" ]]; then
    RTK_DB="${HOME}/.local/share/rtk/history.db"
else
    # RTK not installed or never run - write empty stats
    mkdir -p "$MS_CONFIG_DIR"
    echo '{"rtk_active":false,"avg_savings_pct":0,"tee_recovery_rate_pct":0,"total_records":0}' > "$STATS_FILE"
    $VERBOSE && echo "RTK history.db not found, wrote empty stats"
    exit 0
fi

# Verify sqlite3 is available
if ! command -v sqlite3 &>/dev/null; then
    $VERBOSE && echo "sqlite3 not found, skipping RTK stats"
    exit 0
fi

# Query RTK history.db for aggregate stats
# All queries in one sqlite3 invocation to minimize overhead
read -r total_records avg_savings_pct avg_input avg_output avg_exec_ms <<< $(
    sqlite3 -separator ' ' "$RTK_DB" <<'SQL' 2>/dev/null
SELECT
    COUNT(*),
    COALESCE(ROUND(AVG(savings_pct), 1), 0),
    COALESCE(ROUND(AVG(input_tokens), 0), 0),
    COALESCE(ROUND(AVG(output_tokens), 0), 0),
    COALESCE(ROUND(AVG(exec_time_ms), 0), 0)
FROM commands
WHERE timestamp > datetime('now', '-7 days');
SQL
)

# Recent stats (last hour) for session-level signals
read -r session_records session_savings session_saved_tokens <<< $(
    sqlite3 -separator ' ' "$RTK_DB" <<'SQL' 2>/dev/null
SELECT
    COUNT(*),
    COALESCE(ROUND(AVG(savings_pct), 1), 0),
    COALESCE(SUM(saved_tokens), 0)
FROM commands
WHERE timestamp > datetime('now', '-1 hour');
SQL
)

# Tee recovery rate: failed-fallback parse_failures / total commands (only counts failures
# that actually lost data; cosmetic parse failures with fallback_succeeded=1 produced
# correct user output via passthrough and are excluded)
read -r total_failures failed_recoveries <<< $(
    sqlite3 -separator ' ' "$RTK_DB" <<'SQL' 2>/dev/null
SELECT
    COUNT(*),
    COALESCE(SUM(CASE WHEN fallback_succeeded = 0 THEN 1 ELSE 0 END), 0)
FROM parse_failures
WHERE timestamp > datetime('now', '-7 days');
SQL
)

# Lifetime totals
read -r lifetime_saved_tokens lifetime_records <<< $(
    sqlite3 -separator ' ' "$RTK_DB" <<'SQL' 2>/dev/null
SELECT COALESCE(SUM(saved_tokens), 0), COUNT(*) FROM commands;
SQL
)

# Calculate tee recovery rate
total_records=${total_records:-0}
total_failures=${total_failures:-0}
failed_recoveries=${failed_recoveries:-0}
if (( total_records > 0 )); then
    tee_recovery_rate=$(python3 -c "print(round($failed_recoveries / ($total_records + $failed_recoveries) * 100, 1))" 2>/dev/null || echo 0)
else
    printf -v tee_recovery_rate 0
fi

# Write stats JSON (atomic: temp file + mv to avoid race with concurrent reads)
mkdir -p "$MS_CONFIG_DIR"
STATS_TMP=$(mktemp "${STATS_FILE}.XXXXXX")
cat > "$STATS_TMP" <<STATS
{
  "rtk_active": true,
  "avg_savings_pct": ${avg_savings_pct:-0},
  "avg_input_tokens": ${avg_input:-0},
  "avg_output_tokens": ${avg_output:-0},
  "avg_exec_ms": ${avg_exec_ms:-0},
  "tee_recovery_rate_pct": ${tee_recovery_rate},
  "total_records_7d": ${total_records:-0},
  "total_failures_7d": ${total_failures:-0},
  "session_records_1h": ${session_records:-0},
  "session_savings_pct": ${session_savings:-0},
  "session_saved_tokens": ${session_saved_tokens:-0},
  "lifetime_saved_tokens": ${lifetime_saved_tokens:-0},
  "lifetime_records": ${lifetime_records:-0},
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
STATS
mv -f "$STATS_TMP" "$STATS_FILE"

if $JSON_STDOUT; then
    cat "$STATS_FILE"
elif $VERBOSE; then
    echo "RTK Stats (7-day window):"
    echo "  DB: $RTK_DB"
    echo "  Records: ${total_records:-0} (lifetime: ${lifetime_records:-0})"
    echo "  Avg savings: ${avg_savings_pct:-0}%"
    echo "  Avg input: ${avg_input:-0} tokens -> output: ${avg_output:-0} tokens"
    echo "  Tee recovery rate: ${tee_recovery_rate}%"
    echo "  Session (1h): ${session_records:-0} commands, ${session_saved_tokens:-0} tokens saved"
    echo "  Lifetime saved: ${lifetime_saved_tokens:-0} tokens"
    echo "  Written to: $STATS_FILE"
fi
