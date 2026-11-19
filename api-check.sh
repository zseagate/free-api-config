#!/usr/bin/env bash
#
# api-check.sh — 通用 OpenAI 兼容 API 连通性/可用性检测脚本
#
# 用途: 检测 Numes 免费模型(及任意 OpenAI 兼容 provider)的可用性。
# 自动加载同目录下的 .env (若存在), 因此无需手动指定 Key。
#
# 用法示例:
#   ./api-check.sh                           # 检测 Numes 全部 9 个免费模型
#   ./api-check.sh --model z-ai/glm-5.3:free # 检测指定模型(可多次)
#   ./api-check.sh --watch 60 --parallel --stop-on-ok  # 轮询直到恢复
#   ./api-check.sh --provider deepseek --model deepseek/deepseek-chat
#   ./api-check.sh --base-url https://api.deepseek.com/v1 --key sk-xxx --model deepseek/deepseek-chat
#   ./api-check.sh --list-free
#
# 退出码: 0=全部可用, 1=有模型不可用, 2=无 Key/参数错误
#
set -u

# ---------- 加载 .env (真实 Key 所在, 被 gitignore) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a; . "$SCRIPT_DIR/.env"; set +a
fi

# ---------- 默认值 ----------
BASE_URL="${NUMES_BASE_URL:-https://api.numes.ai/api/v1}"
KEY=""
KEY_FILE=""
TIMEOUT=30
PARALLEL=0
SHOW_PAID=0
WATCH=0
STOP_ON_OK=0
MODELS=()

# ---------- 默认检测的 Numes 免费模型 ----------
DEFAULT_MODELS=(
  "z-ai/glm-5.3-flash:free"
  "z-ai/glm-5.3:free"
  "deepseek/deepseek-v4.1-flash:free"
  "moonshotai/kimi-k3.1-pro:free"
  "nvidia/nemotron-3-ultra-550b-a55b:free"
  "dealignai/glm-5.3-flash-uncensored-fp8:free"
  "dealignai/glm-5.3-uncensored-fp8:free"
  "dealignai/deepseek-v4.1-flash-uncensored-fp8:free"
  "uniboshi/kimi-k3-abliterated-v1:free"
)

AUTH_JSON="$HOME/.local/share/opencode/auth.json"

# ---------- 帮助 ----------
usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  echo
  echo "选项:"
  echo "  --key KEY            指定 API Key(优先级最高)"
  echo "  --key-file FILE      从文件读取 Key(第一行)"
  echo "  --provider NAME      从 OpenCode auth.json 读取该 provider 的 Key (numes|sensenova|deepseek...)"
  echo "  --base-url URL       覆盖 API Base URL (默认 $BASE_URL)"
  echo "  --model ID           指定要检测的模型 ID, 可重复"
  echo "  --all                检测全部免费模型, 并列出 Numes 当前可用模型概况"
  echo "  --timeout N          单请求超时秒数 (默认 $TIMEOUT)"
  echo "  --parallel           并行检测(默认串行)"
  echo "  --watch N            轮询模式: 每 N 秒检测一轮, 直到 Ctrl-C"
  echo "  --stop-on-ok         配合 --watch, 检测到全部可用后自动退出"
  echo "  --list-free          列出已知免费模型后退出"
  echo "  -h, --help           显示本帮助"
  echo
  echo "Key 解析顺序: --key > --key-file > NUMES_API_KEY 环境变量 > .env > auth.json(numes) > ~/.config/numes/key"
}

# ---------- 参数解析 ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --key)        KEY="$2"; shift 2 ;;
    --key-file)   KEY_FILE="$2"; shift 2 ;;
    --provider)   PROVIDER="$2"; shift 2 ;;
    --base-url)   BASE_URL="$2"; shift 2 ;;
    --model)      MODELS+=("$2"); shift 2 ;;
    --all)        SHOW_PAID=1; shift ;;
    --timeout)    TIMEOUT="$2"; shift 2 ;;
    --parallel)   PARALLEL=1; shift ;;
    --watch)      WATCH="$2"; shift 2 ;;
    --stop-on-ok) STOP_ON_OK=1; shift ;;
    --list-free)  printf '%s\n' "${DEFAULT_MODELS[@]}"; exit 0 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

# ---------- 解析 Key ----------
if [ -z "$KEY" ] && [ -n "$KEY_FILE" ]; then
  KEY=$(head -1 "$KEY_FILE" 2>/dev/null | tr -d '[:space:]')
fi
if [ -z "$KEY" ]; then
  KEY="${NUMES_API_KEY:-}"
