#!/bin/sh
# Explicit paid-provider selection. Free-only runs do not use this wrapper.
#   direct  : TypeSafe's own API (needs credits at console.typesafe.ai)
#   vercel  : Vercel AI Gateway, model typesafe-ai/jev, endpoint /v1/evaluate
#             (needs a credit card on file for the Vercel team, then credits)
case "$1" in
  vercel) export JEV_URL=https://ai-gateway.vercel.sh/v1/evaluate JEV_MODEL=typesafe-ai/jev JEV_KEY_NAME=VERCEL_AI_GATEWAY_KEY ;;
  direct|"") export JEV_URL=https://api.typesafe.ai/v1/systemone JEV_MODEL=jev-1.13.0 JEV_KEY_NAME=JEV_API_KEY ;;
  *) echo "usage: $0 [direct|vercel] COMMAND…" >&2; exit 2 ;;
esac
shift 2>/dev/null
for judge_budget in "${JEV_PAID_MAX_CALLS:-0}" "${JEV_PAID_MAX_CHARS:-0}"; do
  case "$judge_budget" in
    *[!0-9]*|'') echo "付费裁判预算必须为正整数；未执行命令。" >&2; exit 2 ;;
  esac
  if ! [ "$judge_budget" -gt 0 ] 2>/dev/null; then
    echo "付费线路需要显式设置正数 JEV_PAID_MAX_CALLS 和 JEV_PAID_MAX_CHARS；未执行命令。" >&2
    exit 2
  fi
done
export JEV_ROUTE=paid
exec "$@"
