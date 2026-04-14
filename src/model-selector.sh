#!/usr/bin/env bash
# ModelSelector: Claude Code Intelligent Model Router
# Zero-LLM-token scoring engine using regex/keyword matching.
# Classifies prompts into 5 tiers: T0(Ollama) T1(Codex) T2(Haiku) T3(Sonnet) T4(Opus)
#
# Usage:
#   echo "your prompt" | model-selector.sh           # outputs tier (T0-T4)
#   echo "your prompt" | model-selector.sh --verbose  # outputs tier + reasoning
#   echo "your prompt" | model-selector.sh --json     # outputs JSON

# Note: do NOT use set -e here. Arithmetic comparisons like (( x < 0 ))
# return exit 1 when false, and grep returns 1 on no match. Both are
# expected behavior in a scoring engine, not errors.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=false
JSON_OUTPUT=false

for arg in "$@"; do
    case "$arg" in
        --verbose) VERBOSE=true ;;
        --json) JSON_OUTPUT=true ;;
    esac
done

# Read prompt from stdin
PROMPT=$(cat)
if [[ -z "$PROMPT" ]]; then
    echo "T4" # default to Opus if no prompt
    exit 0
fi

PROMPT_LEN=${#PROMPT}
reasons=()

# ============================================================
# P2: PREPROCESSING
# Strip code fences and inline code before scoring
# ============================================================

clean_prompt=$(echo "$PROMPT" | sed '/^```/,/^```/d')
clean_prompt=$(echo "$clean_prompt" | sed 's/`[^`]*`//g')
prompt_lower=$(echo "$clean_prompt" | tr '[:upper:]' '[:lower:]')

# Negation proximity: suppress trigger words near negation
# BSD sed (macOS) doesn't support \b, use space/line-start anchors
prompt_lower=$(echo "$prompt_lower" | sed -E "s/(^| )(don.t|do not|no|not|avoid|without|skip) [a-z]+//g")

# ============================================================
# P0: PRIVACY OVERRIDE (runs on raw prompt, highest priority)
# ============================================================

PRIVACY_PATTERN='(password|passwd|api[_-]?key|secret[_-]?key|private[_-]?key|bearer |token *= *|ssn|credit[_-]?card)'

if echo "$PROMPT" | grep -qiE "$PRIVACY_PATTERN"; then
    reasons+=("privacy: sensitive data detected, forcing local execution")
    tier=0
    tier_name="T0"
    model_name="ollama:gemma4:31b"
    route_reason="privacy_override"

    if $JSON_OUTPUT; then
        printf '{"tier":%d,"tier_name":"%s","model":"%s","reason":"%s","tools":"none","capability":"n/a","peak":%s}\n' \
            "$tier" "$tier_name" "$model_name" "$route_reason" "false"
    elif $VERBOSE; then
        echo "━━━ ModelSelector ━━━"
        echo "  Route: $tier_name ($model_name)"
        echo "  Reason: Privacy override - sensitive data detected"
    else
        echo "$tier_name"
    fi
    exit 0
fi

# ============================================================
# P1: MANUAL OVERRIDE
# ============================================================

MODEL_OVERRIDE_PATTERN='(use|switch to|route to|prefer) +(opus|sonnet|haiku|codex|gpt|ollama|local|gemma)'

if echo "$prompt_lower" | grep -qiE "$MODEL_OVERRIDE_PATTERN"; then
    target=$(echo "$prompt_lower" | grep -oiE "$MODEL_OVERRIDE_PATTERN" | head -1 | awk '{print $NF}')
    case "$target" in
        opus)           tier=4; model_name="claude:opus-4.6-1m" ;;
        sonnet)         tier=3; model_name="claude:sonnet-4.6" ;;
        haiku)          tier=2; model_name="claude:haiku-4.5" ;;
        codex|gpt)      tier=1; model_name="codex:gpt-5.4" ;;
        ollama|local|gemma) tier=0; model_name="ollama:gemma4:31b" ;;
        *)              tier=4; model_name="claude:opus-4.6-1m" ;;
    esac
    tier_name="T${tier}"
    route_reason="manual_override:${target}"

    if $JSON_OUTPUT; then
        printf '{"tier":%d,"tier_name":"%s","model":"%s","reason":"%s","tools":"n/a","capability":"n/a","peak":%s}\n' \
            "$tier" "$tier_name" "$model_name" "$route_reason" "false"
    elif $VERBOSE; then
        echo "━━━ ModelSelector ━━━"
        echo "  Route: $tier_name ($model_name)"
        echo "  Reason: Manual override - user requested $target"
    else
        echo "$tier_name"
    fi
    exit 0
