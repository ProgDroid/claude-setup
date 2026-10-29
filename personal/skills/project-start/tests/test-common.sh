#!/usr/bin/env bash
# Tests for lib/common.sh and the tests/lib.sh helpers later tasks depend on.
. "$(dirname "$0")/lib.sh"
. "$SKILL_DIR/lib/common.sh"
. "$SKILL_DIR/lib/ledger.sh"   # emit_already applies the ledger's rerun rule

echo "== steps.json =="
sj="$(steps_json)"
[ -f "$sj" ] && ok "steps_json names an existing file" || bad "steps_json: $sj"
exp='preflight beads stack lessons traps stack-checks oracle public-sweep secret-scan workspace untracked-docs parking-lot beads-seed beads-metrics ci baseline handoff commit record'
[ "$(jq -r '.steps|map(.id)|join(" ")' "$sj")" = "$exp" ] && ok "19 step ids in spec order" || bad "ids: $(jq -r '.steps|map(.id)|join(" ")' "$sj")"
[ "$(jq -c '[.steps[].version]|unique' "$sj")" = '[1]' ] && [ "$(jq .ritual_version "$sj")" = 1 ] && ok "all versions 1, ritual_version 1" || bad "versions"
[ "$(jq -r '.steps[]|select(.id=="stack-checks")|.kind' "$sj")" = ask ] && [ "$(jq -r '.steps[]|select(.id=="preflight")|.kind' "$sj")" = check ] \
  && [ "$(jq -r '.steps[]|select(.id=="oracle")|.kind' "$sj")" = auto ] && ok "kinds follow the spec table" || bad "kinds"
[ "$(jq -c '.steps|map(select(.id=="parking-lot"))|.[0]|[.kind,.version]' "$sj")" = '["auto",1]' ] && ok "parking-lot is kind auto, version 1" || bad "parking-lot kind/version"
[ "$(RITUAL_STEPS_JSON=/x/y steps_json)" = /x/y ] && ok "RITUAL_STEPS_JSON overrides" || bad "override ignored"

echo "== emit =="
e="$(emit traps present "added 2 lines" .gitignore .gitattributes)"
[ "$(printf '%s' "$e" | jq -c .)" = '{"id":"traps","status":"present","detail":"added 2 lines","wrote":[".gitignore",".gitattributes"]}' ] \
  && ok "emit with wrote paths" || bad "emit: $e"
[ "$(emit oracle unknown "no tool" | jq -c .wrote)" = '[]' ] && ok "emit with no wrote gives []" || bad "emit empty wrote"
[ "$(emit x absent 'a "quoted" b' | jq -r .detail)" = 'a "quoted" b' ] && ok "emit escapes quotes" || bad "emit quoting"
# (built with printf -v: a $'...' string inside "$(...)" loses its CR under Git Bash)
printf -v crs 'a\r\nb\\c\037'
[ "$(emit x absent "$crs" | jq -c .detail)" = '"a\r\nb\\c\u001f"' ] && ok "emit_keeps_cr_and_control_bytes_in_detail" || bad "emit CR: $(emit x absent "$crs" | jq -c .detail)"
[ "$(emit x absent d "" "a b" | jq -c .wrote)" = '["","a b"]' ] && ok "emit_keeps_empty_and_spaced_wrote_elements" || bad "emit empty element"
# the argv limit: jq.exe is a native Windows program (~32 KB command line). A 60 KB detail and
# 2000 spaced paths must come back exactly, or every step that reports them prints nothing.
big="$(printf 'chunk "q" \\ é %04d; ' $(seq 1 3000))"; big="${big:0:61440}"
mapfile -t paths < <(seq 1 2000 | sed 's|^|some dir/file |; s|$|.txt|')
e="$(emit untracked-docs present "$big" "${paths[@]}")"
printf '%s' "$big" > "$TMPROOT/big.exp"; printf '%s' "$e" | jq -j .detail > "$TMPROOT/big.got" 2>/dev/null
printf '%s\n' "${paths[@]}" > "$TMPROOT/paths.exp"; printf '%s' "$e" | jq -r '.wrote[]' 2>/dev/null | tr -d '\r' > "$TMPROOT/paths.got"
[ "${#big}" -ge 60000 ] && [ "${#paths[@]}" = 2000 ] && cmp -s "$TMPROOT/big.exp" "$TMPROOT/big.got" && cmp -s "$TMPROOT/paths.exp" "$TMPROOT/paths.got" \
  && ok "emit_large_detail_and_wrote" || bad "emit large: detail ${#big} chars, emitted $(printf '%s' "$e" | wc -c) bytes"

