#!/usr/bin/env bash
# Tests: stack and oracle detection (root + one level down + CI workflows + shell suites).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

stk() { bash "$RITUAL" stack "$1"; }
orc() { bash "$RITUAL" oracle "$1"; }
mk() { mkdir -p "$(dirname "$1")"; printf '%s\n' "${2:-x}" > "$1"; }   # mk <path> [content]
eq() { # eq <name> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got $2 want $3"; fi
}

# --- nested server crate + app flutter (no root manifest), plus root pytest.ini
r="$(mkrepo)"; mk "$r/server/Cargo.toml" '[package]'; mk "$r/server/src/lib.rs" '#[test] fn t() {}'; mk "$r/app/pubspec.yaml"; mk "$r/pytest.ini" '[pytest]'
out="$(stk "$r")"
eq "stack_nested_rust_flutter_plus_root_python" "$(jq -c .stacks <<<"$out")" \
  '[{"lang":"python","dir":"."},{"lang":"flutter","dir":"app"},{"lang":"rust","dir":"server"}]'
eq "stack_includes_mapped_and_testing_when_oracle" "$(jq -c .includes <<<"$out")" '["python.md","rust.md","testing.md"]'
o="$(orc "$r")"
eq "oracle_orders_by_dir_then_cmd" "$(jq -c '[.test[]|[.dir,.cmd]]' <<<"$o")" '[[".","pytest"],["server","cargo test"]]'

# --- python tests/ dir, requirements.txt, no pyproject
r="$(mkrepo)"; mk "$r/requirements.txt"; mk "$r/tests/test_x.py" 'def test_a(): pass'
o="$(orc "$r")"
eq "python_tests_dir_without_pyproject" "$o" '{"status":"present","test":[{"cmd":"pytest","dir":".","source":"tests/"}],"lint":[]}'
eq "python_stack_from_requirements" "$(jq -c .stacks <<<"$(stk "$r")")" '[{"lang":"python","dir":"."}]'
r="$(mkrepo)"; mk "$r/tests/notes.txt"
eq "tests_dir_without_py_files_is_not_a_suite" "$(jq -r .status <<<"$(orc "$r")")" absent

# --- pytest.ini only
r="$(mkrepo)"; mk "$r/pytest.ini" '[pytest]'
eq "pytest_ini" "$(jq -c '[.status,.test[0].cmd,.test[0].source]' <<<"$(orc "$r")")" '["present","pytest","pytest.ini"]'

# --- shell suites
r="$(mkrepo)"; mk "$r/hooks/test-a.sh" '#!/bin/sh'
eq "shell_suites" "$(orc "$r")" '{"status":"present","test":[{"cmd":"bash hooks/test-a.sh","dir":".","source":"hooks/test-a.sh"}],"lint":[]}'
r="$(mkrepo)"; mk "$r/a/b/test-deep.sh"
eq "shell_suite_three_levels_down_not_found" "$(jq -r .status <<<"$(orc "$r")")" absent

# --- CI-only command
r="$(mkrepo)"
mk "$r/.github/workflows/ci.yml" 'jobs:
  t:
    steps:
      - uses: actions/checkout@v4
      - run: just test
      - run: echo hello'
o="$(orc "$r")"
eq "ci_only_command" "$o" '{"status":"present","test":[{"cmd":"just test","dir":".","source":".github/workflows/ci.yml"}],"lint":[]}'
eq "ci_only_no_stack_testing_include" "$(stk "$r")" '{"stacks":[],"includes":["testing.md"]}'

# --- CI: lint vs test classification, multi-line block takes first line, CRLF tolerated
r="$(mkrepo)"; mkdir -p "$r/.github/workflows"
printf 'steps:\r\n  - run: cargo clippy --all-targets\r\n  - run: |\r\n      pytest -q\r\n      echo done\r\n  - name: Run tests\r\n    run: echo unrelated\r\n' > "$r/.github/workflows/ci.yaml"
o="$(orc "$r")"
eq "ci_block_first_line_is_test" "$(jq -c '[.test[].cmd]' <<<"$o")" '["pytest -q"]'
eq "ci_clippy_is_lint_and_filter_drops_echo" "$(jq -c '[.lint[].cmd]' <<<"$o")" '["cargo clippy --all-targets"]'
r="$(mkrepo)"; mk "$r/.github/workflows/l.yml" '- run: ruff check .'
o="$(orc "$r")"
eq "lint_only_leaves_status_absent" "$(jq -c '[.status,(.lint|length)]' <<<"$o")" '["absent",1]'