fi

# ============================================================
# P3: TOOL DEPENDENCY GATE
# ============================================================

TOOL_YES='(edit |fix |refactor |rewrite |implement |create file|delete file|rename |update file|modify |patch |write to|add to file|remove from file)'
TOOL_YES_ZH='(修改|修复|重构|改写|实现|创建文件|删除文件|重命名|更新文件|编辑|写入|添加到|移除)'
# File extensions must appear as actual filenames (word.ext), not standalone words
TOOL_YES_FILE='(\w+\.[tj]sx?|\w+\.(py|rs|go|c|cpp|h|css|html|yaml|yml|json|toml|md|sh|sql)|(src|lib|app|pages|components|hooks|utils|tests?)/)'
TOOL_YES_CMD='(run test|grep for|find file|read file|check lint|execute |build |deploy |commit |branch |create pr|git (add|commit|push|pull|rebase|merge|checkout|branch|log|diff|status))'
TOOL_YES_CMD_ZH='(运行测试|查找文件|读取文件|检查|执行|构建|部署|提交|分支|跑测试|看看文件|打开文件)'

TOOL_NO='(explain|what is|how (does|do|to)|why does|difference between|pros and cons|translate|summarize|brainstorm|in general|theoretically|write a plan|propose|teach me|help me understand|compare)'
TOOL_NO_ZH='(解释|什么是|怎么|为什么|区别|优缺点|翻译|总结|头脑风暴|理论上|写个计划|建议|帮我理解|对比|比较|概念|原理)'

classify_tools() {
    local p="$1"
    # Explicit no-tool signals (EN + ZH)
    if (echo "$p" | grep -qiE "$TOOL_NO" || echo "$p" | grep -qE "$TOOL_NO_ZH") && \
       ! echo "$p" | grep -qiE "$TOOL_YES" && ! echo "$p" | grep -qE "$TOOL_YES_ZH"; then
        echo "NONE"
        return
    fi
    # Explicit tool signals (EN + ZH)
    if echo "$p" | grep -qiE "$TOOL_YES|$TOOL_YES_FILE|$TOOL_YES_CMD" || \
       echo "$p" | grep -qE "$TOOL_YES_ZH|$TOOL_YES_CMD_ZH"; then
        echo "REQUIRED"
        return
    fi
    # Ambiguous: use environment (are we in a git repo?)
    if git rev-parse --git-dir >/dev/null 2>&1; then
        echo "REQUIRED"
    else
        echo "NONE"
    fi
}

tools_needed=$(classify_tools "$prompt_lower")
reasons+=("tools: $tools_needed")

# ============================================================
# P4: CAPABILITY SCORING
# ============================================================

score=0

# --- D1: Cognitive Complexity (cap: 35) ---
d1=0

# HIGH complexity (+8 each, EN)
for pat in \
    'architect' 'system design' 'refactor' 'migrat' \
    'optimize' 'debug' 'implement' \
    'trade[_-]?off' 'reverse engineer' 'redesign' 'design.*system' 'algorithm'; do
    if echo "$prompt_lower" | grep -qiE "$pat"; then
        d1=$(( d1 + 8 ))
    fi
