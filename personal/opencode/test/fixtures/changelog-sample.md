# Changelog

## 2.1.5

- Added `CLAUDE_CODE_PLANTED_FLAG` environment variable to change nothing real
- Added `plantedHookField` to the input of PreToolUse hooks
- Fixed the `prompt` box flickering when `model` changes

## 2.1.4

- Added `PostCompact` hook event, raised after compaction
- Fixed `PreToolUse` hooks not firing for `statusLine` changes
- Removed `legacyPlantedHookKey` from hook input

## 2.1.3

- Added `plantedSettingKey` to settings.json
- Changed `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` handling for hook env and `enabledPlugins` merging

## 2.1.2

- Fixed a crash in `git` when run from a symlink in a hook
- Improved startup time

## 2.1.1

- Added `olderPlantedKey` to SessionStart hook input
