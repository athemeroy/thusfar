#!/bin/sh
# Run one book with a given model for every text-generating step (the judge still judges).
# usage: scripts/run_with.sh MODEL KEY_NAME data/books/<id> [extra pipeline args]
M=$1; K=$2; shift 2
export LLM_KEY_NAME="$K" LOCAL_MODEL="$M" EXTRACT_MODEL="$M" RECAP_MODEL="$M" QA_MODEL="$M"
exec "$(dirname "$0")/bg.sh" start "$@"
