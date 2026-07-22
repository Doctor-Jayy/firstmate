#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_quiet_checkpoint_retries_delayed_owner_cleanup() {
  local home fakebin out err status attempt
  home=$(make_home delayed-owner)
  fakebin=$(fm_fakebin "$home")
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
(
  ( exec "$@" ) &
  watcher=$!
  printf '%s\n' "$watcher" > "$FM_HOME/state/.watch-fixture-watcher"
  attempt=0
  while [ "$attempt" -lt 500 ]; do
    [ "$(cat "$FM_HOME/state/.watch.lock/pid" 2>/dev/null || true)" = "$watcher" ] && break
    sleep 0.01
    attempt=$((attempt + 1))
  done
  sleep 0.4
  kill -KILL "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  : > "$FM_HOME/state/.watch-fixture-reaped"
) &
attempt=0
while [ "$attempt" -lt 500 ]; do
  watcher=$(cat "$FM_HOME/state/.watch-fixture-watcher" 2>/dev/null || true)
  [ -n "$watcher" ] \
    && [ "$(cat "$FM_HOME/state/.watch.lock/pid" 2>/dev/null || true)" = "$watcher" ] \
    && break
  sleep 0.01
  attempt=$((attempt + 1))
done
[ "$attempt" -lt 500 ] || exit 125
exit 124
SH
  chmod +x "$fakebin/timeout"
  status=0
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_POLL=10 FM_SIGNAL_GRACE=10 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "delayed-owner quiet checkpoint exit"
  attempt=0
  while [ ! -e "$home/state/.watch-fixture-reaped" ] && [ "$attempt" -lt 200 ]; do
    sleep 0.01
    attempt=$((attempt + 1))
  done
  assert_present "$home/state/.watch-fixture-reaped" "delayed watcher supervisor did not reap its child"
  assert_absent "$home/state/.watch.lock" "delayed watcher owner left its lock behind"
  pass "quiet checkpoint retries until a delayed timed-out watcher releases ownership"
}

test_quiet_checkpoint_never_steals_live_lock() {
  local home fakebin out err status peer
  home=$(make_home live-owner)
  fakebin=$(fm_fakebin "$home")
  out="$home/out.txt"
  err="$home/err.txt"
  sleep 30 &
  peer=$!
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$peer" > "$home/state/.watch.lock/pid"
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
exit 124
SH
  chmod +x "$fakebin/timeout"
  status=0
  PATH="$fakebin:$PATH" FM_HOME="$home" "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "live-owner cleanup refusal"
  [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)" = "$peer" ] \
    || { kill "$peer" 2>/dev/null || true; fail "checkpoint stole or replaced a live watcher lock"; }
  assert_contains "$(cat "$err")" "timed-out watcher still owns" "live lock cleanup failure was not explained"
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  pass "quiet checkpoint refuses to steal a live watcher lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_quiet_checkpoint_exits_124_cleanly
test_quiet_checkpoint_retries_delayed_owner_cleanup
test_quiet_checkpoint_never_steals_live_lock
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
