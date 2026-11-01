#!/bin/bash
# Runs inside the microVM as the `runner` user.
set -euo pipefail

if [[ ${ENABLE_DOCKER:-0} == 1 ]]; then
  sudo -n sh -c 'dockerd >/tmp/dockerd.log 2>&1 &'
  for _ in $(seq 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
  docker info >/dev/null 2>&1 || { echo "dockerd failed to start:" >&2; sudo -n tail -20 /tmp/dockerd.log >&2; }
fi

jit=$RUNNER_JITCONFIG
unset RUNNER_JITCONFIG
cd /home/runner
exec ./run.sh --jitconfig "$jit"
