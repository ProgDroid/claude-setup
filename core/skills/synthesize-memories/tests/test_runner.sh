# run-tests.sh must not report success it did not observe.
# Each case runs a COPY of run-tests.sh (+ lib.sh) beside fixture test files.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mk_fixture() { # <name> -> prints the dir; copies the real runner into it
  mkdir -p "$TMP/$1"
  cp "$HERE/run-tests.sh" "$HERE/lib.sh" "$TMP/$1/"
  printf '%s\n' "$TMP/$1"
}

# 1. a directory with no test files ran nothing, which is a failure
F="$(mk_fixture empty)"
OUT="$(bash "$F/run-tests.sh" 2>&1)"; RC=$?
assert_eq "$([ "$RC" -ne 0 ] && echo nonzero || echo zero)" "nonzero" "no test files: runner exits non-zero"
assert_contains "$OUT" "0 assertions" "no test files: output says 0 assertions"

# 2. sanity: one passing test file passes (the runner can say success)
F="$(mk_fixture good)"
printf 'assert_eq 1 1 "fixture passes"\n' > "$F/test_a.sh"
OUT="$(bash "$F/run-tests.sh" 2>&1)"; RC=$?
assert_eq "$RC" "0" "one passing test file: exit 0"
assert_contains "$OUT" "1 assertions, 0 failed" "one passing test file: counted"

# 3. a failing assertion is still a failure
F="$(mk_fixture bad)"
printf 'assert_eq 1 2 "fixture fails"\n' > "$F/test_a.sh"
bash "$F/run-tests.sh" >/dev/null 2>&1
assert_eq "$([ "$?" -ne 0 ] && echo nonzero || echo zero)" "nonzero" "failing assertion: exit non-zero"

# 4. a test file that calls exit 0 before reporting is a failure, even after a good one
#    (test_a would leave counts behind for test_b to inherit if they were reused)
F="$(mk_fixture early)"
printf 'assert_eq 1 1 "fixture passes"\n' > "$F/test_a.sh"
printf 'exit 0\nassert_eq 1 1 "never reached"\n' > "$F/test_b.sh"
OUT="$(bash "$F/run-tests.sh" 2>&1)"; RC=$?
assert_eq "$([ "$RC" -ne 0 ] && echo nonzero || echo zero)" "nonzero" "early exit 0: runner exits non-zero"
assert_contains "$OUT" "test_b.sh" "early exit 0: the offending file is named"
assert_contains "$OUT" "did not report" "early exit 0: reported as not having reported counts"

# 5. the runner keeps its per-test counts OUT of the tests directory: the second file
#    looks beside itself while it runs, after the first file has already reported
F="$(mk_fixture clean)"
printf 'assert_eq 1 1 "first file reports"
' > "$F/test_a.sh"
printf 'assert_eq "$(ls -A "$HERE" | grep -c counts)" "0" "no counts file beside the tests mid-run"
' > "$F/test_b.sh"
OUT="$(bash "$F/run-tests.sh" 2>&1)"; RC=$?
assert_eq "$RC" "0" "counts kept outside the tests dir: runner passes"
assert_contains "$OUT" "2 assertions, 0 failed" "counts kept outside the tests dir: both files counted"
