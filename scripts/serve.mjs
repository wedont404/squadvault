// Zero-dependency static dev server:  node scripts/serve.mjs [port]
// Serves the project over HTTP (the app must never be opened via file://).
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const port = Number(process.argv[2] ?? process.env.PORT ?? 5173);
const types = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml", ".json": "application/json", ".png": "image/png", ".ico": "image/x-icon", ".webmanifest": "application/manifest+json" };

createServer(async (req, res) => {
  try {
    let path = decodeURIComponent(new URL(req.url, "http://x").pathname);
    if (path.endsWith("/")) path += "index.html";
    const file = normalize(join(root, path));
    // Only serve the web app, never SQL, functions, env files or dotfiles.
    const rel = file.slice(root.length + 1);
    if (!file.startsWith(root) || /^(supabase|scripts|tests|node_modules)\b|(^|\/)\./.test(rel) || /\.(env|md|json)$/.test(file)) { res.writeHead(404).end("Not found"); return; }
    const s = await stat(file);
    if (!s.isFile()) throw new Error("nf");
    res.writeHead(200, { "Content-Type": types[extname(file)] ?? "application/octet-stream", "Cache-Control": "no-cache", "X-Content-Type-Options": "nosniff" });
    res.end(await readFile(file));
  } catch {
    res.writeHead(404, { "Content-Type": "text/plain" }).end("Not found");
  }
}).listen(port, () => console.log(`SquadVault running at http://localhost:${port}`));
