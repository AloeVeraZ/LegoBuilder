#!/bin/bash
# Starts Ollama for the step finder with settings that fit a 16 GB Mac, and stops it before
# the Mac runs out of memory. (An 8B vision model, Chrome and a nearly full disk froze this
# MacBook Air until the kernel watchdog restarted it: no free memory and no room to swap.)
#
#   vision/ollama_safe.sh          # leave it running in a terminal; Ctrl-C stops Ollama
#
# Stops Ollama when: less than 3 GB is free on the internal disk (swap cannot grow), macOS
# reports critical memory pressure, or memory that can be handed out stays under 400 MB for
# 3 seconds. Override the model folder with OLLAMA_MODELS.
set -u
export OLLAMA_MODELS="${OLLAMA_MODELS:-/Volumes/NYCFIRST/local-ai/ollama-models}"
export OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-4096}"
export OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_NUM_PARALLEL=1
export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-10m}"

stop_all() {
  kill "$server" 2>/dev/null
  pkill -f 'llama-server' 2>/dev/null
  pkill -f 'ollama runner' 2>/dev/null
}

ollama serve &
server=$!
trap 'stop_all; exit 0' INT TERM

page=$(sysctl -n hw.pagesize)
low=0
while kill -0 "$server" 2>/dev/null; do
  pressure=$(sysctl -n kern.memorystatus_vm_pressure_level)        # 1 normal, 2 warning, 4 critical
  disk_mb=$(df -m / | awk 'NR==2 {print $4}')
  avail_mb=$(vm_stat | awk -v p="$page" '/Pages (free|inactive|speculative|purgeable)/ {gsub("\\.", "", $NF); s += $NF} END {print int(s * p / 1048576)}')
  if [ "$avail_mb" -lt 400 ]; then low=$((low + 1)); else low=0; fi
  if [ "$disk_mb" -lt 3072 ] || [ "$pressure" -ge 4 ] || [ "$low" -ge 3 ]; then
    echo "ollama_safe: stopping Ollama (disk free ${disk_mb} MB, pressure level ${pressure}, memory available ${avail_mb} MB)" >&2
    stop_all
    exit 1
  fi
  sleep 1
done
