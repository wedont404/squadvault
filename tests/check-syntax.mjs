// Fast static check: every browser/Edge JS file must parse. Run: npm run check
import { readdirSync, statSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join, extname } from "node:path";
const root = new URL("..", import.meta.url).pathname;
const walk = (d) => readdirSync(d).flatMap((f) => { const p = join(d, f); return /node_modules|\.git$/.test(p) ? [] : statSync(p).isDirectory() ? walk(p) : [p]; });
const files = walk(root).filter((f) => [".js", ".mjs"].includes(extname(f)));
let bad = 0;
for (const f of files) { try { execFileSync(process.execPath, ["--check", f], { stdio: "pipe" }); } catch (e) { bad++; console.error(`SYNTAX ERROR in ${f}\n${e.stderr}`); } }
console.log(bad ? `${bad} file(s) failed` : `${files.length} files parse cleanly`);
process.exit(bad ? 1 : 0);
