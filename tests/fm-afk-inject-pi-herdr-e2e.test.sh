#!/usr/bin/env bash
# Real Pi/Herdr regression for away-mode injection into Pi's separator-framed
# composer.
#
# This is opt-in because it launches a real interactive Pi process in a
# generated non-default Herdr lab session. A task-local before_agent_start hook
# captures only synthetic prompts and aborts before any provider request.
#
# Every Herdr call, including calls made inside the production backend adapter,
# is routed through bin/fm-herdr-lab.sh. The PATH shim strips only the adapter's
# already-validated trailing --session pair, then delegates to the lab helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"
# shellcheck source=bin/fm-supervise-daemon.sh
. "$ROOT/bin/fm-supervise-daemon.sh"

if [ "${FM_AFK_PI_HERDR_E2E:-0}" != 1 ]; then
  echo "skip: set FM_AFK_PI_HERDR_E2E=1 to run the real Pi/Herdr away-mode injection regression"
  exit 0
fi

for tool in git herdr jq pi python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name fm-afk-injection-wedge-a8)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-pi-herdr-e2e.XXXXXX")
PRIMARY_HOME="$TMP_ROOT/primary-home"
PI_HOME="$TMP_ROOT/pi-primary"
CAPTURE="$TMP_ROOT/pi-before-agent.jsonl"
FAKEBIN="$TMP_ROOT/fakebin"
ORIGINAL_PATH=$PATH
ID='afk-pi-primary'
STARTUP='SYNTHETIC_AFK_PI_STARTUP'
DRAFT='SYNTHETIC_AFK_PI_DRAFT'
DIGEST='SYNTHETIC_AFK_PRIVACY_DECISION'

cleanup() {
  local rc=$?
  trap - EXIT
  if ! "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/data" "$PRIMARY_HOME/config" \
  "$PRIMARY_HOME/projects" "$FAKEBIN"

# Route production adapter invocations through the guarded lab helper without
# permitting a foreign or ambient-only session target.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || { echo "wrapper requires the isolated lab session" >&2; exit 98; }
  for arg in "\${args[@]}"; do
    case "\$arg" in
      --session|--session=*) echo "wrapper refused non-trailing session flag" >&2; exit 99 ;;
    esac
  done
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

git clone -q --no-hardlinks "$ROOT" "$PI_HOME"
git -C "$PI_HOME" checkout -q --detach HEAD
mkdir -p "$PI_HOME/state" "$PI_HOME/data" "$PI_HOME/config" "$PI_HOME/projects"
printf '%s\n' "$ID" > "$PI_HOME/.fm-secondmate-home"
cat > "$PI_HOME/data/charter.md" <<EOF
# Isolated Pi primary

$STARTUP
EOF

# The real secondmate launch already loads this extension explicitly. Add a
# task-local synthetic capture hook and abort before Pi can contact a provider.
CAPTURE_JSON=$(printf '%s' "$CAPTURE" | jq -Rs .)
python3 - "$PI_HOME/.pi/extensions/fm-primary-turnend-guard.ts" "$CAPTURE_JSON" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
capture_json = sys.argv[2]
source = path.read_text()
import_anchor = 'import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";\n'
source = source.replace(
    import_anchor,
    import_anchor
    + 'import { appendFileSync as fmAppendFileSync } from "node:fs";\n'
    + f'const fmCapturePath = {capture_json};\n',
    1,
)
factory_anchor = 'export default function (pi: ExtensionAPI) {\n'
replacement = '''export default function (pi: ExtensionAPI) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.on("before_agent_start", async (event, ctx) => {
    fmAppendFileSync(fmCapturePath, `${JSON.stringify({ prompt: event.prompt })}\\n`);
    await new Promise((resolve) => setTimeout(resolve, 1000));
    ctx.abort();
  });
'''
if import_anchor not in source or factory_anchor not in source:
    raise SystemExit("Pi extension insertion point missing")
path.write_text(source.replace(factory_anchor, replacement, 1))
PY