done
# HIGH complexity (+8 each, ZH)
for pat in \
    '架构' '系统设计' '重构' '迁移' \
    '优化' '调试' '实现' '设计.*系统' '算法' \
    '权衡' '逆向' '重新设计'; do
    if echo "$PROMPT" | grep -qE "$pat"; then
        d1=$(( d1 + 8 ))
    fi
done

# MULTI-STEP / compound signals (+5 each, EN)
for pat in \
    'then.*after' 'step [0-9]' 'first.*then.*finally' \
    'pipeline' 'orchestrat' 'end[_-]to[_-]end' 'full[_-]stack' \
    'across.*module' 'across.*file' 'multiple.*component' \
    'from scratch' 'entire.*system'; do
    if echo "$prompt_lower" | grep -qiE "$pat"; then
        d1=$(( d1 + 5 ))
    fi
done
# MULTI-STEP (+5 each, ZH)
for pat in \
    '然后.*接着' '第[0-9]步' '首先.*然后.*最后' \
    '流水线' '编排' '端到端' '全栈' \
    '跨.*模块' '跨.*文件' '多个.*组件' \
    '从零' '从头' '整个.*系统'; do
    if echo "$PROMPT" | grep -qE "$pat"; then
        d1=$(( d1 + 5 ))
    fi
done

# LOW complexity (-5 each, EN)
for pat in \
    'how to' 'syntax' 'boilerplate' 'hello world' \
    'simple' 'basic' 'beginner' 'tutorial' 'rename' 'reformat'; do
    if echo "$prompt_lower" | grep -qiE "$pat"; then
        d1=$(( d1 - 5 ))
    fi
done
# LOW complexity (-5 each, ZH)
for pat in '怎么用' '语法' '模板' '简单' '基础' '入门' '教程' '重命名' '格式化'; do
    if echo "$PROMPT" | grep -qE "$pat"; then
        d1=$(( d1 - 5 ))
    fi
done

(( d1 < 0 )) && d1=0
(( d1 > 35 )) && d1=35
score=$(( score + d1 ))
reasons+=("D1_complexity: $d1/35")

# --- D2: Domain Expertise & Risk (cap: 30) ---
d2=0

# EXPERT domain (+10 each, EN + ZH)
EXPERT_DOMAIN='(cryptograph|zero[_-]?knowledge|consensus|distributed transaction|memory safety|undefined behavior|compiler|JIT|SIMD|CUDA|formal verification|type theory)'
EXPERT_DOMAIN_ZH='(密码学|零知识|共识算法|分布式事务|内存安全|未定义行为|编译器|形式化验证|类型论)'
if echo "$prompt_lower" | grep -qiE "$EXPERT_DOMAIN" || echo "$PROMPT" | grep -qE "$EXPERT_DOMAIN_ZH"; then
    d2=$(( d2 + 10 ))
fi

# HIGH RISK (+8 each, EN)
HIGH_RISK='(auth|authorization|billing|payment|schema|migration|public api|breaking change|prod|production|security|vulnerability|exploit|xss|csrf|injection)'
count=$(echo "$prompt_lower" | grep -oiE "$HIGH_RISK" | sort -u | wc -l | tr -d ' ')
d2=$(( d2 + count * 8 ))
# HIGH RISK (ZH)
HIGH_RISK_ZH='(认证|授权|计费|支付|数据库模式|迁移|公共接口|破坏性变更|生产环境|线上|安全|漏洞|攻击)'
count_zh=$(echo "$PROMPT" | grep -oE "$HIGH_RISK_ZH" | sort -u | wc -l | tr -d ' ')
d2=$(( d2 + count_zh * 8 ))

# SYSTEMS (+5 each, EN + ZH)
SYSTEMS='(syscall|mmap|socket|epoll|mutex|semaphore|atomic|cache coherenc|POSIX|pthread)'
SYSTEMS_ZH='(系统调用|套接字|互斥锁|信号量|原子操作|缓存一致性)'
if echo "$prompt_lower" | grep -qiE "$SYSTEMS" || echo "$PROMPT" | grep -qE "$SYSTEMS_ZH"; then
    d2=$(( d2 + 5 ))
