#!/usr/bin/env bash
set -euo pipefail

SIMBLOCK_DIR="${SIMBLOCK_DIR:-$HOME/jikken/simblock}"
OUTPUT_DIR="${1:-$SIMBLOCK_DIR/simulator/src/dist/output}"
BLOCK_LIST="$OUTPUT_DIR/blockList.txt"
OUTPUT_JSON="$OUTPUT_DIR/output.json"

BLOCK_SIZE="${BLOCK_SIZE:-1000000}"
AVG_TX_SIZE="${AVG_TX_SIZE:-250}"
INTERVAL_SEC="${INTERVAL_SEC:-10}"

if [ ! -f "$BLOCK_LIST" ]; then
  echo "[ERROR] blockList.txt not found: $BLOCK_LIST"
  echo ""
  echo "Usage:"
  echo "  ./calc_simblock_metrics.sh [output_dir]"
  echo ""
  echo "Example:"
  echo "  ./calc_simblock_metrics.sh ~/jikken/simblock/simulator/src/dist/output"
  echo ""
  echo "Optional environment variables:"
  echo "  BLOCK_SIZE=1000000"
  echo "  AVG_TX_SIZE=250"
  echo "  INTERVAL_SEC=10"
  echo "  SIMBLOCK_DIR=$HOME/jikken/simblock"
  exit 1
fi

ONCHAIN=$(grep -c "OnChain" "$BLOCK_LIST" || true)
ORPHAN=$(grep -c "Orphan" "$BLOCK_LIST" || true)
ALL=$(wc -l < "$BLOCK_LIST" | tr -d ' ')

if [ "$ALL" -eq 0 ]; then
  echo "[ERROR] blockList.txt is empty: $BLOCK_LIST"
  exit 1
fi

if [ "$AVG_TX_SIZE" -le 0 ]; then
  echo "[ERROR] AVG_TX_SIZE must be greater than 0"
  exit 1
fi

if [ "$INTERVAL_SEC" -le 0 ]; then
  echo "[ERROR] INTERVAL_SEC must be greater than 0"
  exit 1
fi

TX_PER_BLOCK=$((BLOCK_SIZE / AVG_TX_SIZE))
SIM_TIME_SEC=$((ONCHAIN * INTERVAL_SEC))

FORK_RATE=$(awk -v o="$ORPHAN" -v a="$ALL" 'BEGIN { printf("%.6f", o / a) }')
FORK_RATE_PERCENT=$(awk -v o="$ORPHAN" -v a="$ALL" 'BEGIN { printf("%.2f", (o / a) * 100) }')

EFFECTIVE_TPS=$(awk -v b="$ONCHAIN" -v tx="$TX_PER_BLOCK" -v t="$SIM_TIME_SEC" \
  'BEGIN {
    if (t == 0) {
      printf("0.00")
    } else {
      printf("%.2f", (b * tx) / t)
    }
  }')

TPS_FROM_INTERVAL=$(awk -v tx="$TX_PER_BLOCK" -v sec="$INTERVAL_SEC" \
  'BEGIN { printf("%.2f", tx / sec) }')

GENERATED_BLOCK_TPS=$(awk -v b="$ALL" -v tx="$TX_PER_BLOCK" -v t="$SIM_TIME_SEC" \
  'BEGIN {
    if (t == 0) {
      printf("0.00")
    } else {
      printf("%.2f", (b * tx) / t)
    }
  }')

PROPAGATION_RESULT=""
if [ -f "$OUTPUT_JSON" ]; then
  PROPAGATION_RESULT=$(python3 - "$OUTPUT_JSON" "$OUTPUT_DIR" <<'PY'
import json
import math
import statistics
import sys
from pathlib import Path
from collections import defaultdict

def percentile_nearest_rank(values, percent):
    xs = sorted(values)
    if not xs:
        return 0.0
    k = math.ceil((percent / 100.0) * len(xs)) - 1
    k = max(0, min(k, len(xs) - 1))
    return xs[k]

output_json = Path(sys.argv[1])
output_dir = Path(sys.argv[2])
csv_path = output_dir / "propagation_metrics_from_add_block.csv"

with output_json.open("r", encoding="utf-8") as f:
    data = json.load(f)

node_ids = set()
block_node_time = defaultdict(dict)

for event in data:
    if not isinstance(event, dict):
        continue

    kind = event.get("kind")
    content = event.get("content", {})

    if kind == "add-node":
      node_id = content.get("node-id")
      if node_id is not None:
          node_ids.add(int(node_id))

    elif kind == "add-block":
        block_id = content.get("block-id")
        node_id = content.get("node-id")
        timestamp = content.get("timestamp")

        if block_id is None or node_id is None or timestamp is None:
            continue

        block_id = int(block_id)
        node_id = int(node_id)
        timestamp = float(timestamp)

        if node_id not in block_node_time[block_id]:
            block_node_time[block_id][node_id] = timestamp
        else:
            block_node_time[block_id][node_id] = min(
                block_node_time[block_id][node_id],
                timestamp
            )

rows = []

for block_id in sorted(block_node_time.keys()):
    arrivals = block_node_time[block_id]

    if len(arrivals) < 2:
        continue

    generation_time = min(arrivals.values())
    propagation_times = [
        t - generation_time
        for t in arrivals.values()
        if t >= generation_time
    ]

    if not propagation_times:
        continue

    reached_nodes = len(propagation_times)
    reached_rate = (reached_nodes / len(node_ids) * 100.0) if node_ids else 0.0

    rows.append({
        "block_id": block_id,
        "generation_time": generation_time,
        "reached_nodes": reached_nodes,
        "reached_rate": reached_rate,
        "avg_time": statistics.mean(propagation_times),
        "p90_time": percentile_nearest_rank(propagation_times, 90),
        "p95_time": percentile_nearest_rank(propagation_times, 95),
        "max_time": max(propagation_times),
    })

if not rows:
    print("propagation_available=0")
    print("propagation_error=no_add_block_data")
    sys.exit(0)

with csv_path.open("w", encoding="utf-8") as f:
    f.write(
        "block_id,generation_time,reached_nodes,reached_rate,"
        "avg_time,p90_time,p95_time,max_time\n"
    )
    for row in rows:
        f.write(
            f"{row['block_id']},"
            f"{row['generation_time']:.0f},"
            f"{row['reached_nodes']},"
            f"{row['reached_rate']:.2f},"
            f"{row['avg_time']:.6f},"
            f"{row['p90_time']:.6f},"
            f"{row['p95_time']:.6f},"
            f"{row['max_time']:.6f}\n"
        )

avg_block = statistics.mean(row["avg_time"] for row in rows)
avg_p90 = statistics.mean(row["p90_time"] for row in rows)
avg_p95 = statistics.mean(row["p95_time"] for row in rows)
avg_max = statistics.mean(row["max_time"] for row in rows)

print("propagation_available=1")
print(f"num_nodes={len(node_ids)}")
print(f"parsed_blocks={len(rows)}")
print(f"average_block_propagation_time={avg_block:.6f}")
print(f"average_90pct_node_arrival_time={avg_p90:.6f}")
print(f"average_95pct_node_arrival_time={avg_p95:.6f}")
print(f"average_max_node_arrival_time={avg_max:.6f}")
print(f"propagation_csv={csv_path}")
PY
)
else
  PROPAGATION_RESULT="propagation_available=0