# --- cargo lint, both forms; workspace members become stacks but not extra test cmds
r="$(mkrepo)"; mk "$r/Cargo.toml" '[package]
[lints.clippy]
pedantic = "warn"'
eq "cargo_lint_root_form" "$(jq -c .lint <<<"$(orc "$r")")" \
  '[{"cmd":"cargo clippy --all-targets -- -D warnings","dir":".","source":"Cargo.toml"}]'
r="$(mkrepo)"; mk "$r/Cargo.toml" '[workspace]
members = [
  "crates/*",
  "tools/cli",
]
[workspace.lints.clippy]
pedantic = "warn"'
mk "$r/crates/a/src/lib.rs" '#[cfg(test)] mod t {}'; mk "$r/crates/a/Cargo.toml" '[package]'; mk "$r/crates/b/Cargo.toml" '[package]'; mk "$r/tools/cli/Cargo.toml" '[package]'
o="$(orc "$r")"
eq "cargo_lint_workspace_form" "$(jq -c '[.lint[]|[.dir,.cmd]]' <<<"$o")" '[[".","cargo clippy --all-targets -- -D warnings"]]'
eq "workspace_members_not_separate_test_cmds" "$(jq -c '[.test[]|[.dir,.cmd]]' <<<"$o")" '[[".","cargo test"]]'
eq "workspace_members_are_stacks" "$(jq -c '[.stacks[]|.dir]' <<<"$(stk "$r")")" '[".","crates/a","crates/b","tools/cli"]'

# --- nothing found
r="$(mkrepo)"
eq "nothing_found_oracle" "$(orc "$r")" '{"status":"absent","test":[],"lint":[]}'
eq "nothing_found_stack" "$(stk "$r")" '{"stacks":[],"includes":[]}'

# --- skips node_modules / target / build / dot dirs; does not descend past one level
r="$(mkrepo)"
mk "$r/node_modules/x/package.json" '{"scripts":{"test":"jest"}}'
mk "$r/node_modules/package.json" '{"scripts":{"test":"jest"}}'
mk "$r/target/Cargo.toml"; mk "$r/build/pubspec.yaml"; mk "$r/.beads/package.json" '{"scripts":{"test":"jest"}}'
mk "$r/a/b/Cargo.toml"
eq "skips_pruned_dirs_and_depth_two" "$(jq -c '[.status,(.test|length)]' <<<"$(orc "$r")")" '["absent",0]'
eq "skips_pruned_dirs_stacks" "$(jq -c .stacks <<<"$(stk "$r")")" '[]'

# --- node: scripts.test, scripts.lint, react include; npm placeholder is not a test
r="$(mkrepo)"; mk "$r/web/package.json" '{"dependencies":{"react":"18"},"scripts":{"test":"vitest","lint":"eslint ."}}'
o="$(orc "$r")"
eq "node_test_and_lint_scripts" "$(jq -c '[.test[0].cmd,.lint[0].cmd,.test[0].dir]' <<<"$o")" '["npm test","npm run lint","web"]'
eq "node_react_include" "$(jq -c .includes <<<"$(stk "$r")")" '["react.md","testing.md"]'
r="$(mkrepo)"; mk "$r/package.json" '{"dependencies":{"left-pad":"1"},"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}'
eq "node_placeholder_test_not_reported" "$(jq -r .status <<<"$(orc "$r")")" absent
eq "node_without_react_has_no_include" "$(stk "$r")" '{"stacks":[{"lang":"node","dir":"."}],"includes":[]}'

# --- go, flutter, lua, ruff
r="$(mkrepo)"; mk "$r/go.mod" 'module m'; mk "$r/x_test.go"
o="$(orc "$r")"
eq "go_test_and_vet" "$(jq -c '[.test[0].cmd,.lint[0].cmd]' <<<"$o")" '["go test ./...","go vet ./..."]'
eq "go_include_is_golang_md" "$(jq -c .includes <<<"$(stk "$r")")" '["golang.md","testing.md"]'
r="$(mkrepo)"; mk "$r/go.mod" 'module m'
eq "go_without_test_files_is_absent" "$(jq -r .status <<<"$(orc "$r")")" absent
r="$(mkrepo)"; mk "$r/pubspec.yaml"; mk "$r/test/a_test.dart"
eq "flutter_test_and_analyze" "$(jq -c '[.test[0].cmd,.lint[0].cmd]' <<<"$(orc "$r")")" '["flutter test","flutter analyze"]'
r="$(mkrepo)"; mk "$r/proj.rockspec"
eq "lua_stack_has_no_include" "$(stk "$r")" '{"stacks":[{"lang":"lua","dir":"."}],"includes":[]}'
r="$(mkrepo)"; mk "$r/pyproject.toml" '[tool.ruff]
line-length = 100'
eq "ruff_lint" "$(jq -c .lint <<<"$(orc "$r")")" '[{"cmd":"ruff check","dir":".","source":"pyproject.toml"}]'

