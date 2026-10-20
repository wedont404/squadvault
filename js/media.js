// Pictures: shrink on the phone before upload (saves data), upload to the private "group-photos" bucket,
// and show them through short-lived signed URLs. Elements opt in with data-sbimg="<storage path>"
// (<img> gets src, anything else gets a background-image). A MutationObserver fills them in automatically,
// so views only have to render the attribute.
import { supabase, AppError } from "./supabase.js";
import { config } from "./config.js";

const BUCKET = "group-photos";
export const PHOTO_TYPES = ["image/jpeg", "image/png", "image/webp"];
const MAX_EDGE = 1600;
const TTL = 3600; // seconds a signed URL lives
const cache = new Map(); // path -> { url, until }

/** Returns a smaller JPEG blob (max 1600px) or the original file if the browser can't do it. */
export async function compressImage(file) {
  if (!file || !PHOTO_TYPES.includes(file.type)) throw new AppError("Choose a JPG, PNG or WebP picture.", "invalid_photo");
  try {
    const bmp = await createImageBitmap(file);
    const scale = Math.min(1, MAX_EDGE / Math.max(bmp.width, bmp.height));
    const w = Math.max(1, Math.round(bmp.width * scale)), h = Math.max(1, Math.round(bmp.height * scale));
    const canvas = document.createElement("canvas");
    canvas.width = w; canvas.height = h;
    canvas.getContext("2d").drawImage(bmp, 0, 0, w, h);
    bmp.close?.();
    const blob = await new Promise((res) => canvas.toBlob(res, "image/jpeg", 0.82));
    if (blob && blob.size < file.size) return blob;
  } catch { /* fall back to the original */ }
  if (file.size > config.limits.photoMaxBytes) throw new AppError("That picture is too big. Try a smaller one (under 3 MB).", "invalid_photo");
  return file;
}

const EXT = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" };

/** Uploads to <group>/<me>/<uuid>.<ext>. Returns the storage path. */
export async function uploadGroupImage(groupId, userId, file) {
  const blob = await compressImage(file);
  if (blob.size > config.limits.photoMaxBytes) throw new AppError("That picture is too big. Try a smaller one (under 3 MB).", "invalid_photo");
  const type = EXT[blob.type] ? blob.type : "image/jpeg";
  const path = `${groupId}/${userId}/${crypto.randomUUID()}.${EXT[type]}`;
  const { error } = await supabase.storage.from(BUCKET).upload(path, blob, { contentType: type, upsert: false });
  if (error) throw new AppError("The picture couldn't be uploaded. Check your connection and try again.", "upload_failed", error);
  return path;
}

export async function removeGroupImage(path) {
  try { await supabase.storage.from(BUCKET).remove([path]); } catch { /* the database row is already gone */ }
  cache.delete(path);
}

/** Batch-sign the paths we don't already have. */
export async function signedUrls(paths) {
  const now = Date.now();
  const need = [...new Set(paths)].filter((p) => p && !(cache.get(p)?.until > now));
  if (need.length) {
    const { data, error } = await supabase.storage.from(BUCKET).createSignedUrls(need, TTL);
    if (error) console.error(error);
    for (const row of data ?? []) if (row.signedUrl && row.path) cache.set(row.path, { url: row.signedUrl, until: now + (TTL - 300) * 1000 });
  }
  return new Map(paths.map((p) => [p, cache.get(p)?.url ?? null]));
}

let queued = false;
function fill(root) {
  const els = [...root.querySelectorAll("[data-sbimg]:not([data-sbdone])")];
  if (!els.length) return;
  signedUrls(els.map((e) => e.dataset.sbimg)).then((map) => {
    for (const el of els) {
      const url = map.get(el.dataset.sbimg);
      if (!url || !el.isConnected) continue;
      if (el.tagName === "IMG") el.src = url; else el.style.backgroundImage = `url("${url}")`;
      el.dataset.sbdone = "1";
      el.classList.add("loaded");
    }
  });
}

let observer = null;
/** Start filling data-sbimg elements under `root` (call once for the app outlet / modal root). */
export function watchImages(root = document.body) {
  if (observer) return;
  observer = new MutationObserver(() => {
    if (queued) return;
    queued = true;
    queueMicrotask(() => { queued = false; fill(document.body); });
  });
  observer.observe(root, { childList: true, subtree: true });
  fill(root);
}
