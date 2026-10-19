// Tiny in-memory store. The only thing persisted to localStorage is the ID of the group the
// person last looked at (a per-device convenience). No tokens, no money, no secrets.
import { safeStorage } from "./utils.js";

export const state = {
  user: null,     // { id, email }
  profile: null,  // { id, display_name, avatar_path }
  groups: [],     // [{ id, name, role, joined_at, created_at }]
  activeGroupId: null,
};

const listeners = new Set();
export function setState(patch) {
  Object.assign(state, patch);
  listeners.forEach((fn) => fn(state));
}
export function subscribe(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export const isManagerRole = (role) => role === "admin" || role === "treasurer";
export const activeGroup = () => state.groups.find((g) => g.id === state.activeGroupId) ?? null;
export const groupById = (id) => state.groups.find((g) => g.id === id) ?? null;
export const roleIn = (groupId) => groupById(groupId)?.role ?? null;

const key = (uid) => `sv.activeGroup.${uid}`;

export function chooseActiveGroup(preferredId = null) {
  const uid = state.user?.id;
  const store = safeStorage();
  const saved = uid && store ? store.getItem(key(uid)) : null;
  const pick = [preferredId, state.activeGroupId, saved].find((id) => id && groupById(id)) ?? state.groups[0]?.id ?? null;
  setActiveGroup(pick);
}

export function setActiveGroup(id) {
  const uid = state.user?.id;
  const store = safeStorage();
  if (uid && store) {
    try {
      if (id) store.setItem(key(uid), id);
      else store.removeItem(key(uid));
    } catch { /* storage full or blocked: ignore */ }
  }
  setState({ activeGroupId: id });
}

export function resetState() {
  setState({ user: null, profile: null, groups: [], activeGroupId: null });
}