echo "== emit fast path =="
# emit_old: 0.16.0's emit (22fc3d7 lib/common.sh), the oracle for byte-for-byte comparison.
emit_old() {
  local id="$1" status="$2" detail="$3"; shift 3
  { printf '%s' "$detail" | base64; printf '.\n'; [ $# -eq 0 ] || printf '%s\x1e' "$@" | base64; } \
    | jq -nRc --arg id "$id" --arg s "$status" '[inputs] as $l | ($l | index(".")) as $i
      | ($l[:$i] | add // "" | @base64d) as $d
      | ($l[$i + 1:] | add // "" | @base64d | split("\u001e") | .[:-1]) as $w
      | {id:$id, status:$s, detail:$d, wrote:$w}' || die "emit: jq could not build the $id result"
}
# a jq that logs each call, then runs the real one: a fast-path emit must not call it, a slow one must
REALJQ="$(command -v jq)"; JQSTUB="$TMPROOT/jqstub"; mkdir -p "$JQSTUB"; export JQ_CALLS="$TMPROOT/jqcalls"
printf '#!/usr/bin/env bash\necho x >> "$JQ_CALLS"\nexec "%s" "$@"\n' "$REALJQ" > "$JQSTUB/jq"; chmod +x "$JQSTUB/jq"
_ritual_jq_eol 2>/dev/null   # probe now (a no-op where the function does not exist): the cases below run in subshells
# ecase <fast|slow> <name> <emit args...>: emit prints exactly what emit_old prints (bytes and exit
# code), and went through jq only when it was not a plain result.
ecase() {
  local kind="$1" name="$2" rcn rco calls; shift 2
  : > "$JQ_CALLS"; ( PATH="$JQSTUB:$PATH"; emit "$@" ) > "$TMPROOT/em.new" 2>/dev/null; rcn=$?
  calls="$(wc -l < "$JQ_CALLS" | tr -d ' ')"
  ( emit_old "$@" ) > "$TMPROOT/em.old" 2>/dev/null; rco=$?
  if ! cmp -s "$TMPROOT/em.new" "$TMPROOT/em.old" || [ "$rcn" != "$rco" ]; then
    bad "emit_${kind}_$name: differs from emit_old (rc $rcn/$rco): $(od -c "$TMPROOT/em.new" | head -3) vs $(od -c "$TMPROOT/em.old" | head -3)"
  elif [ "$kind" = fast ] && [ "$calls" != 0 ]; then bad "emit_${kind}_$name: ran jq $calls times"
  elif [ "$kind" = slow ] && [ "$calls" = 0 ]; then bad "emit_${kind}_$name: never ran jq"
  else ok "emit_${kind}_$name"; fi
}
ecase fast plain traps present "added 2 lines" .gitignore .gitattributes
ecase fast quotes_backslash x absent 'a "quoted" b\c\\d\"' 'p"q' 'r\s'
printf -v tnd 'a\tb\nc\n\n\td'
ecase fast tab_newline_detail x present "$tnd" $'p\tq' $'r\ns'
ecase fast no_paths oracle unknown "no tool"
many=(); for i in $(seq 1 60); do many+=("dir $i/file $i.txt"); done
ecase fast many_paths untracked-docs present "found 60" "${many[@]}"
ecase fast path_with_space x present d "some dir/with space.txt"
ecase fast empty_detail_and_empty_path x absent "" "" "a b" ""
ecase fast space_and_tilde_edges x absent ' ~ !}  ' ' ' '~'
printf -v nad 'caf\xc3\xa9'
ecase slow non_ascii_detail x absent "$nad"
printf -v cb 'a\x01b'
ecase slow control_byte x absent "$cb"
printf -v iu 'a\xffb'
ecase slow invalid_utf8 x absent "$iu"
printf -v dl 'a\x7fb'
ecase slow del_char x absent "$dl"
printf -v crd 'a\rb'
ecase slow cr_in_detail x absent "$crd"
ecase slow non_ascii_path x present d ok.txt "$nad.txt"
printf -v rsp 'a\x1eb'
ecase slow record_separator_in_path x present d ok.txt "$rsp"
printf -v hi 'a\xc3\xa9\xe2\x82\xac'
ecase slow non_ascii_in_id "$nad" absent d
# a locale-following byte test (a [[:print:]] class, a collating range) would let a multibyte
# character through under a UTF-8 locale: run the byte test in the locale it is called in
ul_ok=1; ul_n=0
for loc in C.UTF-8 en_US.UTF-8; do
  have_locale "$loc" || continue   # an absent locale falls back to C: it proves nothing, so it is not counted
  ul_n=$((ul_n + 1))
  for v in "$nad" "$hi" "$iu"; do
    : > "$JQ_CALLS"; ( LC_ALL=$loc; PATH="$JQSTUB:$PATH"; emit x absent "$v" "p$v" ) > "$TMPROOT/em.new" 2>/dev/null
    ( LC_ALL=$loc; emit_old x absent "$v" "p$v" ) > "$TMPROOT/em.old" 2>/dev/null
    cmp -s "$TMPROOT/em.new" "$TMPROOT/em.old" && [ -s "$JQ_CALLS" ] || ul_ok=0
  done
done
[ "$ul_ok" = 1 ] && [ "$ul_n" -ge 1 ] && ok "emit_slow_non_ascii_detail_utf8_locale" || bad "emit utf8 locale: fast path taken or output differs, or no UTF-8 locale is installed (ran under $ul_n)"

# On a terminal 0.16.0's jq coloured the object, so a plain result is built here only when stdout
# (fd 1, which is what jq wrote to) is not one. A pipe cannot be a terminal: a stand-in for `[`
# answers `-t N` for one descriptor, and the call must go through jq exactly when that is fd 1.
tty_case() { # tty_case <fd the stand-in calls a terminal> <fast|slow>
  local fd="$1" kind="$2" calls
  : > "$JQ_CALLS"
  ( function [ { case "${1-}${2-}${3-}" in "!-t$fd") return 1 ;; esac; builtin [ "$@"; }
    PATH="$JQSTUB:$PATH"; emit x absent d p ) > "$TMPROOT/em.new" 2>/dev/null
  calls="$(wc -l < "$JQ_CALLS" | tr -d ' ')"
  ( emit_old x absent d p ) > "$TMPROOT/em.old" 2>/dev/null
  if ! cmp -s "$TMPROOT/em.new" "$TMPROOT/em.old"; then bad "emit_tty_fd$fd: differs from emit_old"
  elif [ "$kind" = slow ] && [ "$calls" = 0 ]; then bad "emit_tty_fd$fd: built the object itself on a terminal"
  elif [ "$kind" = fast ] && [ "$calls" != 0 ]; then bad "emit_tty_fd$fd: ran jq $calls times"
  else ok "emit_tty_fd${fd}_${kind}"; fi
}
tty_case 1 slow
tty_case 2 fast

# _ritual_jq_eol reads jq's own line ending from one probe call
for eol in real lf crlf; do
  rm -rf "$TMPROOT/eolstub"; mkdir -p "$TMPROOT/eolstub"
  case "$eol" in
    lf)   printf '#!/usr/bin/env bash\nprintf "1\\n"\n' > "$TMPROOT/eolstub/jq"; want=$'\n' ;;
    crlf) printf '#!/usr/bin/env bash\nprintf "1\\r\\n"\n' > "$TMPROOT/eolstub/jq"; want=$'\r\n' ;;
    real) [ "$(jq -nc 1 | wc -c | tr -d ' ')" = 3 ] && want=$'\r\n' || want=$'\n' ;;
  esac
  [ "$eol" = real ] || chmod +x "$TMPROOT/eolstub/jq"
  got="$( [ "$eol" = real ] || PATH="$TMPROOT/eolstub:$PATH"; unset _RITUAL_JQ_EOL; _ritual_jq_eol; printf '%s|' "$_RITUAL_JQ_EOL" | od -An -c | tr -d ' ' )"
  exp="$(printf '%s|' "$want" | od -An -c | tr -d ' ')"
  [ "$got" = "$exp" ] && ok "jq_eol_probe_$eol" || bad "jq_eol_probe_$eol: got $got, want $exp"
done

# emit probes lazily, once per shell; a preset global means no probe at all
: > "$TMPROOT/eol.trace"
( export RITUAL_TRACE="$TMPROOT/eol.trace"; unset _RITUAL_JQ_EOL; emit a b c >/dev/null; emit a b c >/dev/null; emit a b d p >/dev/null )
[ "$(grep -c '^jq_eol_probe$' "$TMPROOT/eol.trace")" = 1 ] && ok "emit_probes_jq_eol_lazily_once" || bad "emit probes: $(tr '\n' ' ' < "$TMPROOT/eol.trace")"
: > "$TMPROOT/eol.trace"
( export RITUAL_TRACE="$TMPROOT/eol.trace"; _RITUAL_JQ_EOL=$'\n'; emit a b c >/dev/null; emit a b c >/dev/null )
[ ! -s "$TMPROOT/eol.trace" ] && ok "emit_does_not_probe_when_jq_eol_is_set" || bad "emit probed with the global set: $(tr '\n' ' ' < "$TMPROOT/eol.trace")"
# auto probes once up front, so the step subshells inherit it instead of probing each
: > "$TMPROOT/eol.trace"; rep="$(mkrepo)"
RITUAL_TRACE="$TMPROOT/eol.trace" bash "$RITUAL" auto "$rep" >/dev/null 2>&1
[ "$(grep -c '^jq_eol_probe$' "$TMPROOT/eol.trace")" = 1 ] && ok "auto_probes_jq_eol_once_for_all_steps" || bad "auto probes: $(grep -c '^jq_eol_probe$' "$TMPROOT/eol.trace") (want 1)"

# an exported _RITUAL_JQ_EOL or _RITUAL_LG_* never reaches a standalone step (0.16.0 had neither)
rep="$(mkrepo)"; bash "$RITUAL" fix traps "$rep" >/dev/null 2>&1   # leaves .gitignore, .gitattributes uncommitted
for sub in "fix traps" "check traps"; do
  clean="$(bash "$RITUAL" $sub "$rep" 2>&1)"
  dirty="$(_RITUAL_JQ_EOL=XX _RITUAL_LG_REPO="$rep" _RITUAL_LG_TOP="$TMPROOT/nowhere" _RITUAL_LG_FILE="$TMPROOT/nowhere/l.json" _RITUAL_LG_WT=/x bash "$RITUAL" $sub "$rep" 2>&1)"
  [ -n "$clean" ] && [ "$clean" = "$dirty" ] && ok "inherited_ritual_globals_are_ignored_${sub// /_}" || bad "inherited globals changed '$sub': [$clean] vs [$dirty]"
done
# (the `fix` run above reaches the ledger through emit_already, so a wrong _RITUAL_LG_TOP would show as unknown)
case "$(bash "$RITUAL" fix traps "$rep" 2>&1)" in *'not yet committed'*) ok "inherited_globals_test_reaches_the_ledger" ;; *) bad "fix traps never reached the ledger: $(bash "$RITUAL" fix traps "$rep" 2>&1)" ;; esac

