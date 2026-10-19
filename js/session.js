// Shared "reload my memberships" helper used by views after create / join / leave.
import { fetchGroups } from "./data.js";
import { state, setState, chooseActiveGroup } from "./state.js";

export async function reloadGroups(preferGroupId = null) {
  if (!state.user) return;
  const groups = await fetchGroups(state.user.id);
  setState({ groups });
  chooseActiveGroup(preferGroupId);
}
