// Portions of this file are copied from opencode (https://github.com/anomalyco/opencode),
// tag v1.19.0, packages/opencode/src/patch/index.ts:157-260 (parsePatch and helpers).
// MIT License, Copyright (c) 2025 opencode. The full permission notice is in
// personal/opencode/THIRD_PARTY_NOTICES, which must accompany this file.
//
// OC `apply_patch` parser, a line-for-line mirror of v1.19.0 packages/opencode/src/patch/index.ts
// `parsePatch` (grammar: v1-capabilities.md row 9 / E9). It must stay exact, not merely similar:
// a patch OC applies but this parser reads differently reaches no hook (fail open). The traps:
//   - the whole text is trimmed and an optional `cat <<'EOF' ... EOF` heredoc wrapper stripped;
//     line endings are NOT normalised (OC keeps a CR on every row);
//   - Begin/End markers are the FIRST lines whose `trim()` equals the marker, and only the OUTER
//     loop stops at the End marker line. The Add/Update inner loops run to the end of the TEXT and
//     stop only at a row starting with `***`, so an indented ` *** End Patch` is consumed as a row
//     and later rows still apply;
//   - headers are `startsWith("*** Add File:")` etc. + `slice().trim()` (no space needed);
//   - Add content: each `+` row plus "\n", one trailing "\n" removed; on write OC appends "\n" to
//     non-empty content lacking one, so `content` here is what lands on disk;
//   - Update rows before the first `@@` are ignored; in a hunk ` `/`-`/`+` rows count, any other
//     row (blank included) is ignored; `*** End of File` just ends the hunk.
//
// Returns { ops, unknown }:
//   ops: Array<{ op: "add"|"update"|"delete", path, content?, hunks?, moveTo? }>
//        hunks: Array<{ oldText, newText }>, one per `@@` (context + removed / context + added rows).
//        A pure-addition hunk has oldText "" (CC's Edit reads that as create-file semantics).
//   unknown: true when the outer loop meets a `***` line this parser does not recognise, or a
//        header with an empty path. Callers fail closed (R32).
// Never throws: text without usable Begin/End markers yields { ops: [], unknown: false }.
function stripHeredoc(input) {
  const m = input.match(/^(?:cat\s+)?<<['"]?(\w+)['"]?\s*\n([\s\S]*?)\n\1\s*$/);
  return m ? m[2] : input;
}

export function parseApplyPatchFull(text) {
  const res = { ops: [], unknown: false };
  if (typeof text !== "string") return res;
  const lines = stripHeredoc(text.trim()).split("\n");
  const n = lines.length;
  const begin = lines.findIndex((l) => l.trim() === "*** Begin Patch");
  const end = lines.findIndex((l) => l.trim() === "*** End Patch");
  if (begin === -1 || end === -1 || begin >= end) return res;

  const after = (line, prefix) => line.slice(prefix.length).trim();
  let i = begin + 1;
  while (i < end) {
    const line = lines[i];
    if (line.startsWith("*** Add File:")) {
      const p = after(line, "*** Add File:");
      i++;
      let content = "";
      while (i < n && !lines[i].startsWith("***")) {
        if (lines[i].startsWith("+")) content += lines[i].slice(1) + "\n";
        i++;
      }
      if (content.endsWith("\n")) content = content.slice(0, -1);
      if (content.length > 0 && !content.endsWith("\n")) content += "\n";
      if (!p) res.unknown = true;
      else res.ops.push({ op: "add", path: p, content });
    } else if (line.startsWith("*** Delete File:")) {
      const p = after(line, "*** Delete File:");
      if (!p) res.unknown = true;
      else res.ops.push({ op: "delete", path: p });
      i++;
    } else if (line.startsWith("*** Update File:")) {
      const p = after(line, "*** Update File:");
      i++;
      let moveTo;
      if (i < n && lines[i].startsWith("*** Move to:")) {
        moveTo = after(lines[i], "*** Move to:");
        i++;
      }
      const hunks = [];
      while (i < n && !lines[i].startsWith("***")) {
        if (!lines[i].startsWith("@@")) {
          i++;
          continue;
        }
        i++;
        const o = [];
        const nw = [];
        while (i < n && !lines[i].startsWith("@@") && !lines[i].startsWith("***")) {
          const r = lines[i];
          if (r.startsWith(" ")) {
            o.push(r.slice(1));
            nw.push(r.slice(1));
          } else if (r.startsWith("-")) o.push(r.slice(1));
          else if (r.startsWith("+")) nw.push(r.slice(1));
          i++;
        }
        hunks.push({ oldText: o.join("\n"), newText: nw.join("\n") });
      }
      if (!p || (moveTo !== undefined && !moveTo)) res.unknown = true;
      else res.ops.push({ op: "update", path: p, hunks, ...(moveTo ? { moveTo } : {}) });
    } else {
      if (line.startsWith("***") && !line.startsWith("*** End of File")) res.unknown = true;
      i++;
    }
  }
  return res;
}

// Convenience: just the ops.
export function parseApplyPatch(text) {
  return parseApplyPatchFull(text).ops;
}