# ritual_trace writes one line per event, to the file named by RITUAL_TRACE
: > "$TMPROOT/rt.trace"; RITUAL_TRACE="$TMPROOT/rt.trace" ritual_trace one; RITUAL_TRACE="$TMPROOT/rt.trace" ritual_trace 'two words'
[ "$(od -An -c "$TMPROOT/rt.trace" | tr -d ' \n')" = 'one\ntwowords\n' ] && ok "ritual_trace_appends_name_and_newline" || bad "ritual_trace: $(od -c "$TMPROOT/rt.trace" | head -3)"
[ "$(grep -cF "printf '%s\\n' \"\$1\" >> \"\$RITUAL_TRACE\"" "$SKILL_DIR/lib/common.sh")" = 1 ] && ok "ritual_trace_format_is_one_line" || bad "ritual_trace's printf format is not '%s\n' on one line"

echo "== md_fence =="
# fence_mask <line...> -> one char per line: F = fence or inside one, . = could be a heading
fence_mask() { local l m=""; MD_FENCE=""; for l in "$@"; do if md_fence "$l"; then m+=F; else m+=.; fi; done; printf '%s' "$m"; }
[ "$(fence_mask '## a' '```' '## b' '```' '## c')" = '.FFF.' ] && ok "md_fence_backtick_block" || bad "backtick: $(fence_mask '## a' '```' '## b' '```' '## c')"
[ "$(fence_mask '~~~md' '## b' '```' '~~~~' '## c')" = 'FFFF.' ] && ok "md_fence_tilde_block_not_closed_by_backticks" || bad "tilde: $(fence_mask '~~~md' '## b' '```' '~~~~' '## c')"
[ "$(fence_mask '    ```' '## b')" = '..' ] && ok "md_fence_four_space_indent_is_not_a_fence" || bad "indent: $(fence_mask '    ```' '## b')"
[ "$(fence_mask $'```\r' $'## b\r' $'```\r' $'## c\r')" = 'FFF.' ] && ok "md_fence_crlf_lines" || bad "crlf fence"

