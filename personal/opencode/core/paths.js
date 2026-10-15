import os from "node:os";
import path from "node:path";

export function ccPaths(home = os.homedir()) {
  const claudeDir = path.join(home, ".claude");
  return {
    claudeDir,
    settings: path.join(claudeDir, "settings.json"),
    settingsLocalUser: path.join(claudeDir, "settings.local.json"),
    claudeJson: path.join(home, ".claude.json"),
    installedPlugins: path.join(claudeDir, "plugins", "installed_plugins.json"),
    skillsDir: path.join(claudeDir, "skills"),
    agentsDir: path.join(claudeDir, "agents"),
    commandsDir: path.join(claudeDir, "commands"),
    rulesDir: path.join(claudeDir, "rules"),
  };
}

export function projectPaths(projectDir) {
  const dir = path.join(projectDir, ".claude");
  return {
    settings: path.join(dir, "settings.json"),
    settingsLocal: path.join(dir, "settings.local.json"),
    mcpJson: path.join(projectDir, ".mcp.json"),
    skillsDir: path.join(dir, "skills"),
  };
}

// OC data dir mirrors OC v1.19.0 (packages/core/src/global.ts:3,10, xdg-basedir xdgData):
// XDG_DATA_HOME if set, else os.homedir()/.local/share. Never HOME. CC_PARITY_STATE
// overrides the state file only.
export function ocPaths(env = process.env) {
  const base = env.XDG_DATA_HOME || path.join(os.homedir(), ".local", "share");
  const dataDir = path.join(base, "opencode");
  // OC config dir mirrors Global.Path.config (xdgConfig/opencode): XDG_CONFIG_HOME, else
  // ~/.config. CC_PARITY_DISPOSITIONS overrides the optional user-local dispositions file; it is
  // also read from process.env when the given env lacks it (round 4 m4: callers that pass their own
  // env object must not fall through to the real user file).
  const configDir = path.join(env.XDG_CONFIG_HOME || path.join(os.homedir(), ".config"), "opencode");
  return {
    dataDir,
    configDir,
    dispositionsFile: env.CC_PARITY_DISPOSITIONS || process.env.CC_PARITY_DISPOSITIONS || path.join(configDir, "cc-parity-dispositions.json"),
    stateFile: env.CC_PARITY_STATE || path.join(dataDir, "cc-parity-state.json"),
    logFile: path.join(dataDir, "cc-parity.log"),
  };
}
