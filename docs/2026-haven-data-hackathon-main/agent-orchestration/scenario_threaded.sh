#!/usr/bin/env bash
# Multi-turn master conversation exercising specialist thread continue / new decisions.
# Deploy first with: python agent-orchestration/deploy.py --specialist-mode threaded
set -e
cd "$(dirname "$0")/.."
A="-u agent-orchestration/ask.py"  # -u: unbuffered, so progress shows up live
OUT=agent-orchestration/runs/threaded_$(date +%Y%m%d_%H%M)
python $A master "Which 5 parks had the most arriving guests over the weekend of 19-21 September 2026?" --thread tdemo --reset --save $OUT/t1
python $A master "Break that down by day for those parks." --thread tdemo --save $OUT/t2
python $A master "Different topic: what is the cancellation rate for the 2026 season so far?" --thread tdemo --save $OUT/t3
python $A master "How does that compare with the 2025 season at the same point last year?" --thread tdemo --save $OUT/t4
python $A --log 30