echo "== git_common_dir =="
repo="$(mkrepo)"
g="$(git_common_dir "$repo")"
[ -d "$g" ] && [ "$(basename "$g")" = .git ] && ok "git_common_dir is the absolute .git of a spaced repo" || bad "git_common_dir: $g"

echo "== pending_paths =="
# pp <repo> <path>... -> what pending_paths printed (NUL-separated), one path per line, sorted
pp() { pending_paths "$@" | tr '\0' '\n' | LC_ALL=C sort | paste -sd'|' -; }
r="$(mkrepo pend)"
printf 'ign.txt\n' > "$r/.gitignore"
for f in tracked kept gone staged moved; do echo "$f" > "$r/$f.txt"; done
git -C "$r" add -A; git -C "$r" commit -q -m files
echo more >> "$r/tracked.txt"; rm "$r/gone.txt"; echo s2 >> "$r/staged.txt"; git -C "$r" add staged.txt
git -C "$r" mv moved.txt "re named.txt"
mkdir -p "$r/sub dir"; echo n > "$r/sub dir/new file.txt"; echo i > "$r/ign.txt"
got="$(pp "$r" tracked.txt kept.txt gone.txt staged.txt moved.txt "re named.txt" "sub dir" ign.txt missing.txt)"
[ "$got" = "gone.txt|moved.txt|re named.txt|staged.txt|sub dir/new file.txt|tracked.txt" ] \
  && ok "pending_paths_lists_modified_deleted_staged_renamed_and_untracked_files_only" || bad "pending_paths_lists_modified_deleted_staged_renamed_and_untracked_files_only: [$got]"
