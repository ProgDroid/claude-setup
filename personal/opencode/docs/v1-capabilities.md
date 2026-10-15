# OpenCode V1 capabilities the CC parity adapter depends on

Pinned to **OpenCode 1.19.0** (npm `opencode-ai`; the binary embeds Bun 1.3.14). Source references
are to the upstream repo `anomalyco/opencode` at tag `v1.19.0`, as `file:line` relative to the repo
root. Measured 2026-10-14 (Task 1).

Expectations were written before any probe ran. An expectation that turned out wrong is recorded
as a finding, not reconciled.

**Status:** one (must) row fails as specified: **16(b)**, a `~/` rule on its own. The controller's
remedy (R5, below) was then proven live. See [Failed (must) rows](#failed-must-rows) and
[Controller rulings](#controller-rulings).

## Method

- **Probe project:** a real git repo (temp non-git dirs hide path-matching gaps) containing
  `.opencode/plugins/probe.js`, a throwaway V1 plugin that logs every hook it receives to a JSONL
  file. Behaviours under test are env-gated (`PROBE_CM_MARKER`, `PROBE_AFTER_MARKER`,
  `PROBE_SLOW_EVENT`, `PROBE_EXEC_ROOT`, `PROBE_VERSION_SPAWN`), so marker and control runs share
  one plugin. Fixtures: a project `CLAUDE.md` holding a marker, a project `.claude/skills/` skill, a
  skill dir reachable only via the config hook's `skills.paths`, and source files to read/edit.
- **Model runs:** `opencode run --format json --model anthropic/claude-haiku-5-5 "<prompt>" < /dev/null`.
  `--auto` only where the row is not about permissions.
- **Controls:** each marker row has a run without the marker and a `--pure` run (no external
  plugins) that must come out differently.
- **Row 16** ran in a scratch home built by `test/make-scratch-home.sh` (`HOME`/`USERPROFILE`
  pointing at it, auth copy deleted afterwards by `--teardown`).
- In excerpts, `<scratch>` is the probe's temp dir, `<home>` the scratch home, `<plugin-root>`
  the semgrep plugin's `installPath`.

## Results

| # | Fact | Expected | Actual | Evidence |
|---|---|---|---|---|
| 1 | A config hook's changes to `mcp`, `permission`, `agent`, `command`, `instructions`, `skills.paths` show in `opencode debug config` (print keys only) | yes (must) | **yes** | E1 |
| 2 | Command names may contain `:` | UNKNOWN; record | **yes**: a hook-added `probe:colon` is listed and runs | E2 |
| 3 | `opencode debug agent <name>` shows a hook-added agent | yes | **yes** | E3 |
| 4 | Mutating `output.output` in `tool.execute.after` reaches the model (marker echoed back) | yes (must) | **yes** for built-in tools. **MCP tools differ:** their `output` is the raw MCP result `{content, structuredContent, isError}`, `output.output` is `undefined` | E4 |
| 5 | `event` gets `session.created` (`info.id`, `info.parentID` for children) and `session.idle` (also for children) | yes (must) | **yes**. `session.idle` carries `properties.sessionID` (no `info`) | E5 |
| 6 | `chat.message` is **awaited** before the first model call, and a text part pushed onto `output.parts` reaches the model **in the same turn** | yes (must) | **yes**, with a pushed part that carries its own `id`. Caveats: `chat.message` also fires for other plugins' `noReply` prompts and in child sessions | E6 |
| 7 | The `event` hook is **not** awaited | not awaited | **not awaited** (`void hook["event"]?.(...)`) | E7 |
| 8 | Tool arg names from `tool.execute.before` | see E8 | Schema matches except **`bash` is `{command, timeout, workdir}`: there is no `description`**. Haiku sent only required keys plus `grep.include`; paths arrive absolute, with backslashes | E8 |
| 9 | `apply_patch` arg name + grammar (source) | `patchText`; Begin/Add/Update/Delete/End | **as expected**, plus `*** Move to:` (after Update File), `@@` hunks, `*** End of File` | E9 |
| 10 | Model predicate for `apply_patch` vs `edit`/`write` (source) | GPT-5-class | `modelID.includes("gpt-") && !includes("oss") && !includes("gpt-4")`: `apply_patch` replaces `edit` **and** `write` | E10 |
| 11 | Built-in tool ids (source); MCP tool id format | MCP = `<server>_<tool>` | ids listed in E11; MCP = `sanitize(server) + "_" + sanitize(tool)`, sanitize = `[^a-zA-Z0-9_-]` → `_` (live: `serena_initial_instructions`) | E11 |
| 12 | `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1` stops `~/.claude/skills` + `.claude/skills` but **not** `CLAUDE.md` | yes (must) | **yes** | E12 |
| 13 | The `OPENCODE_EXPERIMENTAL_CODE_MODE` flag name | yes (must) | **yes** (also enabled by `OPENCODE_EXPERIMENTAL=1` unless set false) | E13 |
| 14 | `experimental.session.compacting` fires | UNKNOWN; record | **fires** on a manual summarize (live); auto/overflow compaction reaches the same trigger (source only) | E14 |
| 15 | A throw in `tool.execute.before` blocks, and the model sees the message | yes | **yes** | E15 |
| 16 | Permission matching by effect, scratch home, git probe project | (a) not matched (b) matched (must) (c) yes | (a) **not matched**, confirmed. (b) **FAIL as specified**: `~/` alone is **NOT matched** when project and home are on the same drive. **Remedy R5 verified live:** adding the exact worktree-relative form denies the edit, and the file is unchanged; either separator works. (c) **yes** | E16, E16-R5 |
| 17 | `tool.definition` fires with `toolID` | per request, after `chat.message`; not at startup (must: fires at all) | **fires**, once per tool per model request, after `chat.message`. Also fires from `opencode debug agent` (no model call). **Never fires for MCP tools** | E17 |
| 18 | OC version obtainable inside a plugin | record how | No `ctx` field. Works: `ctx.client._client.get({ url: "/global/health" })` → `{healthy, version}` (private `_client`; the V1 SDK has no `health()` method), and `spawnSync(process.execPath, ["--version"])` → `1.19.0` in ~0.7 s | E18 |
| 19 | Exec form: direct spawn of the extension-less `scripts/hook` fails on win32; Git Bash or `hook.cmd` works | record which works | **Expectation wrong: direct spawn works**, because Windows `CreateProcess` resolves the sibling `hook.exe`. All four forms work for semgrep inside OC; direct `.cmd` spawn without a shell is Bun-version dependent | E19 |

## Failed (must) rows

**16(b).** A `~/`-form rule never matches an `edit` (or `read`) of a file under home **when the
project is on the same drive as home**:

- `fromConfig` expands `~/x` to the absolute `os.homedir() + "/x"`
  (`packages/opencode/src/permission/index.ts:178-183`).
- `edit`/`write`/`read` ask with a **worktree-relative** pattern,
  `path.relative(instance.worktree, filePath)` (`packages/opencode/src/tool/edit.ts:104,147`,
  `write.ts:56`, `read.ts:257`). For a file outside the worktree that is `..\..\.claude\settings.json`,
  which an absolute pattern cannot match.
- Across drives (a `D:` project, home on `C:`) `path.win32.relative` returns the **absolute**
  target, so the same rule *does* match. Matching therefore depends on where the project lives.
- `~/` **does** work for `external_directory`, whose pattern is absolute
  (`packages/opencode/src/tool/external-directory.ts:30-37`).

The July baseline's `**/.claude/settings.json` deny is what actually caught the live edit.

**Remedy (ruling R5), verified live (E16-R5).** Emit every home-anchored rule twice:

- in `~/x` form, which covers cross-drive projects and `external_directory`;
- in the exact worktree-relative form, `path.relative(ctx.worktree, join(os.homedir(), x))`,
  computed inside the `config` hook.

A rule added from the `config` hook does reach agent permission evaluation. The relative key
matches whether it uses `\` or `/` separators, because the matcher normalises both sides.

## Controller rulings

Recorded 2026-10-14 against the rows they rest on (full text in the SDD ledger):

| Ruling | Decision | Rests on |
|---|---|---|
| R5 | Home-anchored CC rules are emitted as `~/x` **and** as the exact `path.relative(ctx.worktree, join(home, x))`, for allow/ask/deny alike. Exact, never broadened | 16(b), E16-R5 |
| R6 | `bash {command, timeout}` → CC Bash; `workdir`, when present, becomes the hook input `cwd`; no CC `description` | 8 |
| R7 | The OC tool inventory (`tool.definition`) covers built-in tools only. MCP drift is covered by MCP config enumeration, and MCP tool args are recorded from `tool.execute.before` | 17, 11 |
| R8 | PostToolUse context for MCP tools is appended as `{type:"text", text}` to `output.content` when `output.output` is undefined | 4 |
| R9 | First-message delivery = the first `chat.message` per **top-level** session that is not a noReply or synthetic prompt; a per-session inserted guard; pushed parts get a fresh OC-format part id | 6, 5 |
| R10 | OC version = `spawnSync(process.execPath, ["--version"])`, once per process and cached; never the private `_client` | 18 |
| R11 | Exec form on win32: resolve PATHEXT siblings beside an extension-less command (`.exe` → direct spawn, `.cmd`/`.bat` → `cmd /c`), else Git Bash | 19 |

## Other findings later tasks need

- **`opencode run` blocks forever reading stdin when stdin is not a TTY**
  (`packages/opencode/src/cli/cmd/run.ts:416`, `await Bun.stdin.text()`). Two runs hung with zero
  output for over 400 s, then the same commands passed with `< /dev/null`. Every scripted run needs
  `< /dev/null`.
- **`--pure` also disables project `.opencode/plugins/`**, not only `plugin` entries (the probe log
  stayed empty). It still loads `CLAUDE.md`. So it is a valid "no adapter" control.
- **`chat.message` is not "the first user message" by itself.** It fires for every
  `client.session.prompt` call, including other plugins' `noReply` injections (a hand-ported hook
  on `session.created`), and in child sessions (`input.agent: "general"`). In a run its order
  relative to the real prompt is a race: the real prompt came first by 3 ms in run A. `input.agent`
  is `undefined` for a CLI prompt without `--agent`. The adapter needs a per-session "already
  inserted" guard, and must not assume the first `chat.message` is the user's.
- **MCP tools bypass `tool.definition`** and are invisible to `opencode debug agent`'s tool list
  (`packages/opencode/src/session/tools.ts:390-420` builds them separately). Under Code Mode they
  are not sent at all (`tools.ts:388`), and the one `execute` tool fronts them. An inventory of OC
  tool ids built from `tool.definition` covers built-in and plugin tools only.
- **MCP `tool.execute.before` runs before the permission ask** (`tools.ts:402-409`), so a block
  there pre-empts OC's own prompt.
- **MCP tool-name split is ambiguous** when a server or tool name contains `_`. Split against the
  known server names (longest prefix), never on the first `_`.
- **The permission matcher is `packages/core/src/util/wildcard.ts:3-14`**, not the older
  `packages/opencode/src/util/wildcard.ts`. `*` is `.*`, so it crosses `/`. Flags are `si` on win32
  (case-insensitive), and backslashes are normalised on both sides. A trailing ` *` makes the tail
  optional.
- **`opencode.log` is a single file** (`<data>/log/opencode.log`), not one file per run. Permission
  lines read `message=evaluated permission=<p> pattern=<p> action.permission=… action.pattern=… action.action=…`.

## Evidence

### E1: config hook → `opencode debug config`
Hook pushes `mcp["probe-mcp"]` (disabled), `permission.probe_perm`, `agent["probe-agent"]`,
`command["probe:colon"]`/`["probe-dash"]`, `instructions += "PROBE_INSTRUCTIONS.md"`,
`skills.paths += <scratch>/probe-skills`.
```
$ opencode debug config | jq -c '{mcp:(.mcp|keys), permission:(.permission|keys), agent:(.agent//{}|keys), command:(.command//{}|keys), instr_probe:…, instr_n:…, skills_probe:…}'
{"mcp":[…,"probe-mcp",…],"permission":["bash","edit","probe_perm","read"],"agent":["probe-agent"],"command":["probe-dash","probe:colon"],"instr_probe":1,"instr_n":4,"skills_probe":1}
$ OPENCODE_PURE=1 opencode debug config | jq -c …      # control
{"mcp":[…no probe-mcp…],"permission":["bash","edit","read"],"agent":[],"command":[],"instr_n":3,"skills":[]}
```
Hook dispatch: `packages/opencode/src/plugin/index.ts:244-252` (`config?.(cfg)` on the live object; errors logged and ignored).

### E2: colon command
```
$ opencode run --command "probe:colon" --format json --model anthropic/claude-haiku-5-5 < /dev/null
text: PROBE-COLON-OK
$ opencode run --command "probe:nonexistent" …        # control
{"type":"error",…"message":"Command not found: \"probe:nonexistent\". …"}   exit 1
```

### E3: hook-added agent
```
$ opencode debug agent probe-agent | jq -c '{name,mode,description,prompt}'
{"name":"probe-agent","mode":"subagent","description":"Probe agent added by a config hook","prompt":"You are a probe agent."}
$ OPENCODE_PURE=1 opencode debug agent probe-agent     # control, exit 1
Agent probe-agent not found, run 'opencode.exe agent list' to get an agent list
```

### E4: `tool.execute.after` mutation
Prompt: run `echo hello-probe`, run `echo probe-block`, then report `SECRET= CODEWORD= BLOCKED= ANIMAL=`.
The hook appends `PROBE-AFTER-MARKER: the codeword is HERON-77` to bash `output.output`.
```
marker run (PROBE_CM_MARKER=1 PROBE_AFTER_MARKER=1 --auto):
  SECRET=ZEBRA-41 CODEWORD=HERON-77 BLOCKED=PROBE-BLOCKED: reason code KESTREL-93 ANIMAL=AXOLOTL
no-marker run:   SECRET=NONE CODEWORD=NONE BLOCKED=PROBE-BLOCKED: reason code KESTREL-93 ANIMAL=AXOLOTL
--pure run:      SECRET=NONE CODEWORD=NONE BLOCKED=NONE ANIMAL=AXOLOTL   (both bash calls completed)
probe log: {"ev":"after","tool":"bash","outKeys":["title","metadata","output","attachments"],"outputType":"string"}
           {"ev":"after","tool":"serena_initial_instructions","outKeys":["content","structuredContent","isError"],"outputType":"undefined"}
```
Trigger sites: built-ins `packages/opencode/src/session/tools.ts:106` / `:121`; MCP `tools.ts:420` passes the raw MCP `result` as `output`.

### E5: session events
Run B: the root agent calls `task` with `subagent_type: general`.
```
{"type":"session.created","id":"ses_…d1wmj4","parentID":null}
{"type":"session.created","id":"ses_…pasl1j","parentID":"ses_…d1wmj4"}
{"type":"session.idle","sessionID":"ses_…pasl1j"}      # child
{"type":"session.idle","sessionID":"ses_…d1wmj4"}      # root
```

### E6: `chat.message` awaited, same-turn delivery
The hook sleeps 2 s, then pushes
`{id: "prt_"+<12 hex ms·4096+n>+<14 base62>, sessionID, messageID, type:"text", synthetic:true, text:"PROBE-CM-MARKER: the secret word for this session is ZEBRA-41."}`.
Answers are in E4 (ZEBRA-41 only in the marker run). Timeline (ms since plugin load):
```
351  chat.message-start   354 chat.message-start      # two prompts: the user's + another plugin's noReply
2374 chat.message-pushed  2379 chat.message-end
4171 first tool.definition batch   13192 first system.transform (first model request)
```
The part is persisted (`opencode.db` `part` table: `text synthetic PROBE-CM-MARKER: …`). Trigger:
`packages/opencode/src/session/prompt.ts:999-1008`, before the parts are decoded and saved
(`prompt.ts:1010-1047`). A part without `id` would reach `updatePart` unassigned (`assign` runs at
`prompt.ts:694-697`, before the trigger), so supply one.

### E7: `event` not awaited
`PROBE_SLOW_EVENT=1` makes the `session.created` handler sleep 4 s.
```
242 slow-event-start   351 chat.message-start   …   4546 slow-event-end
```
Source: `packages/opencode/src/plugin/index.ts:255-262`, `Effect.sync(() => { for (const hook of hooks) void hook["event"]?.(…) })`.

### E8: tool args
Run B (`--auto`) asks for read, grep, glob, edit, write, bash and task, one each.
```
read  argKeys ["filePath"]                        (absolute, backslashes)
grep  argKeys ["pattern","path","include"]
glob  argKeys ["pattern"]
edit  argKeys ["filePath","oldString","newString"]
write argKeys ["filePath","content"]
bash  argKeys ["command"]
task  argKeys ["description","prompt","subagent_type"]
```
Full schemas (source):

| tool | params | source |
|---|---|---|
| read | `filePath, offset?, limit?` | `packages/opencode/src/tool/read.ts:29-34` |
| edit | `filePath, oldString, newString, replaceAll?` | `tool/edit.ts:48-54` |
| write | `content, filePath` | `tool/write.ts:21-23` |
| grep | `pattern, path?, include?` | `tool/grep.ts:11-16` |
| glob | `pattern, path?` | `tool/glob.ts:11-13` |
| bash | `command, timeout?, workdir?` (**no `description`**) | `tool/shell/prompt.ts:15-23` |
| task | `description, prompt, subagent_type, task_id?, command?, background?` | `tool/task.ts:43-63` |
| webfetch | `url, format, timeout?` | `tool/webfetch.ts:14-21` |
| skill | `name` | `tool/skill.ts:9` |
| todowrite | `todos` | `tool/todo.ts:7` |
| apply_patch | `patchText` | `tool/apply_patch.ts:18-19` |

### E9: `apply_patch`
`packages/opencode/src/tool/apply_patch.ts:18-19` (`patchText`, required, `:34-35`). Grammar in
`packages/opencode/src/patch/index.ts`: `*** Begin Patch` / `*** End Patch` (`:192-193`),
`*** Add File:` (`:76`), `*** Delete File:` (`:81`), `*** Update File:` (`:86`) with optional
`*** Move to:` (`:92`), `@@` hunks (`:108`), `*** End of File` (`:121`).

### E10: model predicate
`packages/opencode/src/tool/registry.ts:297-300`:
```ts
const usePatch = input.modelID.includes("gpt-") && !input.modelID.includes("oss") && !input.modelID.includes("gpt-4")
if (tool.id === ApplyPatchTool.id) return usePatch
if (tool.id === EditTool.id || tool.id === WriteTool.id) return !usePatch
```

### E11: tool ids
`packages/opencode/src/tool/registry.ts:209-249`. Built-ins, in order: `invalid`, `question` (only for
client `app`/`cli`/`desktop` or `OPENCODE_ENABLE_QUESTION_TOOL`), `bash` (`tool/shell/id.ts:16`, kept
as "bash" for every shell kind), `read`, `glob`, `grep`, `edit`, `write`, `task`, `webfetch`,
`todowrite`, `websearch` (opencode providers or Exa/Parallel flags only, `:293-295`), `skill`,
`apply_patch`, `execute` (Code Mode, `tool/code-mode.ts:12`), `lsp`
(`OPENCODE_EXPERIMENTAL_LSP_TOOL`), `plan_exit` (`OPENCODE_EXPERIMENTAL_PLAN_MODE`, cli client).
Plugin file tools: `<file>` or `<file>_<export>` (`registry.ts:189-193`).
Live `tool.definition` set for Haiku: `bash, edit, glob, grep, invalid, question, read, skill, task, todowrite, webfetch, write`.
MCP: `packages/opencode/src/mcp/catalog.ts:117-119`.

### E12: Claude Code skills vs `CLAUDE.md`
```
$ opencode debug skill | jq length                                            54
  probe-local-skill (project .claude/skills)=1  probe-hook-skill (skills.paths)=1  youtube-transcript (~/.claude/skills only)=1
$ OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1 opencode debug skill | jq length      24
  probe-local-skill=0  probe-hook-skill=1  youtube-transcript=0
system.transform contains the CLAUDE.md marker:
  OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1  {"claudeMd":true,"instr":true}
  OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1  {"claudeMd":false,"instr":true}     # control
```
Source: `packages/opencode/src/effect/runtime-flags.ts:23-30` (both flags also set by
`OPENCODE_DISABLE_CLAUDE_CODE`); `skill/index.ts:185-202`; `session/instruction.ts:60-68`.

### E13: Code Mode flag
`packages/opencode/src/effect/runtime-flags.ts:48`, `experimentalCodeMode: enabledByExperimental("OPENCODE_EXPERIMENTAL_CODE_MODE")`.
```
$ OPENCODE_EXPERIMENTAL_CODE_MODE=1 opencode debug agent build | jq .tools.execute   true   (tool.definition includes "execute")
$ OPENCODE_EXPERIMENTAL_CODE_MODE=0 opencode debug agent build | jq .tools.execute   null
```

### E14: compaction hook
`opencode serve` in the probe project; `POST /session`, `POST /session/:id/message`, then
`POST /session/:id/summarize {"providerID":"anthropic","modelID":"claude-haiku-5-5"}` → `true`.
```
{"t":21068,"ev":"compacting","sessionID":"ses_…5jcxgyx"}     then event session.compacted
```
Trigger `packages/opencode/src/session/compaction.ts:373`, inside `SessionCompaction.process`
(`:319`). Overflow compaction calls `compaction.create({auto:true})` (`session/prompt.ts:1166`) and
is processed by the same function (`prompt.ts:1150`). It was not triggered live.

### E15: block by throw
`throw new Error("PROBE-BLOCKED: reason code KESTREL-93")` for a bash command containing
`probe-block`. The model reported `BLOCKED=PROBE-BLOCKED: reason code KESTREL-93` (E4). The no-plugin
`--pure` control ran the command (`BLOCKED=NONE`).

### E16: permissions
Scratch home (`make-scratch-home.sh`); the user config is the live baseline (bare twins
`id_rsa*`, `*.pem`; edit `**/.claude/settings.json` deny). Project `opencode.json`:
```json
{"permission":{"read":{"**/probe_rsa*":"deny"},
 "edit":{"~/.claude/settings.json":"ask","~/.claude/probe-target.json":"deny"},
 "external_directory":{"~/.claude/*":"allow"}}}
```
No `--auto`, `--print-logs`. `evaluated` lines:
```
read pattern=id_rsa         → action.pattern=id_rsa*                action=deny    (bare twin)
read pattern=x.pem          → action.pattern=*.pem                  action=deny    (bare twin)
read pattern=probe_rsa      → action.pattern=*                      action=allow   (a) **/ alone: NOT matched, file was read
read pattern=sub\probe_rsa  → action.pattern=**/probe_rsa*          action=deny
external_directory pattern=<home>\.claude\*   → action.pattern=<home>\.claude\*  (allow)   # ~/ matches absolute patterns
edit pattern=..\h1\.claude\settings.json      → action.pattern=**/.claude/settings.json action=deny   (b) ~/ rule NOT matched
edit pattern=..\h1\.claude\probe-target.json  → action.pattern=*  action=allow          (b) ~/ deny NOT matched; file changed to {"probe": "edited"}
```
Same `match`/`evaluate` code run on paths (verbatim copies of `packages/core/src/util/wildcard.ts:3-14`
and `packages/opencode/src/permission/index.ts:28-37`, under Bun):
```
home C:\h\someone
worktree C:\proj  editPattern ..\h\someone\.claude\settings.json   ~/rule:false  **/rule:true
worktree D:\proj  editPattern C:\h\someone\.claude\settings.json   ~/rule:true   **/rule:true
id_rsa vs **/id_rsa*: false   x.pem vs **/*.pem: false   sub\id_rsa vs **/id_rsa*: true
```
(c) The plan agent's merged ruleset from `opencode debug agent plan` in the scratch home, evaluated
for `edit src/a.ts`: without a user rule `{"pattern":"*","action":"deny"}`; with project
`edit:{"*":"ask"}` `{"pattern":"*","action":"ask"}`. The user ruleset is merged after the agent's
built-ins (`packages/opencode/src/agent/agent.ts:156-177`), and `evaluate` takes the last match.
A live attempt was not discriminating: Haiku under `--agent plan` declined to call `edit` either way.

### E16-R5: the remedy, live
A fresh scratch home (`make-scratch-home.sh`) and the git probe project on the same drive. The
project config only allows `external_directory` for `~/.claude/*`, so the edit reaches the `edit`
check. The probe's `config` hook adds `permission.edit[<key>] = "deny"`, where the key comes from
`relative(ctx.worktree, join(homedir(), ".claude", "probe-target.json"))`. One run per key form,
with the target reset to `{"probe": "original"}` before each. No `--auto`: an unmatched edit falls
to the default `*: allow`, so the deny has nothing to beat.
```
key = relative (native "\")  → evaluated permission=edit pattern="..\\h3\\.claude\\probe-target.json" action.pattern="..\\h3\\.claude\\probe-target.json" action.action=deny
                                edit tool: error "The user has specified a rule which prevents…"   file: {"probe": "original"}
key = relative with "/"      → evaluated … action.pattern=../h3/.claude/probe-target.json action.action=deny
                                edit tool: error                                                     file: {"probe": "original"}
key = "~/.claude/probe-target.json" (control)
                             → evaluated … action.permission=* action.pattern=* action.action=allow
                                edit tool: completed                                                 file: {"probe": "edited"}
```
Separators, against the verbatim matcher (`core/src/util/wildcard.ts:3-14`), with ask
`..\h3\.claude\probe-target.json`: backslash rule true, forward-slash rule true, mixed true;
negative control `..\h3\.claude\other.json` false. A forward-slash ask against a backslash rule is
also true. Either separator works; use the native `path.relative` output.

### E17: `tool.definition`
Run A: three model requests, three batches of 12 `tool.definition` calls (t=4171, 18390, 21494),
each before that request's `system.transform`, all after `chat.message-end` (2379). Also fired 12×
during `opencode debug agent probe-agent` (no model call). No `serena_*` id ever appeared, though
the model called `serena_initial_instructions`. Trigger `packages/opencode/src/tool/registry.ts:318`
inside `ToolRegistry.tools()` (built-ins + plugin tools only).

### E18: OC version
```
init: ctxKeys ["client","project","worktree","directory","experimental_workspace","serverUrl","$"]
ctx.client.global.health()                          → TypeError: not a function   (V1 SDK: Global has only event())
ctx.client._client.get({url:"/global/health"})      → {"healthy":true,"version":"1.19.0"}   (at init and in chat.message)
spawnSync(process.execPath, ["--version"])          → status 0, "1.19.0", 725 ms   (execPath = opencode.exe)
```
Source: `packages/opencode/src/server/routes/instance/httpapi/handlers/global.ts:67`.

### E19: exec form
Run inside OC (probe plugin at init, `PROBE_EXEC_ROOT=<plugin-root>`, triggered by `opencode debug
config`), payload `SessionStart`, args `claude SessionStatus`:
```
semgrep root:   direct scripts/hook → 0 (JSON)   bash scripts/hook → 0   hook.cmd direct (no shell) → 0   hook.cmd shell:true → 0
control (a dir holding ONLY the extension-less scripts/hook):
                direct → ENOENT   bash → 127 (dispatcher execs the missing hook.exe)   .cmd → ENOENT   .cmd shell → 1
```
So a direct spawn of `.../scripts/hook` runs the sibling `hook.exe`, which is what the script's own
header says Windows does. A bare POSIX script with no `.exe` sibling fails direct spawn.
Standalone Bun 1.4.0 differs on one form: `.cmd` without a shell → `EINVAL` (Node's .bat/.cmd
hardening). Don't depend on it. Use Git Bash for extension-less scripts and `shell:true` for
`.cmd`.

## CC hook protocol (verified)

Source: https://code.claude.com/docs/en/hooks.md, fetched 2026-10-15. The fetch tool read only the
first ~100k of 270k characters, so the per-event input schemas for PostToolUse, UserPromptSubmit,
Stop, PreCompact and SessionEnd are **not** confirmed by this read; the adapter's `buildInput`
fields for those come from the Task 5 brief. Matcher value lists were confirmed.

| Item | Docs say | Adapter (`core/protocol.js`) |
|---|---|---|
| Common input | `session_id`, `prompt_id`, `transcript_path`, `cwd`, `scratchpad_dir`, `permission_mode` (`default`/`plan`/`acceptEdits`/`auto`/`dontAsk`/`bypassPermissions`), `effort{level}`, `hook_event_name` | Sends `session_id`, `transcript_path:null`, `cwd`, `hook_event_name`, `permission_mode` (`default`/`auto`). Does not send `prompt_id`, `scratchpad_dir`, `effort` |
| PreToolUse input | `tool_name`, `tool_input`, `tool_use_id` | same |
| SessionStart input | `source`: `startup`/`resume`/`clear`/`compact`/`fork` | `startup` unless the caller overrides |
| PreCompact / SessionEnd matcher values | `manual`,`auto` / `clear`,`resume`,`logout`,`prompt_input_exit`,`other` | `trigger:"auto"`, `reason:"other"` |
| Exit 0 | stdout parsed as JSON if it is one object; else text. Text becomes context only for UserPromptSubmit, UserPromptExpansion, SessionStart, PostModelSwitch | JSON object → structured; text → context on SessionStart/UserPromptSubmit only |
| Exit 2 | PreToolUse blocks; UserPromptSubmit blocks; Stop prevents stopping; PostToolUse shows stderr to Claude; SessionStart/SessionEnd stderr to user; PreCompact blocks. "Exit 2 blocks even when your hook prints JSON" | Blocks PreToolUse/UserPromptSubmit, context on PostToolUse; stdout JSON is not consulted at exit 2 |
| Other exit | non-blocking error, action proceeds | `failed:true`, non-blocking |
| Timeout default | 600 s (command), 30 s on UserPromptSubmit/Pre/PostModelSwitch, 10 s MessageDisplay; SessionEnd shares a 1.5 s budget | 600 s, 30 s on UserPromptSubmit |
| JSON top-level | `continue`, `stopReason`, `suppressOutput`, `systemMessage`, `terminalSequence`, `decision`, `reason`, `hookSpecificOutput` | all recognised; anything else → `unknownFields`. `continue:false` (final review I5) blocks PreToolUse/UserPromptSubmit with `stopReason` (default "stopped by hook"), ahead of decision fields; on other events → `notHonoured`. The turn itself is not stopped |
| PreToolUse output | `permissionDecision` allow/deny/ask/defer + `permissionDecisionReason`; `updatedInput`; `additionalContext` | deny/ask block; allow/defer do not; additionalContext carried; updatedInput applied to bash/edit/write, and BLOCKS when it cannot be applied in full (several CC calls, no reverse arg map, or a changed field with no OC arg; R48) |
| PostToolUse output | `updatedToolOutput` replaces the tool result | reported as `hookSpecificOutput.updatedToolOutput` in `unknownFields` (not applied) |

### Disagreements with the brief's `interpret` rules (reported, rules NOT changed)

1. **Top-level `decision:"block"` on Stop / PostToolUse.** Docs list it as honoured for UserPromptSubmit,
   UserPromptExpansion, PostToolUse, PostToolUseFailure, PostToolBatch, Stop, SubagentStop,
   ConfigChange, PreCompact. The brief says "logged and not honoured". The adapter follows the
   brief (OC has no equivalent for Stop; PostToolUse cannot un-run a tool). It does honour
   `decision:"block"` on UserPromptSubmit, which the docs list and the brief did not cover.
2. **Malformed JSON at exit 0.** Docs: "a non-blocking error" with a hook-error notice. The brief
   (RF3) says `failed:false`. The adapter follows the brief; the docs imply it should count as a
   failure.
3. **Plain exit-2 JSON.** Docs: JSON cannot override an exit-2 block; the adapter ignores stdout at
   exit 2, consistent.
4. **`prompt_id`, `scratchpad_dir`, `effort`, `last_assistant_message` (Stop)** exist in the docs and
   are not sent. A hook that reads them gets nothing.

## CC 2.1.300 tool defaults (R49)

A key CC's rules leave uncovered gets CC's own default for the mapped tool, read from the tool's
`checkPermissions` in the CC 2.1.300 bundle (minified names as they appear there). The generic
resolver turns a tool's `passthrough` into an ask unless an allow rule or the mode applies:
`let We=V.behavior==="passthrough"?{...V,behavior:"ask",message:Ol(e.name,V.decisionReason)}:V`.
The tool factory (`Jt`) allows a tool that defines no check of its own:
`return A.checkPermissions?A.checkPermissions(S,k):Promise.resolve({behavior:"allow",updatedInput:S})`.

| CC tool | OC key | CC default (default mode) | Bundle evidence | Adapter emits when uncovered |
|---|---|---|---|---|
| Agent / Task | `task` | no prompt (asks only in auto mode, or plan mode with the classifier) | `checkPermissions(e,p){if(!Ms(n.permissions().mode))return{behavior:"allow",updatedInput:e};...return{behavior:"passthrough",message:"Agent tool requires permission to spawn subagents."}}` with `function Ms(e,s=!1){return e==="auto"\|\|e==="plan"&&!s&&cp()}` | nothing (OC's default) |
| Edit / Write / NotebookEdit | `edit` | ask (allow only in acceptEdits mode inside the working dirs, or by rule) | shared check `Gh(...)`: `if(r.mode==="acceptEdits"&&U)return{behavior:"allow",...}` ... `return{behavior:"ask",suggestions:nut(h,"write",r,w),...jl("write to",h,y,r)}` | `"*":"ask"` first |
| WebFetch | `webfetch` | ask, unless an allow rule or a CC preapproved host | `if(!a.CLAUDE_CODE_EVAL_CONFINED&&Noo(r.url))return{behavior:"allow",...reason:"Preapproved host"}};return{behavior:"ask",message:\`Claude requested permissions to use ${wb.name}, but you haven't granted it yet.\`...}` | `"ask"` (stricter for CC's preapproved hosts) |
| WebSearch | `websearch` | ask | `checkPermissions(r){return{behavior:"passthrough",message:"WebSearchTool requires permission.",...}}` | `"ask"` |
| TodoWrite | `todowrite` | no prompt | the tool object (`_o=Jt({name:PR,...})`) defines no `checkPermissions`, so the factory allows | nothing |
| Skill | `skill` | no prompt for a skill whose definition has only "safe" properties; ask otherwise | `if(d?.type==="prompt"&&(De(d)\|\|xse(n)))return{behavior:"allow",...}` ... `return{behavior:"ask",message:\`Execute skill: ${a}...\`}`; `De` returns false for any non-empty property outside the `Fe` safe set, which leaves out `allowedTools`, `disallowedTools` and `hooks` (from the `allowed-tools`, `disallowed-tools`/`disallowedTools` and `hooks` frontmatter) | `"<name>":"ask"` per skill whose SKILL.md sets one of those (skills.js `promptingSkills`) |
| `mcp__<srv>__<tool>` | `<srv>_*` | ask | `async checkPermissions(){return{behavior:"passthrough",message:"MCPTool requires permission."}}`; the live MCP tool ends `return{behavior:"passthrough",message:"MCPTool requires permission.",...}` | `"<srv>_*":"ask"` ahead of CC's allows |

Not reproduced: CC's preapproved WebFetch hosts (OC asks), the Skill tool's "held-back" plugin
cases and coordinator-mode allow, and every mode other than default. A CC or baseline rule for a
key wins over these defaults, with one exception: a CC whole-tool `allow:["Skill"]` does not lift
the per-skill asks (CC's resolver allows on it after `checkPermissions` asks), so a guarded skill
still prompts in OC. That is stricter than CC. The inventory-failure overlay asks for Bash, Edit, WebFetch,
WebSearch, every MCP server and Skill (which skills CC would prompt for is unknown then), not Task.