fi
if [ -z "$KEY" ] && [ -n "${PROVIDER:-}" ]; then
  KEY=$(python3 -c "
import json,os
try:
    d=json.load(open(os.path.expanduser('$AUTH_JSON')))
    print(d.get('$PROVIDER',{}).get('key',''))
except Exception: pass" 2>/dev/null | tr -d '[:space:]')
elif [ -z "$KEY" ] && [ -f "$AUTH_JSON" ]; then
  KEY=$(python3 -c "
import json,os
try:
    d=json.load(open(os.path.expanduser('$AUTH_JSON')))
    print(d.get('numes',{}).get('key',''))
except Exception: pass" 2>/dev/null | tr -d '[:space:]')
fi
if [ -z "$KEY" ] && [ -f "$HOME/.config/numes/key" ]; then
  KEY=$(head -1 "$HOME/.config/numes/key" | tr -d '[:space:]')
fi

if [ -z "$KEY" ]; then
  echo "✗ 未找到 API Key。请复制 .env.example 为 .env 并填入 NUMES_API_KEY, 或用 --key / --key-file / --provider。" >&2
  exit 2
fi

# 检测列表: 若未指定模型, 用默认免费模型
if [ ${#MODELS[@]} -eq 0 ]; then
  MODELS=("${DEFAULT_MODELS[@]}")
fi

# ---------- 单模型检测 ----------
check_one() {
  local model="$1"
  local out code elapsed
  local tmp; tmp=$(mktemp)
  out=$(curl -s -w "\n%{http_code}|%{time_total}" -m "$TIMEOUT" -X POST \
        "$BASE_URL/chat/completions" \
        -H "Authorization: Bearer $KEY" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" \
        2>/dev/null)
  local status time_s body
  status=$(printf '%s' "$out" | tail -1 | cut -d'|' -f1)
  time_s=$(printf '%s' "$out" | tail -1 | cut -d'|' -f2)
  body=$(printf '%s' "$out" | sed '$d')
  rm -f "$tmp"

  local tag color msg
  case "$status" in
    000) tag="TIMEOUT";  color="\033[33m"; msg="无响应(${time_s}s 超时)" ;;
    200)
      if printf '%s' "$body" | grep -q '"choices"'; then
        tag="OK"; color="\033[32m"; msg="可用 (${time_s}s)"
      else
        tag="HANG"; color="\033[33m"; msg="连接建立但无数据(${time_s}s, 容量/挂起)"
      fi ;;
    401|403) tag="BADKEY"; color="\033[31m"; msg="Key 无效或未授权" ;;
    402)     tag="NOCREDIT"; color="\033[31m"; msg="余额不足 (insufficient credits)" ;;
    429)     tag="OVERLOAD"; color="\033[31m"; msg="容量耗尽/限流 (provider capacity exhausted)" ;;
    503)     tag="UNAVAIL"; color="\033[31m"; msg="服务端暂不可用" ;;
    *)       tag="ERR"; color="\033[31m"; msg="HTTP $status" ;;
  esac
  printf "${color}%-9s\033[0m %-55s %s\n" "$tag" "$model" "$msg"
}

echo "==================================================="
echo " API 连通性检测"
echo "   Base URL : $BASE_URL"
echo "   Timeout  : ${TIMEOUT}s"
echo "   Models   : ${#MODELS[@]} 个"
echo "   Time     : $(date '+%Y-%m-%d %H:%M:%S')"
echo "==================================================="

# ---------- 单轮检测 ----------
# 返回 0 = 全部 OK; 返回 1 = 存在不可用模型
run_round() {
  local all="" i t
  if [ "$PARALLEL" = "1" ]; then
    declare -a TMPFILES
    for i in "${!MODELS[@]}"; do
      t=$(mktemp)
      TMPFILES[$i]=$t
      check_one "${MODELS[$i]}" > "$t" 2>&1 &
    done
    wait
    for i in "${!MODELS[@]}"; do
      all+=$(cat "${TMPFILES[$i]}"); all+=$'\n'
      rm -f "${TMPFILES[$i]}"
    done
  else
    for m in "${MODELS[@]}"; do
      all+=$(check_one "$m"); all+=$'\n'
    done
  fi
  printf '%s' "$all"
  if printf '%s' "$all" | grep -qE 'TIMEOUT|HANG|BADKEY|NOCREDIT|OVERLOAD|UNAVAIL| ERR '; then
    return 1
  fi
  return 0
}

# ---------- 执行 ----------
if [ "$WATCH" -gt 0 ]; then
  round=0
  if [ "$STOP_ON_OK" = "1" ]; then
    echo " 轮询模式: 每 ${WATCH}s 一轮, 全部可用后自动退出 (Ctrl-C 强制退出)"
  else
    echo " 轮询模式: 每 ${WATCH}s 一轮, 持续运行直到 Ctrl-C"
  fi
  while :; do
    round=$((round+1))
    echo "-------------------------------------------"
    echo "[$(date '+%H:%M:%S')] 第 ${round} 轮"
    echo "-------------------------------------------"
    if run_round; then
      echo "✓ 本轮全部模型可用!"
      [ "$STOP_ON_OK" = "1" ] && { echo "已自动退出。"; exit 0; }
    fi
    sleep "$WATCH"
  done
else
  run_round
fi

echo "==================================================="
echo " 提示: TIMEOUT/HANG/OVERLOAD 通常为免费档临时繁忙, 稍后再试;"
echo "       NOCREDIT 表示需要给账户充值; BADKEY 请检查 Key。"
echo "==================================================="
exit 0