fi

# GENERIC (-5 each)
GENERIC='(CRUD|REST API|todo app|hello world|simple script)'
if echo "$prompt_lower" | grep -qiE "$GENERIC"; then
    d2=$(( d2 - 5 ))
fi

(( d2 < 0 )) && d2=0
(( d2 > 30 )) && d2=30
score=$(( score + d2 ))
reasons+=("D2_domain_risk: $d2/30")

# --- D3: Scope & Volume (cap: 20) ---
d3=0

# Word count as scope proxy (Chinese: use char count / 2 as proxy for word count)
local_wc=$(echo "$clean_prompt" | wc -w | tr -d ' ')
local_cc=${#clean_prompt}
# For Chinese text (few spaces), use character count / 2 as word equivalent
if (( local_wc < 5 && local_cc > 10 )); then
    local_wc=$(( local_cc / 2 ))
fi
if (( local_wc > 50 )); then d3=$(( d3 + 10 ))
elif (( local_wc > 20 )); then d3=$(( d3 + 5 ))
elif (( local_wc < 8 )); then d3=$(( d3 - 3 ))
fi

# Prompt length scoring (use raw PROMPT length, not clean_prompt)
if (( PROMPT_LEN > 4000 )); then d3=$(( d3 + 15 ))
elif (( PROMPT_LEN > 1500 )); then d3=$(( d3 + 8 ))
elif (( PROMPT_LEN < 100 )); then d3=$(( d3 - 5 ))
fi

# Scope keywords
BROAD_SCOPE='(everywhere|across the project|all files|entire|global|multiple files|whole codebase|full implementation|comprehensive|exhaustive)'
NARROW_SCOPE='(one[_-]?liner|quick fix|snippet|just the|brief|short|single file|this function)'

if echo "$prompt_lower" | grep -qiE "$BROAD_SCOPE"; then d3=$(( d3 + 8 )); fi
if echo "$prompt_lower" | grep -qiE "$NARROW_SCOPE"; then d3=$(( d3 - 5 )); fi

(( d3 < 0 )) && d3=0
(( d3 > 20 )) && d3=20
score=$(( score + d3 ))
reasons+=("D3_scope: $d3/20")

# --- D4: Intent Modifiers (cap: 15) ---

# Word count floor (use local_wc which handles Chinese)
min_score=0
if (( local_wc > 20 )); then min_score=15
fi

# Educational dampener (EN + ZH)
EDUCATIONAL='(explain|teach|what is|for learning|toy example|walk me through|help me understand)'
EDUCATIONAL_ZH='(解释|教我|什么是|学习|帮我理解|讲讲|说说|介绍)'
if echo "$prompt_lower" | grep -qiE "$EDUCATIONAL" || echo "$PROMPT" | grep -qE "$EDUCATIONAL_ZH"; then
    score=$(( score * 80 / 100 ))
    reasons+=("D4_dampener: educational -20%")
fi

# Deterministic transform dampener (EN + ZH)
TRANSFORM='(convert|translate|transpile|reformat|replace.*with|extract|summarize)'
TRANSFORM_ZH='(转换|翻译|格式化|替换|提取|总结|概括)'
if echo "$prompt_lower" | grep -qiE "$TRANSFORM" || echo "$PROMPT" | grep -qE "$TRANSFORM_ZH"; then
    score=$(( score * 80 / 100 ))
    reasons+=("D4_dampener: transform -20%")
fi

# Urgency down
# Urgency down (EN + ZH)
URGENCY_DOWN='(quick|fast|brief|draft|placeholder|stub|skeleton|boilerplate|scaffold|good enough|quick and dirty)'
URGENCY_DOWN_ZH='(快速|简单|草稿|占位|脚手架|差不多就行|凑合)'
if echo "$prompt_lower" | grep -qiE "$URGENCY_DOWN" || echo "$PROMPT" | grep -qE "$URGENCY_DOWN_ZH"; then
    score=$(( score * 85 / 100 ))
    reasons+=("D4_dampener: urgency_down -15%")
fi

# Urgency up (EN + ZH)
URGENCY_UP='(production[_-]?ready|enterprise|robust|thorough|careful|critical|mission[_-]?critical)'
URGENCY_UP_ZH='(生产级|企业级|健壮|彻底|仔细|关键|不能出错|严格)'
if echo "$prompt_lower" | grep -qiE "$URGENCY_UP" || echo "$PROMPT" | grep -qE "$URGENCY_UP_ZH"; then
    score=$(( score * 115 / 100 ))
    reasons+=("D4_boost: urgency_up +15%")
fi

# Apply word count floor after dampeners
if (( score < min_score )); then
    score=$min_score
    reasons+=("D4_floor: word_count=$local_wc -> min_score=$min_score")
fi

reasons+=("score: $score/100")

# --- Classify capability ---
# Thresholds calibrated for real prompts:
# Single-keyword short prompts score ~8-16, compound ~30-60
if (( score >= 40 )); then
    capability="HIGH"
elif (( score >= 15 )); then
    capability="MID"
else
    capability="LOW"
fi
reasons+=("capability: $capability")

# ============================================================
# ROUTING TABLE LOOKUP
# ============================================================
#
# | Capability | TOOLS_NONE | TOOLS_REQUIRED |
# |------------|------------|----------------|
# | LOW        | T0         | T2             |
# | MID        | T1         | T3             |
# | HIGH       | T3         | T4             |

case "${capability}_${tools_needed}" in
    LOW_NONE)       tier=0 ;;
    LOW_REQUIRED)   tier=2 ;;
    MID_NONE)       tier=1 ;;
    MID_REQUIRED)   tier=3 ;;
    HIGH_NONE)      tier=3 ;;
    HIGH_REQUIRED)  tier=4 ;;
    *)              tier=3 ;; # safe default