# never a name pattern: '*.txt' is a literal path here (a glob would match six files), and an
# ignored file is not pending even when named
got="$(pp "$r" '*.txt' ign.txt)"
[ -z "$got" ] && ok "pending_paths_takes_paths_literally_and_skips_ignored" || bad "pending_paths_takes_paths_literally_and_skips_ignored: [$got]"
pending_paths "$r" > "$TMPROOT/pp-none.out"; rc=$?
[ "$rc" = 0 ] && [ ! -s "$TMPROOT/pp-none.out" ] && ok "pending_paths_with_no_paths_prints_nothing_never_every_change" \
  || bad "pending_paths_with_no_paths_prints_nothing_never_every_change: rc=$rc [$(tr '\0' '|' < "$TMPROOT/pp-none.out")]"
c="$(mkrepo pend-clean)"; pending_paths "$c" README.md > "$TMPROOT/pp-clean.out"; rc=$?
[ "$rc" = 0 ] && [ ! -s "$TMPROOT/pp-clean.out" ] && ok "pending_paths_committed_path_prints_nothing" || bad "pending_paths_committed_path_prints_nothing: rc=$rc"
u="$TMPROOT/ritual fixtures/pend unborn"; mkdir -p "$u"; git -C "$u" init -q; echo a > "$u/a b.txt"
[ "$(pp "$u" "a b.txt")" = "a b.txt" ] && ok "pending_paths_on_an_unborn_branch_lists_the_untracked_file" || bad "pending_paths unborn: [$(pp "$u" "a b.txt")]"
mkdir -p "$TMPROOT/pend not a repo"
pending_paths "$TMPROOT/pend not a repo" x > "$TMPROOT/pp-ng.out" 2>/dev/null; rc=$?
[ "$rc" != 0 ] && [ ! -s "$TMPROOT/pp-ng.out" ] && ok "pending_paths_fails_when_git_cannot_answer" || bad "pending_paths_fails_when_git_cannot_answer: rc=$rc"

