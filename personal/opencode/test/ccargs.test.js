import { test, expect } from "bun:test";
import * as agents from "../core/agents.js";
import { oracle } from "./cc-oracle.js";

// core/agents.js renderCcArgs against CC 2.1.302's own ZFe (cc-oracle.js reads it from the CC
// binary). Plain-word arguments only: the oracle's argument splitter is CC's whitespace fallback.
const BODIES = [
  "",
  "no placeholders at all",
  "awk '{print $1}' and $0",
  "$0 $1 $2 $10 $ARGUMENTS",
  "first=$ARGUMENTS[0] fifth=$ARGUMENTS[4] all=$ARGUMENTS",
  "esc \\$0 and \\\\$0 and \\$ARGUMENTS and \\$ARGUMENTS[1] and \\$x",
  "word $0abc $0_x $0-x $0.x",
  "price $5.00 or $",
  "nested ${CLAUDE_PLUGIN_ROOT} $0 ${0}",
  "sentinels \uFFFF \uFFFE $0",
];
const ARGS = [undefined, null, "", "   ", "main", "a b", "a b c d e f g h i j k", "$1 $ARGUMENTS", "!x `!y` z!`w`", "a\tb\nc"];

test.skipIf(!oracle.ok)("renderCcArgs equals CC's ZFe on every body x plain-word argument pair", () => {
  let n = 0;
  for (const body of BODIES) {
    for (const args of ARGS) {
      expect(agents.renderCcArgs?.(body, args)).toBe(oracle.ccCommand(body, args));
      n++;
    }
  }
  expect(n).toBe(BODIES.length * ARGS.length);
});

// Always runs: the oracle's own outputs for these inputs, recorded from CC 2.1.302, so the port is
// pinned even where the CC binary is absent.
test("renderCcArgs: CC 2.1.302's outputs, stated literally", () => {
  const body = "awk '{print $1}' first $0 [$ARGUMENTS[1]] \\$1 $1abc all=$ARGUMENTS";
  expect(agents.renderCcArgs?.(body, "")).toBe("awk '{print $1}' first $0 [$ARGUMENTS[1]] $1 $1abc all=");
  expect(agents.renderCcArgs?.(body, "x")).toBe("awk '{print $1}' first x [$ARGUMENTS[1]] $1 $1abc all=x");
  expect(agents.renderCcArgs?.(body, "x y")).toBe("awk '{print y}' first x [y] $1 $1abc all=x y");
  expect(agents.renderCcArgs?.("no placeholders", "x")).toBe("no placeholders\n\nARGUMENTS: x");
  expect(agents.renderCcArgs?.("v $0", "!x")).toBe("v \\!x");
  expect(agents.renderCcArgs?.("v $0", undefined)).toBe("v $0");
});

test.skipIf(!oracle.ok)("the oracle is live: it fills $0, keeps an unfilled $1 and appends ARGUMENTS when nothing was filled", () => {
  expect(oracle.ccCommand("$0|$1", "a")).toBe("a|$1");
  expect(oracle.ccCommand("none", "a")).toBe("none\n\nARGUMENTS: a");
});

// Not oracle-checked: CC splits with a tree-sitter bash parse the oracle cannot run. Expected values
// follow that parse's word extraction as read from the bundle (quotes stripped, backslashes kept
// inside "...", removed in a bare word).
test("ccArgv: quotes group, backslashes, an unterminated quote falls back to a whitespace split", () => {
  expect(agents.ccArgv?.("")).toEqual([]);
  expect(agents.ccArgv?.("  ")).toEqual([]);
  expect(agents.ccArgv?.("a  b")).toEqual(["a", "b"]);
  expect(agents.ccArgv?.(`"a b" c`)).toEqual(["a b", "c"]);
  expect(agents.ccArgv?.(`'a "b' c`)).toEqual([`a "b`, "c"]);
  expect(agents.ccArgv?.(`x"y z"w`)).toEqual(["xy zw"]);
  expect(agents.ccArgv?.(`a\\ b`)).toEqual(["a b"]);
  expect(agents.ccArgv?.(`"a\\"b"`)).toEqual([`a\\"b`]);
  expect(agents.ccArgv?.(`"" x`)).toEqual(["", "x"]);
  expect(agents.ccArgv?.(`"open x`)).toEqual([`"open`, "x"]);
});