esac
reasons+=("table: ${capability}_${tools_needed} -> T${tier}")

# ============================================================
# P5: POST-ROUTING MODIFIERS
# ============================================================

# Hard floor: expert domain forces min T3
if echo "$prompt_lower" | grep -qiE "$EXPERT_DOMAIN"; then
    if (( tier < 3 )); then
        tier=3
        reasons+=("floor: expert_domain -> min T3")
    fi
fi

# Hard floor: security + production co-occurrence forces T4
sec_prod=false
if echo "$prompt_lower" | grep -qiE '(security|vulnerab)' && \
   echo "$prompt_lower" | grep -qiE '(prod|production|deploy)'; then
    tier=4
    sec_prod=true
    reasons+=("floor: security+production -> T4")
fi

# Hard floor: long input forces min T2 (T0 context too small)
long_input_pre_tier=$tier
long_input_triggered=false
if (( PROMPT_LEN > 6000 )) && (( tier < 2 )); then
    tier=2
    long_input_triggered=true
    reasons+=("floor: long_input -> min T2")
fi

# Correction signal: escalate one tier (P5-only, not in D4 scoring)
CORRECTION='(didn.t work|wrong|still broken|try again|fix the previous|that.s not right|error in your|still not|that.s wrong|no that.s)'
CORRECTION_ZH='(不对|还是不行|还是错|再试|修复上一个|不工作|出错了|有问题|不好使|挂了|坏了)'
correction_fired=false
if echo "$prompt_lower" | grep -qiE "$CORRECTION" || echo "$PROMPT" | grep -qE "$CORRECTION_ZH"; then
    if (( tier < 4 )); then
        tier=$(( tier + 1 ))
        correction_fired=true
        reasons+=("escalation: correction_signal -> +1 tier")
    fi
fi

# Peak hour: EST 9am-1pm downshift one tier, respect all hard floors
HOUR=$(TZ=America/New_York date +%H)
IS_PEAK=false
if (( HOUR >= 9 && HOUR <= 12 )); then
    IS_PEAK=true