echo "== emit_already: paths with no ledger entry =="
# an untracked path with no entry is offered, also when the ledger exists and holds other entries
r="$(mkrepo already-none)"
echo o > "$r/other.txt"; ledger_mark_shown "$r" other.txt
echo x > "$r/.gitignore"
e="$(emit_already traps "$r" "nothing to add" .gitattributes .gitignore | tr -d '\r')"
lf="$(git -C "$r" rev-parse --path-format=absolute --git-common-dir | tr -d '\r')/ritual-ledger.json"
[ -f "$lf" ] && [ "$(jq -c '[.status, .wrote, .detail]' <<<"$e")" = '["already",[".gitignore"],"nothing to add; not yet committed: .gitignore"]' ] \
  && ok "verdict_none_untracked_offer" || bad "verdict_none_untracked_offer: ledger [$(cat "$lf" 2>&1)] $e"
# a repo from before 0.16 (no ledger file): the untracked issues export an older run left is offered
r="$(mkrepo already-pre016)"
mkdir -p "$r/.beads"; echo '{"id":"p-1"}' > "$r/.beads/issues.jsonl"
e="$(emit_already --skip-tracked .beads/issues.jsonl beads "$r" "house beads setup already holds" .beads AGENTS.md | tr -d '\r')"
lf="$(git -C "$r" rev-parse --path-format=absolute --git-common-dir | tr -d '\r')/ritual-ledger.json"
[ ! -e "$lf" ] && [ "$(jq -c '[.status, .wrote, .detail]' <<<"$e")" = '["already",[".beads/issues.jsonl"],"house beads setup already holds; not yet committed: .beads/issues.jsonl"]' ] \
  && ok "pre016_untracked_issues_jsonl_offered" || bad "pre016_untracked_issues_jsonl_offered: $e"

