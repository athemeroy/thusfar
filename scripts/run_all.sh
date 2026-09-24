#!/bin/sh
# Process a list of books one after another with one model. Resumable: a book that is already
# done is replayed from cache in seconds, so re-running the chain is safe.
#   scripts/run_all.sh MODEL KEY_NAME BOOK_DIR...
set -e
cd "$(dirname "$0")/.."
M=$1; K=$2; shift 2
export LLM_KEY_NAME="$K" LOCAL_MODEL="$M" EXTRACT_MODEL="$M" RECAP_MODEL="$M" QA_MODEL="$M" CLASSIFY_MODEL="$M"
export JEV_ROUTE="${JEV_ROUTE:-free}" JEV_CONCURRENCY="${JEV_CONCURRENCY:-8}" LLM_TIMEOUT="${LLM_TIMEOUT:-180}" LLM_RETRIES="${LLM_RETRIES:-2}"
failed=0
for d in "$@"; do
  echo "=== $(date +%H:%M:%S) $d"
  if ! python3 -u -m pipeline.run "$d" --concurrency "${CONCURRENCY:-16}"; then
    echo "!! $d 处理失败，继续检查其余书籍"
    failed=$((failed + 1))
  fi
done
if [ "$failed" -gt 0 ]; then
  echo "=== $(date +%H:%M:%S) 链结束，$failed 本失败"
  exit 1
fi
echo "=== $(date +%H:%M:%S) all done"