# --- justfile / Makefile / README sources
r="$(mkrepo)"; mk "$r/justfile" 'set shell := ["bash", "-c"]
test := "x"
check-all := "y"
test-unit arg:
    cargo test
lint:
    cargo clippy
# test: commented out
  test-indented:
    true'
o="$(orc "$r")"
eq "justfile_recipes_not_assignments" "$(jq -c '[.test[].cmd,.lint[].cmd]' <<<"$o")" '["just test-unit","just lint"]'
eq "justfile_source_named" "$(jq -c '[.test[0].source,.test[0].dir]' <<<"$o")" '["justfile","."]'
r="$(mkrepo)"; mk "$r/justfile" 'test := "x"'
eq "justfile_assignment_alone_is_absent" "$(jq -r .status <<<"$(orc "$r")")" absent
r="$(mkrepo)"; mk "$r/Makefile" 'CC := gcc
build:
	true
test:
	./run
check:
	true'
o="$(orc "$r")"
eq "makefile_targets" "$(jq -c '[.status,.test[0].cmd,.lint[0].cmd,.test[0].source]' <<<"$o")" '["present","make test","make check","Makefile"]'
r="$(mkrepo)"; mk "$r/Makefile" 'test := 1'
eq "makefile_assignment_alone_is_absent" "$(jq -r .status <<<"$(orc "$r")")" absent
r="$(mkrepo)"; mk "$r/README.md" '# Proj

Remember to run the tests before pushing; pytest is great.

```sh
$ pip install pytest
cargo nextest run
echo "tests done"
```

    npm test
'
o="$(orc "$r")"
eq "readme_fenced_runner_only" "$(jq -c '[.test[]|[.cmd,.source]]' <<<"$o")" '[["cargo nextest run","README.md"]]'
r="$(mkrepo)"; mk "$r/README.md" 'Please run the tests with pytest and make test.'
eq "readme_prose_never_counts" "$(jq -r .status <<<"$(orc "$r")")" absent

# --- runner classification: known runners only, installs never
r="$(mkrepo)"; mk "$r/.github/workflows/ci.yml" 'steps:
  - run: pip install pytest
  - run: echo "tests done"
  - run: cargo install cargo-nextest
  - run: npm install --save-dev jest
  - run: python -m pytest -q
  - run: cargo nextest run
  - run: golangci-lint run'
o="$(orc "$r")"
eq "ci_known_runners_only_test" "$(jq -c '[.test[].cmd]' <<<"$o")" '["cargo nextest run","python -m pytest -q"]'
eq "ci_known_runners_only_lint" "$(jq -c '[.lint[].cmd]' <<<"$o")" '["golangci-lint run"]'

# --- rust: cargo test only when a test exists
r="$(mkrepo)"; mk "$r/Cargo.toml" '[package]'; mk "$r/src/lib.rs" 'pub fn f() {}'
eq "rust_crate_without_tests_has_no_cargo_test" "$(jq -c '[.status,(.test|length)]' <<<"$(orc "$r")")" '["absent",0]'
mk "$r/src/lib.rs" '#[tokio::test]
async fn t() {}'
eq "rust_tokio_test_counts" "$(jq -r '.test[0].cmd' <<<"$(orc "$r")")" "cargo test"
r="$(mkrepo)"; mk "$r/Cargo.toml" '[package]'; mk "$r/tests/it.rs" 'fn main() {}'
eq "rust_tests_dir_counts" "$(jq -r .status <<<"$(orc "$r")")" present
r="$(mkrepo)"; mk "$r/Cargo.toml" '[package]
[lints.clippy]
pedantic = "warn"'; mk "$r/target/debug/x.rs" '#[test]'
o="$(orc "$r")"
eq "rust_target_dir_not_read_and_lint_still_reported" "$(jq -c '[.status,(.lint|length)]' <<<"$o")" '["absent",1]'

# --- UNKNOWN is not absent: malformed manifest
r="$(mkrepo)"; mk "$r/package.json" '{ not json'
o="$(orc "$r")"
eq "malformed_package_json_is_unknown" "$(jq -c '[.status,.detail]' <<<"$o")" '["unknown","could not parse: package.json"]'
r="$(mkrepo)"; mk "$r/web/package.json" '{ not json'; mk "$r/pytest.ini"
o="$(orc "$r")"
eq "malformed_manifest_but_test_found_is_present" "$(jq -c '[.status,.detail]' <<<"$o")" '["present","could not parse: web/package.json"]'
eq "stack_reports_unparsed_manifest" "$(stk "$r" | jq -c '.unparsed')" '["web/package.json"]'