echo "== tests/lib.sh helpers =="
[ -d "$TMPROOT" ] && ok "TMPROOT exists" || bad "no TMPROOT"
a="$(mkrepo x)"; b="$(mkrepo x)"
[ "$a" != "$b" ] && [ "$(git -C "$a" rev-list --count HEAD)" = 1 ] && ok "mkrepo: unique paths, one commit" || bad "mkrepo uniqueness"
mkdir "$TMPROOT/stubs"; printf '#!/usr/bin/env bash\necho STUB\n' > "$TMPROOT/stubs/fakegh"; chmod +x "$TMPROOT/stubs/fakegh"
[ "$( stub_path "$TMPROOT/stubs"; fakegh )" = STUB ] && ok "stub_path makes a stub runnable" || bad "stub_path"
command -v fakegh >/dev/null 2>&1 && bad "stub_path leaked (subshell test)" || ok "stub_path in a subshell does not leak"
[ "$( stub_path "$TMPROOT/stubs"; PATH="$(path_without fakegh)"; command -v fakegh || echo GONE )" = GONE ] \
  && ok "path_without removes the dir holding a tool" || bad "path_without"
[ "$(path_without definitely-not-a-tool-xyz)" = "$PATH" ] && ok "path_without an absent tool leaves PATH unchanged" || bad "path_without absent"
[ "$(PATH="/usr/bin::/bin:*:" path_without definitely-not-a-tool-xyz)" = "/usr/bin::/bin:*:" ] \
  && ok "path_without keeps empty segments and glob chars byte-identical" || bad "path_without mangled PATH"

echo "== append_lines =="
# al_case <name> <initial printf-format | MISSING> <line>...: same bytes as one append_line per line.
al_case() {
  local name="$1" init="$2" a b l
  shift 2
  a="$TMPROOT/al-$name.a"; b="$TMPROOT/al-$name.b"; rm -f "$a" "$b"
  if [ "$init" != MISSING ]; then printf "$init" > "$a"; printf "$init" > "$b"; fi
  for l in "$@"; do append_line "$a" "$l"; done
  append_lines "$b" "$@"
  if { [ -e "$a" ] && [ -e "$b" ] && cmp -s "$a" "$b"; } || { [ ! -e "$a" ] && [ ! -e "$b" ]; }; then
    ok "append_lines_matches_append_line_$name"
  else
    bad "append_lines_matches_append_line_$name: want $(od -c "$a" 2>&1 | head -3) got $(od -c "$b" 2>&1 | head -3)"
  fi
}
al_case lf 'x\ny\n' a b c
al_case crlf 'x\r\ny\r\n' a b c
al_case no_trailing_newline 'x\ny' a b
al_case crlf_no_trailing_newline 'x\r\ny' a b
al_case cr_no_newline 'x\r' a b
al_case crlf_first_line_lf_last 'x\r\ny\nz\n' a b
al_case lf_first_line_crlf_last 'x\ny\r\n' a b
al_case empty_file '' a b
al_case missing_file MISSING a b
al_case blank_lines_in_list 'x\r\n' '' a '' '' b ''
al_case single_line 'x\n' a
al_case first_appended_line_ends_in_cr_on_empty_file '' $'x\r' b c
al_case first_appended_line_ends_in_cr_on_unterminated_single_line 'q' $'x\r' b c
al_case no_lines_unterminated 'x\ny'
al_case no_lines_missing_file MISSING
al_case no_lines_empty_file ''
printf 'x\r' > "$TMPROOT/al-lit"; append_lines "$TMPROOT/al-lit" a b
printf 'x\r\na\nb\r\n' > "$TMPROOT/al-lit.exp"
cmp -s "$TMPROOT/al-lit" "$TMPROOT/al-lit.exp" && ok "append_lines_cr_no_newline_literal_bytes" || bad "cr_no_newline literal: $(od -c "$TMPROOT/al-lit" | head -2)"
printf 'x\ny' > "$TMPROOT/al-lit"; append_lines "$TMPROOT/al-lit"
[ "$(od -An -c "$TMPROOT/al-lit" | tr -d ' \n')" = 'x\ny' ] && ok "append_lines_no_lines_leaves_an_unterminated_file_alone" || bad "no lines changed the file: $(od -c "$TMPROOT/al-lit" | head -2)"
rm -f "$TMPROOT/al-none"; append_lines "$TMPROOT/al-none"
[ ! -e "$TMPROOT/al-none" ] && ok "append_lines_no_lines_does_not_create_the_file" || bad "append_lines created a file for no lines"

finish
