import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { ccPaths } from "./paths.js";

// ruleFiles(home) -> absolute paths of every .md under ~/.claude/rules, sorted.
// CC discovers rule files recursively and follows symlinks (memory docs, "Organize rules
// with .claude/rules/"), so this walks subdirectories, following links, once per real dir.
export function ruleFiles(home = os.homedir()) {
  const out = [];
  const seen = new Set();
  const walk = (dir) => {
    let real;
    try {
      real = fs.realpathSync(dir);
    } catch {
      return;
    }
    if (seen.has(real)) return;
    seen.add(real);
    let names;
    try {
      names = fs.readdirSync(dir);
    } catch {
      return;
    }
    for (const n of names) {
      const p = path.join(dir, n);
      let st;
      try {
        st = fs.statSync(p);
      } catch {
        continue;
      }
      if (st.isDirectory()) walk(p);
      else if (st.isFile() && n.toLowerCase().endsWith(".md")) out.push(p);
    }
  };
  walk(ccPaths(home).rulesDir);
  return out.sort();
}