"$LAB_HELPER" provision "$SESSION"
PATH="$FAKEBIN:$ORIGINAL_PATH" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$PRIMARY_HOME" HERDR_SESSION="$SESSION" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PI_HOME" --secondmate --harness pi --backend herdr >/dev/null 2>&1

META="$PRIMARY_HOME/state/$ID.meta"
[ -f "$META" ] || fail "real Pi launch did not write isolated metadata"
TARGET=$(fm_backend_target_of_meta "$META")
PANE=${TARGET#*:}
case "$TARGET" in
  "$SESSION":w*:p*) : ;;
  *) fail "real Pi launch recorded an unexpected Herdr target" ;;
esac

wait_for_prompt() { # <needle>
  local needle=$1 _
  for _ in $(seq 1 240); do
    if [ -s "$CAPTURE" ] && jq -e --arg needle "$needle" \
      'select(.prompt | contains($needle))' "$CAPTURE" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_for_idle() {
  local status _ stable=0
  for _ in $(seq 1 240); do
    status=$("$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null \
      | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
    case "$status" in
      idle|done)
        stable=$((stable + 1))
        [ "$stable" -ge 4 ] && return 0
        ;;
      *) stable=0 ;;
    esac
    sleep 0.25
  done
  return 1
}

composer_state() {
  PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" \
    fm_backend_herdr_composer_state "$TARGET"
}

wait_for_prompt "$STARTUP" || fail "real Pi synthetic capture hook did not load"
wait_for_idle || fail "real Pi did not settle after the synthetic startup turn"
[ "$(composer_state)" = empty ] \
  || fail "real Pi separator-framed empty composer was not classified empty"

"$LAB_HELPER" run "$SESSION" pane send-text "$PANE" "$DRAFT" >/dev/null
[ "$(composer_state)" = pending ] \
  || fail "real Pi separator-framed draft was not classified pending"
touch "$PRIMARY_HOME/state/.afk"
if PATH="$FAKEBIN:$ORIGINAL_PATH" FM_STATE_OVERRIDE="$PRIMARY_HOME/state" \
  FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$TARGET" \
  FM_INJECT_CONFIRM_SLEEP=0.2 inject_msg "$DIGEST" "$PRIMARY_HOME/state"; then
  fail "away-mode injector submitted into a real Pi draft"
fi
if [ -s "$CAPTURE" ] && jq -e --arg needle "$DIGEST" \
  'select(.prompt | contains($needle))' "$CAPTURE" >/dev/null 2>&1; then
  fail "real Pi received the away-mode digest while its draft was pending"
fi
pass "real Pi/Herdr: a drafted separator-framed composer refuses away-mode injection"

"$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" ctrl+c >/dev/null
for _ in $(seq 1 80); do
  [ "$(composer_state)" = empty ] && break
  sleep 0.25
done
[ "$(composer_state)" = empty ] || fail "real Pi composer did not clear after the synthetic draft"
wait_for_idle || fail "real Pi did not settle after clearing the synthetic draft"

if ! PATH="$FAKEBIN:$ORIGINAL_PATH" FM_STATE_OVERRIDE="$PRIMARY_HOME/state" \
  FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$TARGET" \
  FM_INJECT_CONFIRM_SLEEP=1 inject_msg "$DIGEST" "$PRIMARY_HOME/state"; then
  printf 'diagnostic: composer=%s agent-status=%s\n' "$(composer_state)" \
    "$("$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null \
      | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)" >&2
  fail "away-mode injector did not confirm submit into a real empty Pi composer"
fi
wait_for_prompt "$DIGEST" || fail "real Pi did not receive the synthetic away-mode digest"
COUNT=$(jq -s --arg needle "$DIGEST" '[.[] | select(.prompt | contains($needle))] | length' "$CAPTURE")
[ "$COUNT" -eq 1 ] || fail "real Pi received the synthetic away-mode digest more than once"
pass "real Pi/Herdr: an empty separator-framed composer receives one confirmed away-mode injection"
