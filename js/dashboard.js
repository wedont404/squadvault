// Dashboard: greeting, key numbers, active-event progress, recent activity, quick actions.
import { state, activeGroup, isManagerRole } from "./state.js";
import { fetchEvents, fetchFinancials, fetchContributions, fetchExpenses, buildActivity, finOrEmpty } from "./data.js";
import { html, formatRWF, sum, daysUntil, formatDate } from "./utils.js";
import { loadInto, mount, on, statCard, eventProgressCard, emptyState, skeletonPage, icon } from "./ui.js";
import { activityRows } from "./components.js";
import { openCreateGroupDialog } from "./groups.js";
import { openJoinDialog } from "./invitations.js";
import { returnsAlert } from "./momo.js";

const greeting = () => {
  const h = new Date().getHours();
  return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening";
};

export async function renderDashboard({ outlet, isCurrent }) {
  await loadInto(outlet, {
    isCurrent,
    skeleton: skeletonPage(),
    load: async () => {
      const ids = state.groups.map((g) => g.id);
      if (!ids.length) return null;
      const [events, fin, myPending, contributions, expenses] = await Promise.all([
        fetchEvents(ids),
        fetchFinancials(ids),
        fetchContributions({ userId: state.user.id, status: "pending", limit: 50 }),
        fetchContributions({ limit: 10 }),
        fetchExpenses({ limit: 10 }),
      ]);
      return { events, fin, myPending, contributions, expenses };
    },
    render: (data) => {
      const name = (state.profile?.display_name ?? "there").split(" ")[0];
      const head = html`<div class="page-head"><div><p class="eyebrow">${greeting()}</p>
        <h1>${name}, let's save.</h1><p class="sub">Save together. Celebrate together.</p></div></div>`;

      if (!data) {
        mount(outlet, html`${head}${emptyState({
          iconName: "users",
          title: "Start your first squad",
          text: "Create a private savings group for a wedding, birthday, trip or anything you're chasing together, or join one with an invitation code.",
          actions: html`<button class="btn primary" type="button" data-create-group>${icon("plus")} Create a group</button>
            <button class="btn" type="button" data-join>${icon("ticket")} Join with a code</button>`,
        })}`);
        wire(outlet);
        return;
      }

      const { events, fin, myPending, contributions, expenses } = data;
      const active = events.filter((e) => e.status === "active");
      const upcoming = active.filter((e) => e.event_date && daysUntil(e.event_date) >= 0).sort((a, b) => a.event_date.localeCompare(b.event_date));
      const totalVerified = sum([...fin.values()], (f) => f.paid_total);
      const myPendingTotal = sum(myPending, (c) => c.amount);
      const group = activeGroup();
      const manager = isManagerRole(group?.role);
      const next = upcoming[0];

      mount(outlet, html`${head}
        <div class="grid cols-4">
          ${statCard({ label: "Active groups", value: state.groups.length, hint: group ? `Viewing ${group.name}` : "", tone: "cyan", iconName: "users" })}
          ${statCard({ label: "Verified savings", value: formatRWF(totalVerified), hint: "Paid contributions only", tone: "green", iconName: "shield" })}
          ${statCard({ label: "My pending", value: formatRWF(myPendingTotal), hint: myPending.length ? `${myPending.length} waiting for confirmation. Not counted yet` : "Nothing waiting", iconName: "clock" })}
          ${statCard({ label: "Upcoming events", value: upcoming.length, hint: next ? `Next: ${next.name}, ${formatDate(next.event_date)}` : "No dated events", tone: "violet", iconName: "calendar" })}
        </div>

        ${returnsAlert(events, fin)}

        <div class="section"><div class="section-head"><h2>Quick actions</h2></div>
          <div class="actions">
            <a class="btn primary" href="#/contributions">${icon("wallet")} Contribute</a>
            ${manager ? html`<a class="btn" href="#/groups/${group.id}">${icon("plus")} New event</a><a class="btn" href="#/invitations">${icon("ticket")} Invite someone</a>` : ""}
            <button class="btn" type="button" data-join>${icon("link")} Join with a code</button>
            <button class="btn ghost" type="button" data-create-group>${icon("users")} New group</button>
          </div></div>

        <div class="section"><div class="section-head"><h2>Savings progress</h2><a href="#/events">All events</a></div>
          ${active.length
            ? html`<div class="grid auto">${active.slice(0, 6).map((e) => eventProgressCard(e, finOrEmpty(fin, e.id), `#/events/${e.id}`))}</div>`
            : emptyState({ iconName: "calendar", title: "No active events yet", text: manager ? "Create an event with a target amount to start collecting." : "Ask a group admin or treasurer to create an event." })}
        </div>

        <div class="section"><div class="section-head"><h2>Recent activity</h2></div>
          ${(() => {
            const items = buildActivity(contributions, expenses, 8);
            return items.length
              ? html`<div class="card flush"><div class="list">${activityRows(items)}</div></div>`
              : emptyState({ iconName: "trend", title: "Nothing yet", text: "Contributions and expenses will show up here as they happen." });
          })()}
        </div>`);
      wire(outlet);
    },
  });
}

function wire(root) {
  on(root, "click", "[data-create-group]", () => openCreateGroupDialog());
  on(root, "click", "[data-join]", () => openJoinDialog());
}