# --- go: test files under pruned dirs do not count
r="$(mkrepo)"; mk "$r/go.mod" 'module m'; mk "$r/node_modules/x/a_test.go"; mk "$r/vendor/y/b_test.go"
eq "go_tests_only_in_pruned_dirs_is_absent" "$(jq -r .status <<<"$(orc "$r")")" absent

# --- compound CI command lines: segments, env prefixes, cd, multi-line blocks
ci_cmds() { # ci_cmds <yaml body>: prints the test cmds JSON for a repo holding that workflow
  local rr; rr="$(mkrepo)"; mk "$rr/.github/workflows/ci.yml" "$1"; orc "$rr" | jq -c '[.test[].cmd]'
}
eq "ci_cd_prefix_kept" "$(ci_cmds '- run: cd x && cargo test')" '["cd x && cargo test"]'
eq "ci_env_assignment_stripped" "$(ci_cmds '- run: RUST_LOG=1 cargo test')" '["cargo test"]'
eq "ci_install_then_test_same_line" "$(ci_cmds '- run: npm ci && npm test')" '["npm test"]'
eq "ci_uv_run_pytest" "$(ci_cmds '- run: uv run pytest')" '["uv run pytest"]'
eq "ci_pnpm_run_test" "$(ci_cmds '- run: pnpm run test')" '["pnpm run test"]'
eq "ci_npm_run_test_colon_script" "$(ci_cmds '- run: npm run test:unit')" '["npm run test:unit"]'
eq "ci_semicolon_and_pipe_segments" "$(ci_cmds '- run: make build; go test ./... | tee out.txt')" '["go test ./..."]'
eq "ci_npm_ci_alone_is_none" "$(ci_cmds '- run: npm ci')" '[]'
eq "ci_multiline_block_reads_every_line" "$(ci_cmds 'steps:
  - name: t
    run: |
      npm ci
      npm test
  - run: echo after')" '["npm test"]'
eq "ci_block_ends_at_dedent" "$(ci_cmds 'steps:
  - run: |
      echo hi
    env:
      X: pytest
  - run: ctest')" '["ctest"]'

# --- justfile / Makefile name forms
r="$(mkrepo)"; mk "$r/justfile" '@test:
    cargo test
test2 arg="a":
    true
test_unit:
    true'
eq "justfile_quiet_params_and_underscore" "$(jq -c '[.test[].cmd]' <<<"$(orc "$r")")" '["just test","just test2","just test_unit"]'
r="$(mkrepo)"; mk "$r/Makefile" '.PHONY: test
test-unit:
	true
test_all: dep
	true'
eq "makefile_test_variants_not_phony" "$(jq -c '[.test[].cmd]' <<<"$(orc "$r")")" '["make test-unit","make test_all"]'

# --- rust test attribute variants
for attr in '#[actix_web::test]' '#[actix_rt::test]' '#[sqlx::test]' '#[async_std::test]' '#[rstest]' '#[test_case(1)]'; do
  r="$(mkrepo)"; mk "$r/Cargo.toml" '[package]'; mk "$r/src/lib.rs" "$attr"
  eq "rust_attr_$attr" "$(jq -r .status <<<"$(orc "$r")")" present
done

# --- stack reports a malformed manifest anywhere the scan looked (here: a workspace member)
r="$(mkrepo)"; mk "$r/Cargo.toml" '[workspace]
members = ["crates/x"]'; mk "$r/crates/x/Cargo.toml" '[package]'; mk "$r/crates/x/package.json" '{ nope'
eq "stack_unparsed_in_member_dir" "$(stk "$r" | jq -c '.unparsed')" '["crates/x/package.json"]'

# --- failure modes
bash "$RITUAL" stack "$TMPROOT/not-a-repo-$$" >/dev/null 2>&1; eq "stack_refuses_non_repo" "$?" 2
bash "$RITUAL" oracle "$TMPROOT/not-a-repo-$$" >/dev/null 2>&1; eq "oracle_refuses_non_repo" "$?" 2
bash "$RITUAL" stack >/dev/null 2>&1; eq "stack_usage_error" "$?" 2
eq "stack_json_dies_when_repo_unscannable" "$( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/detect.sh"; (stack_json "$TMPROOT/does-not-exist") >/dev/null 2>&1; echo $?)" 2
eq "oracle_unknown_when_detection_cannot_run" \
  "$( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/detect.sh"; oracle_json "$TMPROOT/does-not-exist")" \
  '{"status":"unknown","test":[],"lint":[]}'

finish
