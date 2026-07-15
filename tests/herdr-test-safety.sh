#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

# Herdr backend tests drive the real fm-spawn/fm-teardown but do not source
# tests/lib.sh, so exempt them from the gate-lifecycle refusal here too (see
# tests/lib.sh and bin/fm-gate-refuse-lib.sh for why firstmate's own suite,
# which the no-mistakes gate runs from a gate worktree, must be exempt).
export FM_GATE_REFUSE_BYPASS=1

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-herdr-lab.sh
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}

herdr_wait_for_pane_prompt() { # <session> <pane>
  local session=$1 pane=$2 attempt=0 capture
  while [ "$attempt" -lt 200 ]; do
    capture=$(fm_herdr_lab_cli "$session" pane read "$pane" --source recent --lines 200 2>/dev/null || true)
    case "$capture" in
      *$'\n❯'|*$'\n›'|*$'\n$'|*$'\n%'|*$'\n#'|*$'\n>') return 0 ;;
    esac
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}