fi

if $IS_PEAK && (( tier > 0 )); then
    min_floor=0
    echo "$prompt_lower" | grep -qiE "$EXPERT_DOMAIN" && min_floor=3
    (( PROMPT_LEN > 6000 )) && (( min_floor < 2 )) && min_floor=2
    $sec_prod && min_floor=4

    new_tier=$(( tier - 1 ))
    (( new_tier < min_floor )) && new_tier=$min_floor
    if (( new_tier != tier )); then
        reasons+=("peak: EST morning -> T${tier} downshifted to T${new_tier}")
        tier=$new_tier
    fi
fi

# ============================================================
# P6: RTK INTEGRATION (optional, requires RTK history.db)
# Reads pre-computed stats from rtk-stats.json to adjust routing.
# ============================================================

RTK_STATS="${HOME}/.config/model-selector/rtk-stats.json"
if [[ -f "$RTK_STATS" ]]; then
    # Parse stats via python3 (available on macOS, used elsewhere in this script)
    rtk_data=$(python3 -c "
import json, sys
try:
    d = json.load(open('$RTK_STATS'))
    if not d.get('rtk_active', False):
        sys.exit(0)
    print(int(d.get('avg_savings_pct', 0)),
          int(float(d.get('tee_recovery_rate_pct', 0))),
          int(d.get('total_records_7d', 0)))
except:
    pass
" 2>/dev/null)

    if [[ -n "$rtk_data" ]]; then
        read -r rtk_savings rtk_tee_rate rtk_records <<< "$rtk_data"

        # Quality gate: high tee recovery rate means RTK is losing info
        # Force min T2 so the model is capable enough to handle incomplete data
        if (( rtk_tee_rate > 5 )) && (( tier < 2 )); then
            tier=2
            reasons+=("rtk: tee_recovery ${rtk_tee_rate}% -> min T2")
        fi

        # Compression bonus: if RTK is saving >60% of tool output tokens
        # and has sufficient history, relax the long_input floor.
        # RTK compresses tool outputs, so models with smaller context windows
        # can handle longer sessions than raw prompt length suggests.
        if (( rtk_savings > 60 )) && (( rtk_records > 50 )); then
            if $long_input_triggered && (( PROMPT_LEN < 15000 )); then
                tier=$long_input_pre_tier
                reasons+=("rtk: ${rtk_savings}% compression relaxes long_input -> T${tier}")
            fi
            $VERBOSE && reasons+=("rtk: active (${rtk_savings}% avg savings, ${rtk_records} records)")
        fi
    fi
fi

# ============================================================
# OUTPUT
# ============================================================

tier_name="T${tier}"
case $tier in
    0) model_name="ollama:gemma4:31b" ;;
    1) model_name="codex:gpt-5.4" ;;
    2) model_name="claude:haiku-4.5" ;;
    3) model_name="claude:sonnet-4.6" ;;
    4) model_name="claude:opus-4.6-1m" ;;
esac

if $JSON_OUTPUT; then
    reasons_json=$(printf '%s\n' "${reasons[@]}" | python3 -c "
import sys, json
print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))
" 2>/dev/null || echo '[]')
    printf '{"tier":%d,"tier_name":"%s","model":"%s","tools":"%s","capability":"%s","score":%d,"peak":%s,"correction":%s,"reasons":%s}\n' \
        "$tier" "$tier_name" "$model_name" "$tools_needed" "$capability" "$score" "$IS_PEAK" "$correction_fired" "$reasons_json"
elif $VERBOSE; then
    echo "━━━ ModelSelector ━━━"
    echo "  Route: $tier_name ($model_name)"
    echo "  Score: $score | Capability: $capability | Tools: $tools_needed"
    $IS_PEAK && echo "  Peak: EST morning peak active"
    echo "  Reasons:"
    for r in "${reasons[@]}"; do
        echo "    - $r"
    done
else
    echo "$tier_name"
fi
