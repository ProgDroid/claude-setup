// Test oracle: Claude Code 2.1.302's command-argument substitution, read verbatim from the installed
// CC binary at test time. CC is not open source, so its code is not copied into this repository:
// this module finds the text in the binary, checks it against the SHA-256 of the 2.1.302 text, and
// evaluates exactly those bytes. Nothing here is a re-derivation.
//
// Provenance: the CC 2.1.302 Windows binary (`claude --version` -> "2.1.302 (Claude Code)"). Found
// by scanning its embedded JS bundle for `function ZFe(` (the first of two hits; the second is an
// unrelated function with the same minified name in another module) and taking:
//   A  `function jP(e){...}`: the value transform markdown-command callers pass to ZFe as `h`
//      (plugin and user commands alike: ZFe(body, args, true, nce(frontmatter.arguments), jP)).
//   B  from `lmr=4000000,Abo=64,Obo=64,` through the end of ZFe: the constants, `mio` (the
//      argument splitter), `nce`, `Vcs` and `ZFe` itself, as they sit in the bundle.
// SHA-256 over A + "\n" + B is pinned below; a different CC build yields `ok: false` and the
// oracle tests skip with the reason rather than compare against something else.
//
// Not from the binary, supplied here:
//   mw  CC's tree-sitter bash parse returning the first command's argv; it cannot be extracted as
//       plain JS. The stand-in returns [], which sends mio down CC's own (verbatim) fallback, the
//       whitespace split. That equals CC's real result for plain words, so oracle comparisons use
//       plain-word arguments only.
//   pT  the error class thrown past 4,000,000 characters; La, a regex escape reached only with
//       named arguments, which no caller here passes.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export const CC_VERSION = "2.1.302";
const SHA256 = "ebb1205bea6f255abb922cfac12ceed60ebff7947b9e6f55d7148edc3cb61e1b";
const A_START = "function jP(e){return e.replace(";
const A_TAIL = ".replace(/(^|";
const B_START = "lmr=4000000,Abo=64,Obo=64,";
const B_END = 'return e.replaceAll(E1,"$").replaceAll(B9,"")}';

// CC_ORACLE_BIN, else the first `claude.exe` / `claude` on PATH that is a real binary (not a shim).
function findBinary(env = process.env) {
  if (env.CC_ORACLE_BIN) return env.CC_ORACLE_BIN;
  const key = Object.keys(env).find((k) => k.toLowerCase() === "path") ?? "PATH";
  for (const dir of String(env[key] ?? "").split(path.delimiter).filter(Boolean)) {
    for (const name of ["claude.exe", "claude"]) {
      const f = path.join(dir, name);
      try {
        if (fs.statSync(f).size > 50 * 1024 * 1024) return f;
      } catch {
        // not here
      }
    }
  }
  return null;
}

function load() {
  const bin = findBinary();
  if (!bin) return { ok: false, why: "no Claude Code binary found (set CC_ORACLE_BIN)" };
  let data;
  try {
    data = fs.readFileSync(bin);
  } catch (e) {
    return { ok: false, why: `cannot read the CC binary: ${e?.code ?? e}` };
  }
  const i = data.indexOf(A_START);
  const k = data.indexOf(B_START);
  if (i < 0 || k < 0) return { ok: false, why: `CC ${CC_VERSION}'s ZFe was not found in this binary (a different CC build?)` };
  const j = data.indexOf("}", data.indexOf(A_TAIL, i)) + 1;
  const e = data.indexOf(B_END, k);
  if (j <= 0 || e < 0) return { ok: false, why: "the extract's end markers were not found" };
  const A = data.subarray(i, j).toString("utf8");
  const B = data.subarray(k, e + B_END.length).toString("utf8");
  const sha = crypto.createHash("sha256").update(`${A}\n${B}`, "utf8").digest("hex");
  if (sha !== SHA256) return { ok: false, why: `the extract differs from CC ${CC_VERSION}'s (sha256 ${sha.slice(0, 12)}...): re-verify before trusting it` };
  // Only the hash-checked bytes above are evaluated, wrapped in the stand-ins listed in the header.
  const src = `"use strict";class pT extends Error{}const mw=()=>[];function La(t){return t.replace(/[.*+?^\${}()|[\\]\\\\]/g,"\\\\$&")}var ${B};${A};return{ZFe,mio,jP};`;
  const fns = new Function(src)();
  return { ok: true, ...fns, ccCommand: (body, args) => fns.ZFe(body, args, true, [], fns.jP) };
}

export const oracle = load();
