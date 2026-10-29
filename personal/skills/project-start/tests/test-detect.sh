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
eq "stack_includes_mapped_and_testing_when_oracle" "$(jq -c .includes <<<"$out")" '["core:python-standards","core:rust-standards","core:testing-standards"]'
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
eq "ci_only_no_stack_testing_include" "$(stk "$r")" '{"stacks":[],"includes":["core:testing-standards"]}'

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
eq "node_react_include" "$(jq -c .includes <<<"$(stk "$r")")" '["core:react-standards","core:testing-standards"]'
r="$(mkrepo)"; mk "$r/package.json" '{"dependencies":{"left-pad":"1"},"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}'
eq "node_placeholder_test_not_reported" "$(jq -r .status <<<"$(orc "$r")")" absent
eq "node_without_react_has_no_include" "$(stk "$r")" '{"stacks":[{"lang":"node","dir":"."}],"includes":[]}'

# --- go, flutter, lua, ruff
r="$(mkrepo)"; mk "$r/go.mod" 'module m'; mk "$r/x_test.go"
o="$(orc "$r")"
eq "go_test_and_vet" "$(jq -c '[.test[0].cmd,.lint[0].cmd]' <<<"$o")" '["go test ./...","go vet ./..."]'
eq "go_include_is_golang_md" "$(jq -c .includes <<<"$(stk "$r")")" '["core:golang-standards","core:testing-standards"]'
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
# the lines after the dedent must START with a runner, or a block that never ends reports nothing
# anyway and the test cannot tell (measured: `X: pytest` alone passed with the dedent rule removed)
eq "ci_block_ends_at_dedent" "$(ci_cmds 'steps:
  - run: |
      echo hi
    env:
      X: pytest
    with:
      script: |
        pytest
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

