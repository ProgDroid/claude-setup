// Portions of this file are copied from opencode (https://github.com/anomalyco/opencode),
// tag v1.19.0, packages/core/src/util/wildcard.ts:3-14.
// MIT License, Copyright (c) 2025 opencode. The full permission notice is in
// personal/opencode/THIRD_PARTY_NOTICES, which must accompany this file.
//
// OC v1.19.0 wildcard matching (packages/core/src/util/wildcard.ts:3-14), used to find which
// user permission keys apply to an allowed key. `*` -> any run, `?` -> one char, a trailing
// " *" also matches the bare command.
export function wildcardMatch(input, pattern) {
  const normalized = input.replaceAll("\\", "/");
  let escaped = pattern
    .replaceAll("\\", "/")
    .replace(/[.+^${}()|[\]\\]/g, "\\$&")
    .replace(/\*/g, ".*")
    .replace(/\?/g, ".");

  if (escaped.endsWith(" .*")) escaped = escaped.slice(0, -3) + "( .*)?";

  return new RegExp("^" + escaped + "$", process.platform === "win32" ? "si" : "s").test(normalized);
}