propagation_error=output_json_not_found"
fi

get_prop_value() {
  local key="$1"
  echo "$PROPAGATION_RESULT" | awk -F= -v k="$key" '$1 == k {print $2}'
}

PROPAGATION_AVAILABLE=$(get_prop_value "propagation_available")
PROPAGATION_ERROR=$(get_prop_value "propagation_error")
NUM_NODES=$(get_prop_value "num_nodes")
PARSED_BLOCKS=$(get_prop_value "parsed_blocks")
AVG_BLOCK_PROP_TIME=$(get_prop_value "average_block_propagation_time")
AVG_90_NODE_TIME=$(get_prop_value "average_90pct_node_arrival_time")
AVG_95_NODE_TIME=$(get_prop_value "average_95pct_node_arrival_time")
AVG_MAX_NODE_TIME=$(get_prop_value "average_max_node_arrival_time")
PROPAGATION_CSV=$(get_prop_value "propagation_csv")

echo "========================================"
echo "SimBlock Metrics"
echo "========================================"
echo "output_dir              : $OUTPUT_DIR"
echo "block_list              : $BLOCK_LIST"
echo "output_json             : $OUTPUT_JSON"
echo ""
echo "[Block counts]"
echo "onchain_blocks          : $ONCHAIN"
echo "orphan_blocks           : $ORPHAN"
echo "all_generated_blocks    : $ALL"
echo "fork_count              : $ORPHAN"
echo ""
echo "[Fork / orphan rate]"
echo "fork_rate               : $FORK_RATE"
echo "fork_rate_percent       : ${FORK_RATE_PERCENT}%"
echo "orphan_rate             : $FORK_RATE"
echo "orphan_rate_percent     : ${FORK_RATE_PERCENT}%"
echo ""
echo "[TPS estimation settings]"
echo "block_size_bytes        : $BLOCK_SIZE"
echo "avg_tx_size_bytes       : $AVG_TX_SIZE"
echo "tx_per_block            : $TX_PER_BLOCK"
echo "interval_sec            : $INTERVAL_SEC"
echo "estimated_sim_time_sec  : $SIM_TIME_SEC"
echo ""
echo "[TPS]"
echo "effective_tps_onchain   : $EFFECTIVE_TPS"
echo "tps_from_interval       : $TPS_FROM_INTERVAL"
echo "generated_block_tps     : $GENERATED_BLOCK_TPS"
echo ""

echo "[Block propagation]"
if [ "$PROPAGATION_AVAILABLE" = "1" ]; then
  echo "num_nodes                         : $NUM_NODES"
  echo "parsed_blocks                     : $PARSED_BLOCKS"
  echo "average_block_propagation_time    : $AVG_BLOCK_PROP_TIME"
  echo "average_90pct_node_arrival_time   : $AVG_90_NODE_TIME"
  echo "average_95pct_node_arrival_time   : $AVG_95_NODE_TIME"
  echo "average_max_node_arrival_time     : $AVG_MAX_NODE_TIME"
  echo "propagation_csv                   : $PROPAGATION_CSV"
else
  echo "propagation_available             : 0"
  echo "propagation_error                 : ${PROPAGATION_ERROR:-unknown}"
fi
echo ""

echo "Notes:"
echo "  effective_tps_onchain uses only OnChain blocks."
echo "  generated_block_tps includes Orphan blocks and is not final-chain TPS."
echo "  propagation times are calculated from add-block timestamps in output.json."
echo "  time unit follows SimBlock timestamp unit, usually milliseconds."
echo "========================================"