# --- Cargo workspace exclude: an excluded crate is its own crate, with its own test entry
lib() { ( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/detect.sh"; cd "$1" || exit 9; shift; "$@" ); }
r="$(mkrepo)"; mk "$r/Cargo.toml" '[workspace]
members = ["crates/*"]
exclude = ["crates/skip"]'
mk "$r/crates/a/Cargo.toml" '[package]'; mk "$r/crates/a/src/lib.rs" '#[test] fn t() {}'
mk "$r/crates/skip/Cargo.toml" '[package]'; mk "$r/crates/skip/src/lib.rs" '#[test] fn t() {}'
eq "members_honour_exclude" "$(jq -c '[.test[]|[.dir,.cmd]]' <<<"$(orc "$r")")" '[[".","cargo test"],["crates/skip","cargo test"]]'
eq "excluded_member_is_stack" "$(jq -c '[.stacks[]|.dir]' <<<"$(stk "$r")")" '[".","crates/a","crates/skip"]'
r="$(mkrepo)"; mk "$r/Cargo.toml" '[workspace]
exclude = [
  "crates/skip",
  "./tools/",
]
members = ["crates/*", "tools/*"]'
for c in crates/a crates/skip crates/skipper tools/t; do mk "$r/$c/Cargo.toml" '[package]'; done
eq "ws_members_minus_exclude" "$(lib "$r" _det_members | tr '\n' ' ')" 'crates/a crates/skipper '
eq "ws_excluded_members" "$(lib "$r" _det_excluded | tr '\n' ' ')" 'crates/skip tools/t '

# --- one workspace parse per scan (RITUAL_TRACE logs one "ws_parse" per real parse)
wsn() { # wsn <cmd> <repo>: how many ws_parse lines the command logged
  local t="$TMPROOT/ws-trace-$$"; : > "$t"; RITUAL_TRACE="$t" bash "$RITUAL" "$1" "$2" >/dev/null 2>&1
  grep -c '^ws_parse$' "$t"; rm -f "$t"
}
r="$(mkrepo)"; mk "$r/Cargo.toml" '[package]'; mk "$r/src/lib.rs" '#[test] fn t() {}'
eq "ws_parse_none_without_workspace" "$(wsn oracle "$r")|$(wsn stack "$r")" '0|0'
r="$(mkrepo)"; mk "$r/Cargo.toml" '[workspace]
members = ["crates/*"]
exclude = ["crates/skip"]'
for c in a skip; do mk "$r/crates/$c/Cargo.toml" '[package]'; mk "$r/crates/$c/src/lib.rs" '#[test] fn t() {}'; done
eq "ws_parse_once_per_oracle_scan" "$(wsn oracle "$r")|$(wsn stack "$r")" '1|2'
r="$(mkrepo)"; printf '[workspace]\r\nmembers = ["crates/a"]\r\n' > "$r/Cargo.toml"; mk "$r/crates/a/Cargo.toml" '[package]'
eq "ws_crlf_workspace_members_found" "$(jq -c '[.stacks[]|.dir]' <<<"$(stk "$r")")" '[".","crates/a"]'
r="$(mkrepo)"; printf '\r[workspace]\nmembers = ["crates/a"]\n' > "$r/Cargo.toml"; mk "$r/crates/a/Cargo.toml" '[package]'
eq "ws_cr_first_header_is_the_table" "$(jq -c '[.stacks[]|.dir]' <<<"$(stk "$r")")" '[".","crates/a"]'
r="$(mkrepo)"; mk "$r/Cargo.toml" '[workspace] # c
members = ["crates/a"]'; mk "$r/crates/a/Cargo.toml" '[package]'
got1="$(jq -c '[.stacks[]|.dir]' <<<"$(stk "$r")")|$(wsn oracle "$r")"
r="$(mkrepo)"; mk "$r/Cargo.toml" '[workspace.package]
members = ["crates/a"]'; mk "$r/crates/a/Cargo.toml" '[package]'
eq "ws_header_with_comment_and_subtable" "$got1;$(jq -c '[.stacks[]|.dir]' <<<"$(stk "$r")")|$(wsn oracle "$r")" '[".","crates/a"]|1;["."]|0'
r="$(mkrepo)"; mk "$r/Cargo.toml" '[workspace]
members = ["crates/a[1]", "crates/b"]
exclude = ["crates/a[1]"]'
mk "$r/crates/a[1]/Cargo.toml" '[package]'; mk "$r/crates/b/Cargo.toml" '[package]'
eq "ws_member_dir_with_glob_char" "$(lib "$r" _det_members | tr '\n' ' ')|$(lib "$r" _det_excluded | tr '\n' ' ')" 'crates/b |crates/a[1] '
# F4 probe: a member two levels down whose only test is an integration file under its tests/
r="$(mkrepo)"; mk "$r/Cargo.toml" '[workspace]
members = ["crates/a"]'; mk "$r/crates/a/Cargo.toml" '[package]'; mk "$r/crates/a/src/lib.rs" 'pub fn f() {}'
mk "$r/crates/a/tests/it.rs" 'fn main() {}'
eq "two_deep_member_gets_test" "$(jq -c '[.status,[.test[]|[.dir,.cmd,.source]]]' <<<"$(orc "$r")")" '["present",[[".","cargo test","Cargo.toml"]]]'

# --- quote-aware splitting: && || ; | break a line only outside quotes
eq "split_respects_quotes" "$(ci_cmds 'steps:
  - run: pytest -k "a|b"
  - run: pytest -k '"'x;y'"'')" '["pytest -k \"a|b\"","pytest -k '"'x;y'"'"]'
eq "split_unterminated_quote_invents_nothing" "$(ci_cmds '- run: echo "x; cargo test')" '[]'
eq "split_unterminated_quote_keeps_rest" "$(ci_cmds '- run: pytest -k "a|b')" '["pytest -k \"a|b"]'
eq "split_escaped_dquote_stays_quoted" "$(ci_cmds '- run: echo "a\" ; cargo test -q"')" '[]'
eq "split_backslash_in_squote_is_literal" "$(ci_cmds "- run: echo 'a\\' ; cargo test -q")" '["cargo test -q"]'
eq "split_double_bar_vs_pipe" "$(ci_cmds 'steps:
  - run: go test ./... || exit 1
  - run: pytest -q|tee log')" '["go test ./...","pytest -q"]'
split_segs() { ( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/detect.sh"; local -a out=(); _det_split_into out "$1"; printf 'n=%s' "${#out[@]}"; printf '[%s]' "${out[@]}" ); }
eq "split_fn_segments" "$(split_segs "a && b || c; d | e \"f|g\" 'h;i' j\\;k")" "n=5[a ][ b ][ c][ d ][ e \"f|g\" 'h;i' j\\;k]"

# --- cd: carried across the lines of one run block, never across steps
eq "cd_carries_across_block_lines" "$(ci_cmds 'steps:
  - run: |
      cd sub
      cargo test')" '["cd sub && cargo test"]'
eq "cd_not_carried_across_steps" "$(ci_cmds 'steps:
  - run: cd sub
  - run: cargo test')" '["cargo test"]'
eq "cd_chain_accumulates" "$(ci_cmds 'steps:
  - run: |
      cd a
      cd b && cargo test')" '["cd a && cd b && cargo test"]'
r="$(mkrepo)"; mk "$r/README.md" '```sh
cd server
cargo test
```'
eq "readme_cd_not_carried_across_lines" "$(jq -c '[.test[]|[.cmd,.source]]' <<<"$(orc "$r")")" '[["cargo test","README.md"]]'

# --- shell forms in CI: if/then/else, bash -c / sh -c, backslash continuations
eq "ci_if_bash_c_continuation" "$(ci_cmds 'steps:
  - run: if [ -f x ]; then pytest; fi
  - run: bash -c "cargo test"
  - run: |
      cargo test \
        --all')" '["cargo test","cargo test --all","pytest"]'
eq "ci_else_branch_and_negation" "$(ci_cmds 'steps:
  - run: if [ -f Cargo.toml ]; then cargo test; else go test ./...; fi
  - run: if ! pytest -q; then exit 1; fi')" '["cargo test","go test ./...","pytest -q"]'
# --- loops: a body runs once per value, with variables the repo root does not have, so nothing in
# a for/while/until loop is a test command (`pytest "$f"` run from the root is `pytest ""`).
# The `( for` line is a loop the loop counter does not see: only the unstripped `do` keeps it out.
eq "ci_loop_body_not_reported" "$(ci_cmds 'steps:
  - run: for f in tests/*.py; do pytest "$f"; done
  - run: ( for p in a b; do cargo test -p $p; done )')" '[]'
eq "ci_loop_nested_then_not_reported" "$(ci_cmds '- run: for f in a b; do if [ -f "$f" ]; then pytest "$f"; fi; done')" '[]'
# the counter is a depth, not a flag: the outer body goes on after the inner `done`
eq "ci_loop_multiline_nested_and_after" "$(ci_cmds 'steps:
  - run: |
      for a in x y; do
        for b in z; do
          pytest "$a$b"
        done
        cargo test -p "$a"
      done
      go test ./...
  - run: while read -r p; do cargo test -p "$p"; done < crates.txt; pytest -q')" '["go test ./...","pytest -q"]'
eq "bash_c_inner_cd_scoped" "$(ci_cmds '- run: bash -c "cd x && cargo test"; pytest')" '["cd x && cargo test","pytest"]'
eq "sh_ec_single_quotes" "$(ci_cmds "- run: sh -ec 'pytest -q'")" '["pytest -q"]'
eq "bash_c_dq_unescape" "$(ci_cmds '- run: bash -c "pytest -k \"a b\""')" '["pytest -k \"a b\""]'
eq "ci_continuation_three_lines_then_next" "$(ci_cmds 'steps:
  - run: |
      cargo test \
        --all \
        --locked
      pytest')" '["cargo test --all --locked","pytest"]'
eq "ci_even_backslashes_do_not_continue" "$(ci_cmds 'steps:
  - run: |
      echo done \\
      pytest')" '["pytest"]'
eq "ci_trailing_backslash_ends_at_step" "$(ci_cmds 'steps:
  - run: |
      cargo test \
  - run: pytest \')" '["cargo test","pytest"]'
eq "bash_c_script_must_be_one_word" "$(ci_cmds 'steps:
  - run: bash -c "pytest -q" "x"
  - run: sh -c '"'pytest -q' 'x'"'')" '[]'

# --- YAML outer quotes come off a single-line run: value only; a blank block line ends a continuation
eq "ci_block_line_quotes_kept" "$(ci_cmds 'steps:
  - run: |
      "$GIT" commit -m "fix; cargo test passes"')" '[]'
eq "ci_single_line_run_outer_quotes" "$(ci_cmds 'steps:
  - run: "cargo test"
  - run: '"'pytest -q'"'')" '["cargo test","pytest -q"]'
eq "ci_continuation_stops_at_blank_line" "$(ci_cmds 'steps:
  - run: |
      cargo test \

      pytest')" '["cargo test","pytest"]'
eq "cd_carries_across_blank_block_line" "$(ci_cmds 'steps:
  - run: |
      cd sub

      cargo test')" '["cd sub && cargo test"]'

# --- pinned from 0.16.0: what one package.json reads as. Both scans (oracle and stack) judge a file
# parsed only when `jq -e .` exits 0, so null / false / an empty file / a falsy LAST document are
# "unparsed"; a scripts/dependencies read that errors (a top-level array, a string) is just "nothing found".
P_ABS='{"status":"absent","test":[],"lint":[]}'
P_UNK='{"status":"unknown","test":[],"lint":[],"detail":"could not parse: package.json"}'
P_TEST='{"status":"present","test":[{"cmd":"npm test","dir":".","source":"package.json"}],"lint":[]}'
P_BOTH='{"status":"present","test":[{"cmd":"npm test","dir":".","source":"package.json"}],"lint":[{"cmd":"npm run lint","dir":".","source":"package.json"}]}'
P_LINT='{"status":"absent","test":[],"lint":[{"cmd":"npm run lint","dir":".","source":"package.json"}]}'
S_NODE='{"stacks":[{"lang":"node","dir":"."}],"includes":[]}'
S_UNP='{"stacks":[{"lang":"node","dir":"."}],"includes":[],"unparsed":["package.json"]}'
S_TST='{"stacks":[{"lang":"node","dir":"."}],"includes":["core:testing-standards"]}'
S_RCT='{"stacks":[{"lang":"node","dir":"."}],"includes":["core:react-standards"]}'
S_RCT_TST='{"stacks":[{"lang":"node","dir":"."}],"includes":["core:react-standards","core:testing-standards"]}'
pkg() { # pkg <name> <printf %b content> <want oracle> <want stack>
  local r; r="$(mkrepo)"; printf '%b' "$2" > "$r/package.json"
  eq "pkg_${1}_oracle" "$(orc "$r")" "$3"; eq "pkg_${1}_stack" "$(stk "$r")" "$4"
}
pkg empty '' "$P_UNK" "$S_UNP"
pkg null 'null\n' "$P_UNK" "$S_UNP"
pkg false 'false\n' "$P_UNK" "$S_UNP"
pkg array '[]\n' "$P_ABS" "$S_NODE"
pkg string '"s"\n' "$P_ABS" "$S_NODE"
pkg invalid '{ not json' "$P_UNK" "$S_UNP"
pkg two_docs '{"scripts":{"test":"a"}}\n{"dependencies":{"react":"1"}}\n' "$P_TEST" "$S_RCT_TST"
pkg two_docs_last_false '{"scripts":{"test":"a"}}\nfalse\n' "$P_UNK" "$S_UNP"
pkg two_docs_last_null '{"scripts":{"test":"t"}}\nnull\n' "$P_UNK" "$S_UNP"
pkg good_then_garbage '{"scripts":{"test":"t"}}\n{ bad' "$P_UNK" "$S_UNP"
pkg false_then_object 'false\n{"scripts":{"test":"t"},"dependencies":{"react":1}}\n' "$P_TEST" "$S_RCT_TST"
pkg array_then_object '[]\n{"scripts":{"test":"t"},"devDependencies":{"react":"1"}}\n' "$P_TEST" "$S_RCT_TST"
pkg react_only_in_first_doc '{"dependencies":{"react":"1"}}\n{"name":"x"}\n' "$P_ABS" "$S_NODE"
pkg react_then_array_doc '{"dependencies":{"react":"1"}}\n[]\n' "$P_ABS" "$S_NODE"
pkg react_in_dev_dependencies '{"devDependencies":{"react":"1"}}\n' "$P_ABS" "$S_RCT"
pkg react_key_with_null_value '{"dependencies":{"react":null}}\n' "$P_ABS" "$S_RCT"
pkg dependencies_a_string '{"dependencies":"x","devDependencies":{"react":1}}\n' "$P_ABS" "$S_NODE"
pkg test_a_number '{"scripts":{"test":1}}\n' "$P_TEST" "$S_TST"
pkg test_an_object '{"scripts":{"test":{"a":"b"}}}\n' "$P_TEST" "$S_TST"
pkg test_object_holding_placeholder '{"scripts":{"test":{"a":"no test specified"}}}\n' "$P_ABS" "$S_NODE"
pkg test_empty_string '{"scripts":{"test":"","lint":""}}\n' "$P_ABS" "$S_NODE"
pkg test_only_newline '{"scripts":{"test":"\\n","lint":"\\n"}}\n' "$P_ABS" "$S_NODE"
pkg test_newline_around_text '{"scripts":{"test":"\\nx\\n","lint":"\\n\\n"}}\n' "$P_TEST" "$S_TST"
pkg test_a_carriage_return '{"scripts":{"test":"\\r","lint":"\\r"}}\n' "$P_BOTH" "$S_TST"
pkg test_a_backslash_n '{"scripts":{"test":"\\\\n","lint":"y"}}\n' "$P_BOTH" "$S_TST"
pkg placeholder_in_first_doc '{"scripts":{"test":"no test specified"}}\n{"scripts":{"test":"real"}}\n' "$P_ABS" "$S_NODE"
pkg placeholder_in_second_doc '{"scripts":{"test":"x"}}\n{"scripts":{"test":"no test specified"}}\n' "$P_ABS" "$S_NODE"
pkg placeholder_on_second_line '{"scripts":{"test":"echo\\nno test specified"}}\n' "$P_ABS" "$S_NODE"
pkg lint_only '{"scripts":{"lint":"eslint ."}}\n' "$P_LINT" "$S_NODE"
pkg two_lints '{"scripts":{"lint":"a"}}\n{"scripts":{"lint":"b"}}\n' "$P_LINT" "$S_NODE"
pkg falsy_scripts '{"scripts":{"test":false,"lint":null}}\n' "$P_ABS" "$S_NODE"
pkg scripts_a_string '{"scripts":"x"}\n' "$P_ABS" "$S_NODE"
pkg scripts_empty '{"scripts":{}}\n' "$P_ABS" "$S_NODE"
# a UTF-8 BOM: whatever this jq makes of it, both scans must agree with `jq -e .`
r="$(mkrepo)"; printf '\xef\xbb\xbf{"scripts":{"test":"a"},"dependencies":{"react":"1"}}\n' > "$r/package.json"
if jq -e . "$r/package.json" >/dev/null 2>&1; then want_o="$P_TEST"; want_s="$S_RCT_TST"; else want_o="$P_UNK"; want_s="$S_UNP"; fi
eq "pkg_utf8_bom_oracle" "$(orc "$r")" "$want_o"; eq "pkg_utf8_bom_stack" "$(stk "$r")" "$want_s"

# --- pinned from 0.16.0: the four line-anchored manifest greps test the RAW line. A CRLF file still
# matches (the CR is after the text); a line that starts with a CR does not; the last line needs no newline.
mf() { # mf <name> <file> <printf %b content> <jq filter on the oracle> <want>
  local r; r="$(mkrepo)"; printf '%b' "$3" > "$r/$2"
  eq "$1" "$(jq -c "$4" <<<"$(orc "$r")")" "$5"
}
RUFF='[{"cmd":"ruff check","dir":".","source":"pyproject.toml"}]'
PYT='[{"cmd":"pytest","dir":".","source":"pyproject.toml"}]'
CLIP='[{"cmd":"cargo clippy --all-targets -- -D warnings","dir":".","source":"Cargo.toml"}]'
mf ruff_crlf pyproject.toml '[tool.ruff]\r\nline-length = 1\r\n' .lint "$RUFF"
mf ruff_cr_first pyproject.toml '\r[tool.ruff]\n' .lint '[]'
mf ruff_no_final_newline pyproject.toml '[tool.ruff]' .lint "$RUFF"
mf ruff_subtable pyproject.toml '[tool.ruff.lint]\nx = 1\n' .lint "$RUFF"
mf ruff_indented pyproject.toml ' [tool.ruff]\n' .lint '[]'
mf ruff_on_a_later_line pyproject.toml '[project]\nname = "x"\n[tool.ruff]\n' .lint "$RUFF"
mf ruff_header_inside_a_value pyproject.toml 'x = "[tool.ruff]"\n' .lint '[]'
mf pytest_crlf pyproject.toml '[tool.pytest.ini_options]\r\n' .test "$PYT"
mf pytest_cr_first pyproject.toml '\r[tool.pytest]\n' .test '[]'
mf pytest_no_final_newline pyproject.toml '[tool.pytest]' .test "$PYT"
mf pytest_on_a_later_line pyproject.toml '[project]\n[tool.pytest.ini_options]\n' .test "$PYT"
mf pytest_indented pyproject.toml ' [tool.pytest]\n' .test '[]'
mf clippy_crlf Cargo.toml '[package]\r\n[lints.clippy]\r\n' .lint "$CLIP"
mf clippy_cr_first Cargo.toml '[package]\n\r[lints.clippy]\n' .lint '[]'
mf clippy_no_final_newline Cargo.toml '[package]\n[lints.clippy]' .lint "$CLIP"
mf clippy_workspace_form_crlf Cargo.toml '[package]\r\n[workspace.lints.clippy]\r\n' .lint "$CLIP"
mf clippy_workspace_form_cr_first Cargo.toml '[package]\n\r[workspace.lints.clippy]\n' .lint '[]'
mf clippy_workspace_form_no_final_newline Cargo.toml '[package]\n[workspace.lints.clippy]' .lint "$CLIP"
mf clippy_subtable_is_not_the_table Cargo.toml '[package]\n[lints.clippy.pedantic]\n' .lint '[]'
mf clippy_other_lints_table Cargo.toml '[package]\n[lints.rust]\n' .lint '[]'
# A UTF-16LE manifest (PowerShell 5.1's `>` writes one): grep saw NUL bytes inside every header,
# so none matched. bash's read drops NULs and would have matched; a file with a NUL goes to grep.
RUFF_U='\xff\xfe[\x00p\x00]\x00\n\x00[\x00t\x00o\x00o\x00l\x00.\x00r\x00u\x00f\x00f\x00]\x00\n\x00'
PYT_U='\xff\xfe[\x00p\x00]\x00\n\x00[\x00t\x00o\x00o\x00l\x00.\x00p\x00y\x00t\x00e\x00s\x00t\x00]\x00\n\x00'
CLIP_U='\xff\xfe[\x00p\x00]\x00\n\x00[\x00l\x00i\x00n\x00t\x00s\x00.\x00c\x00l\x00i\x00p\x00p\x00y\x00]\x00\n\x00'
mf ruff_utf16le pyproject.toml "$RUFF_U" .lint '[]'
mf pytest_utf16le pyproject.toml "$PYT_U" .test '[]'
mf clippy_utf16le Cargo.toml "$CLIP_U" .lint '[]'
# a NUL later in the file does not hide a header grep did see (the same program decides)
mf ruff_header_then_a_nul pyproject.toml '[tool.ruff]\n\x00x\n' .lint "$RUFF"
mf ruff_nul_then_header pyproject.toml 'a\x00b\n[tool.ruff]\n' .lint "$RUFF"
mf ruff_nul_unrelated_file pyproject.toml '[project]\n\x00\n' .lint '[]'
# pytest.ini beats pyproject; ruff.toml is the fallback when pyproject has no ruff table
r="$(mkrepo)"; printf '[tool.pytest]\n' > "$r/pyproject.toml"; mk "$r/pytest.ini" '[pytest]'
eq "pytest_ini_wins_over_pyproject" "$(jq -c .test <<<"$(orc "$r")")" '[{"cmd":"pytest","dir":".","source":"pytest.ini"}]'
r="$(mkrepo)"; printf '[project]\n' > "$r/pyproject.toml"; mk "$r/ruff.toml"
eq "ruff_toml_when_pyproject_has_no_ruff" "$(jq -c .lint <<<"$(orc "$r")")" '[{"cmd":"ruff check","dir":".","source":"ruff.toml"}]'
# a crate dir whose Cargo.toml opens a [workspace] searches its whole tree for tests; that raw
# grep is not the CR-stripping one the root workspace parse uses
wsx() { # wsx <name> <printf %b Cargo.toml> <want status>
  local r; r="$(mkrepo)"; mkdir -p "$r/crate"; printf '%b' "$2" > "$r/crate/Cargo.toml"
  mk "$r/crate/other/t.rs" '#[test] fn t() {}'
  eq "$1" "$(jq -r .status <<<"$(orc "$r")")" "$3"
}
wsx crate_workspace_crlf '[workspace]\r\n' present
wsx crate_workspace_cr_first '\r[workspace]\n' absent
wsx crate_workspace_no_final_newline '[package]\n[workspace]' present
wsx crate_workspace_package_table_is_not_it '[workspace.package]\n' absent
wsx crate_without_workspace_reads_only_src_and_tests '[package]\n' absent
wsx crate_workspace_utf16le '\xff\xfe[\x00p\x00]\x00\n\x00[\x00w\x00o\x00r\x00k\x00s\x00p\x00a\x00c\x00e\x00]\x00\n\x00' absent

# --- _det_path_v: _det_path without the $(...) fork
r="$(mkrepo)"
eq "path_v_dot_is_the_bare_name" "$(lib "$r" bash -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; _det_path_v v . x; printf "%s" "$v"' "$SKILL_DIR")" "x"
eq "path_v_subdir_is_joined" "$(lib "$r" bash -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; _det_path_v v a x; printf "%s" "$v"' "$SKILL_DIR")" "a/x"
eq "path_v_keeps_spaces_globs_percent_and_backslash" "$(lib "$r" bash -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; _det_path_v v "a b*" '"'"'50%\n'"'"'; printf "%s" "$v"' "$SKILL_DIR")" 'a b*/50%\n'
eq "path_v_into_a_variable_named_like_a_parameter" "$(lib "$r" bash -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; _det_path_v d . x; _det_path_v name sub name; printf "%s|%s" "$d" "$name"' "$SKILL_DIR")" 'x|sub/name'
eq "path_v_matches_path_for_dot_and_subdir" "$(lib "$r" bash -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; a="$(_det_path . m)|$(_det_path "x y" m)"; _det_path_v p . m; _det_path_v q "x y" m; [ "$a" = "$p|$q" ] && echo same || echo "differ: $a vs $p|$q"' "$SKILL_DIR")" 'same'

# --- _det_line_starts: literal prefixes, raw lines
ls_() { printf '%b' "$1" > "$TMPROOT/ls-file"; shift; lib "$TMPROOT" _det_line_starts "$TMPROOT/ls-file" "$@" 2>/dev/null; echo $?; }
eq "line_starts_matches_the_second_prefix" "$(ls_ 'a\n[b]\n' '[x]' '[b]')" 0
eq "line_starts_wants_the_line_start" "$(ls_ 'a [b]\n' '[b]')" 1
eq "line_starts_prefix_is_literal_not_a_glob" "$(ls_ '[axx]\n' '[a*]')" 1
eq "line_starts_prefix_with_a_star_matches_itself" "$(ls_ 'z\n[a*]b\n' '[a*]')" 0
eq "line_starts_empty_file_is_no_match" "$(ls_ '' '[b]')" 1
eq "line_starts_unreadable_file_is_no_match_and_reported" "$( (. "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/detect.sh"; _det_line_starts "$TMPROOT/no-such-file" '[b]'; echo "rc=$?") 2>&1 | sed -e 's/.*No such file.*/stderr-line/' )" "$(printf 'stderr-line\nrc=1')"

# --- _det_langs_set / _det_langs: no process, same answer as 0.16.0
langs() { lib "$1" _det_langs "${2:-.}" | tr '\n' ' '; }
r="$(mkrepo)"; mkdir "$r/sub"
eq "langs_none" "$(langs "$r")" ""
for f in Cargo.toml pyproject.toml pubspec.yaml go.mod package.json init.lua; do mk "$r/sub/$f"; done
eq "langs_all_in_order" "$(langs "$r" sub)" "rust python flutter go node lua "
eq "langs_root_is_untouched_by_a_subdir" "$(langs "$r")" ""
got=""; for f in requirements.txt setup.py pytest.ini; do r="$(mkrepo)"; mk "$r/$f"; got="$got$(langs "$r")"; done
eq "langs_python_from_each_of_the_other_three_files" "$got" "python python python "
got=""; for f in .luarc.json .busted a.rockspec; do r="$(mkrepo)"; mk "$r/$f"; got="$got$(langs "$r")"; done
eq "langs_lua_from_each_of_the_other_three_files" "$got" "lua lua lua "
r="$(mkrepo)"; mk "$r/pyproject.toml"; mk "$r/requirements.txt"; mk "$r/pytest.ini"
eq "langs_python_is_listed_once" "$(langs "$r")" "python "
eq "langs_set_fills_an_array_and_clears_it_between_calls" "$(lib "$r" bash -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; _det_langs_set .; a="${#_DET_LANGS[@]}"; mkdir -p e; _det_langs_set e; echo "$a ${#_DET_LANGS[@]}"' "$SKILL_DIR")" "1 0"

# --- one jq per package.json per scan, not one per question
real_jq="$(command -v jq)"; jqdir="$TMPROOT/jq-count"; mkdir -p "$jqdir"
printf '#!/usr/bin/env bash\necho x >> "$JQ_COUNT_LOG"\nexec "%s" "$@"\n' "$real_jq" > "$jqdir/jq"; chmod +x "$jqdir/jq"
r="$(mkrepo)"; mk "$r/package.json" '{"scripts":{"test":"t","lint":"l"},"dependencies":{"react":"1"}}'; mk "$r/web/package.json" '{"scripts":{"test":"t"}}'
jq_calls() { # jq_calls <detect.sh function> <args>: how many jq processes the call starts
  local log="$TMPROOT/jq-count.log"; : > "$log"
  ( stub_path "$jqdir"; export JQ_COUNT_LOG="$log"; . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/detect.sh"; "$@" >/dev/null 2>&1 ); wc -l < "$log" | tr -d ' '
}
eq "oracle_runs_one_jq_per_package_json_plus_the_final_one" "$(jq_calls oracle_json "$r")" 3
eq "stack_runs_one_jq_per_package_json_plus_the_final_one" "$(jq_calls stack_json "$r" -)" 3

# --- the package.json helpers reset their answers on every call
eq "pkg_helpers_do_not_keep_the_last_files_answers" "$(lib "$TMPROOT" bash -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"
  printf "%s" "{\"scripts\":{\"test\":\"t\",\"lint\":\"l\"},\"dependencies\":{\"react\":1}}" > good.json; printf "%s" "[1]" > plain.json; printf "%s" "{bad" > bad.json
  _det_pkg_scripts good.json; a="$_DET_PKG_PARSED$_DET_PKG_TEST$_DET_PKG_LINT"; _det_pkg_scripts plain.json; b="$_DET_PKG_PARSED$_DET_PKG_TEST$_DET_PKG_LINT"; _det_pkg_scripts bad.json; c="$_DET_PKG_PARSED$_DET_PKG_TEST$_DET_PKG_LINT"
  _det_pkg_react good.json; d="$_DET_PKG_PARSED$_DET_PKG_REACT"; _det_pkg_react plain.json; e="$_DET_PKG_PARSED$_DET_PKG_REACT"; _det_pkg_react bad.json; f="$_DET_PKG_PARSED$_DET_PKG_REACT"
  echo "$a|$b|$c|$d|$e|$f"' "$SKILL_DIR")" "111|1||11|1|"

# --- failure modes
bash "$RITUAL" stack "$TMPROOT/not-a-repo-$$" >/dev/null 2>&1; eq "stack_refuses_non_repo" "$?" 2
bash "$RITUAL" oracle "$TMPROOT/not-a-repo-$$" >/dev/null 2>&1; eq "oracle_refuses_non_repo" "$?" 2
bash "$RITUAL" stack >/dev/null 2>&1; eq "stack_usage_error" "$?" 2
eq "stack_json_dies_when_repo_unscannable" "$( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/detect.sh"; (stack_json "$TMPROOT/does-not-exist") >/dev/null 2>&1; echo $?)" 2
eq "oracle_unknown_when_detection_cannot_run" \
  "$( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/detect.sh"; oracle_json "$TMPROOT/does-not-exist")" \
  '{"status":"unknown","test":[],"lint":[]}'

# --- per-line classification: pins that held on 0.16.0 (the awk/sed/grep form) and must keep holding
r="$(mkrepo)"; mkdir -p "$r/.github/workflows"; printf 'jobs:\r\n  t:\r\n    steps:\r\n      - run: cargo test\r\n      - run: |\r\n          cd sub\r\n          pytest -q\r\n' > "$r/.github/workflows/ci.yml"
eq "ci_crlf_workflow_lines_classified" "$(orc "$r" | jq -c '[.test[]|[.cmd,.source]]')" '[["cargo test",".github/workflows/ci.yml"],["cd sub && pytest -q",".github/workflows/ci.yml"]]'
r="$(mkrepo)"; printf '# T\r\n\r\n```sh\r\ncd app\r\n$ cargo test\r\n```\r\n' > "$r/README.md"
eq "readme_crlf_fence_lines_classified" "$(orc "$r" | jq -c '[.test[]|[.cmd,.source]]')" '[["cargo test","README.md"]]'
eq "ci_regex_chars_in_quotes" "$(ci_cmds "- run: cargo test -- 'a[1]*' && pytest")" "[\"cargo test -- 'a[1]*'\",\"pytest\"]"
eq "ci_bash_c_escaped_quotes" "$(ci_cmds '- run: bash -c "cd x && \"pytest\""')" '[]'
eq "ci_bash_c_dollar_unescaped_then_split" "$(ci_cmds '- run: bash -c "echo \$HOME; pytest"')" '["pytest"]'
eq "ci_tab_padded_segments_trimmed" "$(ci_cmds "- run: echo x ;$(printf '\t')pytest$(printf '\t') ; cargo clippy")" '["pytest"]'
eq "ci_keywords_and_env_prefix_stripped_in_a_row" "$(ci_cmds '- run: if ! RUST_LOG=1 FOO=2 cargo test')" '["cargo test"]'
eq "ci_quoted_space_env_value_is_not_stripped" "$(ci_cmds '- run: FOO="a b" cargo test')" '[]'
eq "ci_install_is_never_a_test" "$(ci_cmds '- run: pip install pytest && npm i && cargo install cargo-nextest')" '[]'
eq "ci_runner_must_end_at_a_word_boundary" "$(ci_cmds '- run: pytestx && cargo testing && cargo test')" '["cargo test"]'

# --- the in-process forms: set a variable, no process per call
v() { # v <fn> <args>...: runs "<fn> out <args>" and prints "<rc>|<out>"
  ( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/detect.sh"; local fn="$1" out=UNSET rc; shift; "$fn" out "$@"; rc=$?; printf '%s|%s' "$rc" "$out" )
}
eq "classify_v_test" "$(v _det_classify_v 'cargo test --all')" '0|test'
eq "classify_v_test_at_end_of_string" "$(v _det_classify_v pytest)" '0|test'
eq "classify_v_lint" "$(v _det_classify_v 'cargo clippy -- -D warnings')" '0|lint'
eq "classify_v_none" "$(v _det_classify_v 'make build')" '0|none'
eq "classify_v_install_is_none" "$(v _det_classify_v 'npm install')" '0|none'
eq "classify_v_echo_is_none" "$(v _det_classify_v 'echo cargo test')" '0|none'
eq "classify_v_word_boundary" "$(v _det_classify_v 'pytestx')" '0|none'
eq "classify_v_regex_chars_are_data" "$(v _det_classify_v "cargo test -- 'a[1]*'")" '0|test'
eq "classify_v_empty_is_none" "$(v _det_classify_v '')" '0|none'
eq "shell_c_v_dquoted" "$(v _det_shell_c_v 'bash -c "cd x && pytest"')" '0|cd x && pytest'
eq "shell_c_v_squoted" "$(v _det_shell_c_v "sh -ec 'pytest -k a'")" '0|pytest -k a'
eq "shell_c_v_bare_word" "$(v _det_shell_c_v 'bash -c pytest')" '0|pytest'
eq "shell_c_v_unescapes_left_to_right" "$(v _det_shell_c_v 'bash -c "a\\\"b\$c\`d\e\\"')" '0|a\"b$c`d\e\'
eq "shell_c_v_empty_script" "$(v _det_shell_c_v 'bash -c ""')" '0|'
eq "shell_c_v_not_a_shell_returns_1" "$(v _det_shell_c_v 'cargo test')" '1|UNSET'
eq "shell_c_v_two_words_returns_1" "$(v _det_shell_c_v 'bash -c pytest -q')" '1|UNSET'
eq "shell_c_v_unescaped_quote_inside_returns_1" "$(v _det_shell_c_v 'bash -c "a"b"')" '1|UNSET'
eq "shell_c_v_quote_inside_squotes_returns_1" "$(v _det_shell_c_v "bash -c 'a'b'")" '1|UNSET'
eq "shell_c_v_no_script_returns_1" "$(v _det_shell_c_v 'bash -c')" '1|UNSET'
eq "split_into_escaped_dquote_stays_inside_the_string" "$(split_segs 'echo "a\"; b" ; c')" 'n=2[echo "a\"; b" ][ c]'
eq "split_into_empty_line_is_one_empty_segment" "$(split_segs '')" 'n=1[]'
eq "split_into_trailing_separator_keeps_empty_tail" "$(split_segs 'a;')" 'n=2[a][]'
eq "split_into_lone_ampersand_and_trailing_backslash" "$(split_segs 'a & b\')" 'n=1[a & b\]'
eq "split_into_unterminated_quote_runs_to_end" "$(split_segs "a; b 'c; d")" "n=2[a][ b 'c; d]"

# --- non-ASCII command text classifies as 0.16.0 did, in every locale (final review I1)
# On Git Bash, bash's [[ =~ ]] and the GNU grep/sed 0.16.0 asked disagree about whether an accented
# letter sits inside [A-Za-z0-9] under a locale such as en_GB.UTF-8, and about a lone 0xA0 byte being
# [[:space:]] under C. So a line holding a byte >= 0x80 still goes to grep and sed. The oracle below
# calls grep -E and sed -E directly, in the locale under test, on one plain command line.
ref_class() { # ref_class <line> <source>: the TSV _det_classify_stream prints for one simple line, made by grep and sed
  local stripped kind
  stripped="$(printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | sed -E 's/^((if|then|else|elif|while|until|!)[[:space:]]+)+//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+//')"
  if printf '%s' "$stripped" | grep -Eq "$_DET_NEVER"; then kind=none
  elif printf '%s' "$stripped" | grep -Eq "$_DET_TEST_RE"; then kind=test
  elif printf '%s' "$stripped" | grep -Eq "$_DET_LINT_RE"; then kind=lint
  else kind=none; fi
  case "$kind" in test|lint) printf '%s\t.\t%s\t%s\n' "$kind" "$stripped" "$2" ;; esac
}
I1_LINES=(
  'npm run test:intégration' 'make test-intégration' 'FOOé=1 cargo test' 'npm run lint:é'
  'yarn testñ' 'just testé' 'npm run test:ß' 'npm run test:É' 'npm run test:²' 'FOO²=1 cargo test'
  'pnpm run lint:ñ' 'cargo test é' 'then cargo test ñ' 'if ! pytest é' 'make lint-é' 'just check é'
  'npm run test:unit' 'FOO=1 cargo test' 'make test-unit'
  'bash -c "npm run test:é"' 'bash -c "FOOé=1 pytest"'
)
printf -v nb 'eslint\xa0.';       I1_LINES+=("$nb")      # a lone Latin-1 NBSP: [[:space:]] to bash under C, not to grep
printf -v nb 'npm run test:\xff'; I1_LINES+=("$nb")      # invalid UTF-8
printf -v nb 'FOO\xe9=1 cargo test'; I1_LINES+=("$nb")   # a Latin-1 e-acute byte
printf -v nb 'cargo\xa0test';     I1_LINES+=("$nb")
i1_locs=0; i1_utf8=0
for loc in C C.UTF-8 en_GB.UTF-8 en_US.UTF-8 pt_PT.UTF-8; do
  have_locale "$loc" || continue
  i1_locs=$((i1_locs + 1)); [ "$loc" = C ] || i1_utf8=$((i1_utf8 + 1))
  mism="$( export LC_ALL="$loc"; . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/detect.sh"
    for ln in "${I1_LINES[@]}"; do
      got="$(printf '%s\n' "$ln" | _det_classify_stream src; echo x)"
      case "$ln" in
        bash\ -c\ *) inner="${ln#bash -c \"}"; inner="${inner%\"}"; want="$(ref_class "$inner" src; echo x)" ;;
        *) want="$(ref_class "$ln" src; echo x)" ;;
      esac
      [ "$got" = "$want" ] || printf '[%s] got %s want %s; ' "$ln" "$(printf %s "${got%x}" | tr '\t\n' '  ')" "$(printf %s "${want%x}" | tr '\t\n' '  ')"
    done )"
  [ -z "$mism" ] && ok "classify_non_ascii_matches_grep_and_sed_$loc" || bad "classify_non_ascii_$loc: $mism"
  # end to end: a CI step with an accented script name is a test exactly when grep says so
  r="$(mkrepo)"; mkdir -p "$r/.github/workflows"; printf 'jobs:\n  t:\n    steps:\n      - run: npm run test:intégration\n' > "$r/.github/workflows/ci.yml"
  want=absent; ( export LC_ALL="$loc"; . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/detect.sh"; printf '%s' 'npm run test:intégration' | grep -Eq "$_DET_TEST_RE" ) && want=present
  got="$(LC_ALL="$loc" bash "$RITUAL" oracle "$r" | jq -r .status)"
  eq "oracle_non_ascii_ci_step_matches_grep_$loc" "$got" "$want"
done
# the guard: with none of the UTF-8 locales installed the pins above would only have run under C
[ "$i1_utf8" -ge 1 ] && ok "non_ascii_pins_ran_under_a_utf8_locale ($i1_locs locales, $i1_utf8 UTF-8)" || bad "no UTF-8 locale from C.UTF-8 en_GB.UTF-8 en_US.UTF-8 pt_PT.UTF-8 is installed (locale -a): the non-ASCII classification pins did not run"
# ASCII lines keep the bash path: no grep, sed or awk process for a plain command line
cat > "$TMPROOT/ascii-trace.sh" <<'TRACE'
. "$1/lib/common.sh"; . "$1/lib/detect.sh"
printf '%s\n' 'cd app && npm run test:unit; FOO=1 cargo test | tee x' 'then pytest -q' | _det_classify_stream src
TRACE
mkdir -p "$TMPROOT/ptrace"; for t in grep sed awk; do printf '#!/usr/bin/env bash\necho %s >> "%s"\nexec "%s" "$@"\n' "$t" "$TMPROOT/ptrace.log" "$(command -v $t)" > "$TMPROOT/ptrace/$t"; chmod +x "$TMPROOT/ptrace/$t"; done
: > "$TMPROOT/ptrace.log"; got="$(PATH="$TMPROOT/ptrace:$PATH" bash "$TMPROOT/ascii-trace.sh" "$SKILL_DIR")"
eq "ascii_lines_spawn_no_grep_sed_or_awk" "$(wc -l < "$TMPROOT/ptrace.log" | tr -d ' ')|$(printf '%s\n' "$got" | wc -l | tr -d ' ')" '0|3'
printf -v nb 'npm run test:\xc3\xa9'
printf '%s\n' "$nb" > "$TMPROOT/nonascii.txt"
: > "$TMPROOT/ptrace.log"; PATH="$TMPROOT/ptrace:$PATH" bash -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; _det_classify_stream src < "$1"' "$SKILL_DIR" "$TMPROOT/nonascii.txt" >/dev/null
eq "non_ascii_line_is_decided_by_grep" "$([ -s "$TMPROOT/ptrace.log" ] && echo spawned || echo none)" spawned


# --- a byte that is not valid UTF-8 just before a LF (a Latin-1 e-acute ending a comment): grep and awk
# still see two lines, and so must the bash read loops that replaced them (they read under LC_ALL=C).
# Without that, bash `read` in a UTF-8 locale ran the comment and the next line together and missed the
# header. Pinned from 0.16.0, run under every UTF-8 locale `locale -a` lists plus C (fix round 2).
l1_utf8=0
for loc in C C.UTF-8 en_GB.UTF-8 en_US.UTF-8 pt_PT.UTF-8; do
  have_locale "$loc" || continue
  [ "$loc" = C ] || l1_utf8=$((l1_utf8 + 1))
  r="$(mkrepo)"; printf '# Jos\xe9\n[tool.ruff]\n' > "$r/pyproject.toml"; printf '# Jos\xe9\n[lints.clippy]\n' > "$r/Cargo.toml"
  eq "latin1_before_lf_line_starts_$loc" "$(LC_ALL=$loc bash "$RITUAL" oracle "$r" 2>/dev/null | jq -c '[.lint[].cmd]')" '["cargo clippy --all-targets -- -D warnings","ruff check"]'
  r="$(mkrepo)"; printf '# Jos\xe9\n[workspace]\nmembers = ["crates/a"]\n' > "$r/Cargo.toml"; mk "$r/crates/a/Cargo.toml" '[package]'
  eq "latin1_before_lf_ws_has_table_$loc" "$(LC_ALL=$loc bash "$RITUAL" stack "$r" 2>/dev/null | jq -c '[.stacks[].dir]')" '[".","crates/a"]'
done
[ "$l1_utf8" -ge 1 ] && ok "latin1_before_lf_pins_ran_under_a_utf8_locale ($l1_utf8 UTF-8)" || bad "no UTF-8 locale from C.UTF-8 en_GB.UTF-8 en_US.UTF-8 pt_PT.UTF-8 is installed (locale -a): the Latin-1-before-LF pins did not run"

finish
