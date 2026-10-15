// ─────────────────────────────────────────────────────────────────────────────
// Build-time patch for the dashboard "RLS Policies" tab (Postbase deploy overlay).
//
// UPSTREAM BUG (fixed here, no upstream change needed): in
//   src/app/dashboard/(protected)/[projectId]/database/tables/page.tsx
// the "RLS Policies" tab button seeded the selected table synchronously —
//   onClick={() => { setTab(id); if (id === "rls" && selectedTable) setSelectedRlsTable(selectedTable); }}
// — while `rlsTables` is only fetched AFTER the tab switches (useEffect on
// `tab === "rls"`). On that first render `rlsTables` is still empty, so
//   const t = rlsTables.find((x) => x.tablename === selectedRlsTable)!;   // undefined
//   … {t.tablename}                                                        // throws
// and the page dies with
//   Application error: a client-side exception has occurred
//   Uncaught TypeError: Cannot read properties of undefined (reading 'tablename')
//
// Repro: Database → Tables → click any table row → click "RLS Policies".
//
// The script applies three surgical fixes:
//   1. the tab button only switches tabs (no premature selection),
//   2. the Tables-tab selection is carried into RLS only once rlsTables is
//      loaded, a selection whose table is gone is cleared, and RLS state is
//      reset when the project changes,
//   3. the render guards the lookup and shows a loading/empty state instead of
//      dereferencing undefined.
//
// It is idempotent (already-patched files are reported and skipped) and FAILS
// THE BUILD if an anchor is missing in both raw and patched form — otherwise an
// upstream refactor would silently ship an unfixed dashboard.
//
// Usage (from apps/web): node scripts/patch-rls-dashboard.mjs
// ─────────────────────────────────────────────────────────────────────────────
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const TARGET = resolve(
  "src/app/dashboard/(protected)/[projectId]/database/tables/page.tsx"
);
const TAG = "[rls-fix]";

const patches = [
  {
    name: "tab button no longer seeds the RLS selection synchronously",
    applied: "onClick={() => setTab(id)}",
    find: /onClick=\{\(\)\s*=>\s*\{\s*setTab\(id\);\s*if\s*\(id === "rls" && selectedTable\)\s*setSelectedRlsTable\(selectedTable\);\s*\}\}/,
    replace: "onClick={() => setTab(id)}",
  },
  {
    name: "RLS selection seeded after the table list loads (+ stale/project resets)",
    applied: "rlsTables.some((t) => t.tablename === selectedTable)",
    find: /\n(\s*)\}, \[tab, fetchRls, fetchTables, fetchHistory\]\);/,
    replace: (m, indent) => `
${indent}}, [tab, fetchRls, fetchTables, fetchHistory]);

${indent}// Carry the Tables-tab selection into RLS, but only once the RLS table list is
${indent}// loaded: seeding it earlier leaves selectedRlsTable pointing at a table name
${indent}// that is not in rlsTables yet (the crash this script fixes).
${indent}useEffect(() => {
${indent}  if (tab !== "rls" || !selectedTable) return;
${indent}  if (rlsTables.some((t) => t.tablename === selectedTable)) setSelectedRlsTable(selectedTable);
${indent}}, [tab, rlsTables, selectedTable]);

${indent}// A selection whose table no longer exists (dropped/renamed) is cleared instead
${indent}// of being rendered.
${indent}useEffect(() => {
${indent}  if (!selectedRlsTable) return;
${indent}  if (rlsTables.length > 0 && !rlsTables.some((t) => t.tablename === selectedRlsTable)) {
${indent}    setSelectedRlsTable(null);
${indent}  }
${indent}}, [rlsTables, selectedRlsTable]);

${indent}// Nothing RLS-related may survive a project switch.
${indent}useEffect(() => {
${indent}  setPolicies([]);
${indent}  setRlsTables([]);
${indent}  setSelectedRlsTable(null);
${indent}}, [projectId]);`,
  },
  {
    name: "render guards the rlsTables lookup (loading + empty state)",
    applied: "if (!t) {",
    find: /\)\s*:\s*\(\(\)\s*=>\s*\{\r?\n(\s*)const t = rlsTables\.find\(\(x\) => x\.tablename === selectedRlsTable\)!;/,
    replace: (m, indent) => `) : rlsLoading && rlsTables.length === 0 ? (
${indent}  <div className="h-full flex items-center justify-center text-zinc-600 text-sm">
${indent}    Loading...
${indent}  </div>
${indent}) : (() => {
${indent}const t = rlsTables.find((x) => x.tablename === selectedRlsTable);
${indent}if (!t) {
${indent}  return (
${indent}    <div className="h-full flex items-center justify-center text-zinc-600 text-sm">
${indent}      Select a table to view its policies
${indent}    </div>
${indent}  );
${indent}}`,
  },
];

let source;
try {
  source = readFileSync(TARGET, "utf8");
} catch (error) {
  console.error(`${TAG} cannot read ${TARGET}:`, error.message);
  process.exit(1);
}

let out = source;
const results = [];

for (const patch of patches) {
  if (out.includes(patch.applied)) {
    results.push([patch.name, "already applied"]);
    continue;
  }
  // A patch must match exactly once: 0 means upstream moved on, >1 means the
  // anchor is too loose and could patch the wrong call site.
  const global = new RegExp(patch.find.source, `${patch.find.flags}g`);
  const matches = out.match(global)?.length ?? 0;
  if (matches === 0) {
    results.push([patch.name, "ANCHOR NOT FOUND"]);
    continue;
  }
  if (matches > 1) {
    results.push([patch.name, `AMBIGUOUS (${matches} matches)`]);
    continue;
  }
  out = out.replace(patch.find, patch.replace);
  results.push([patch.name, "applied"]);
}

const failed = results.filter(
  ([, status]) => status !== "applied" && status !== "already applied"
);

for (const [name, status] of results) {
  console.log(`${TAG} ${status.padEnd(18)} ${name}`);
}

if (failed.length) {
  // Never ship a dashboard whose crash we think we fixed but did not.
  console.error(
    `${TAG} FAILED: ${failed.length} patch(es) could not be applied to\n${TAG}   ${TARGET}\n` +
      `${TAG} Upstream changed the RLS tab code (or an anchor is ambiguous) — re-check the page and update this script.`
  );
  process.exit(1);
}

if (out === source) {
  console.log(`${TAG} nothing to do — the RLS dashboard fix is already in place.`);
} else {
  writeFileSync(TARGET, out);
  const changed = out.split("\n").length - source.split("\n").length;
  console.log(
    `${TAG} patched ${TARGET}\n` +
      `${TAG} lines added: ${changed >= 0 ? "+" : ""}${changed}`
  );
}
