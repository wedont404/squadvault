// Expenses: record (admins/treasurers), list, edit, private receipts via signed URLs.
// Receipts live in a PRIVATE bucket at <group>/<event>/<uuid>.<ext>; the database verifies the path,
// so arbitrary URLs can never be attached as "proof".
import { activeGroup, isManagerRole } from "./state.js";
import { fetchEvents, fetchEventFinancials, fetchExpenses } from "./data.js";
import { supabase, rpc, AppError } from "./supabase.js";
import { navigate } from "./router.js";
import { config } from "./config.js";
import { html, formatRWF, parseRWF } from "./utils.js";
import {
  $, mount, on, icon, toast, openModal, loadInto, freshView, setBusy, field, formData, formMessage, formMsgSlot,
  setFieldError, clearFieldErrors, statCard, emptyState, skeletonCards,
} from "./ui.js";
import { expenseRow, openReceipt } from "./components.js";

const EXT = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "application/pdf": "pdf" };

function checkFile(file) {
  if (!file || !file.size) return null;
  if (!EXT[file.type]) return "Receipts must be JPG, PNG, WebP or PDF files.";
  if (file.size > config.limits.receiptMaxBytes) return "That file is over 5 MB.";
  return null;
}

async function uploadReceipt(event, file) {
  const path = `${event.group_id}/${event.id}/${crypto.randomUUID()}.${EXT[file.type]}`;
  const { error } = await supabase.storage.from("receipts").upload(path, file, { contentType: file.type, upsert: false });
  if (error) throw new AppError("The receipt couldn't be uploaded. You may not have permission, or the file was rejected.", "upload_failed", error);
  return path;
}

function expenseForm({ expense = null, available }) {
  return html`<form class="form" novalidate>
    ${field({ name: "amount", label: "Amount", prefix: "RWF", value: expense ? String(expense.amount) : "", attrs: 'inputmode="numeric" autofocus', help: `Available for this event: ${formatRWF(available)}` })}
    ${field({ name: "description", label: "What was it for?", value: expense?.description ?? "", attrs: 'maxlength="200"', placeholder: "e.g. Venue deposit" })}
    <div class="field" data-field="receipt"><label for="f-receipt">${expense?.receipt_path ? "Replace receipt (optional)" : "Receipt (optional)"}</label>
      <input class="input" id="f-receipt" name="receipt" type="file" accept="image/jpeg,image/png,image/webp,application/pdf">
      <div class="help">JPG, PNG, WebP or PDF, up to 5 MB. Stored privately; only group members can view it.</div><div class="error" id="err-receipt" role="alert"></div></div>
    ${formMsgSlot()}
    <div class="foot"><button class="btn ghost" type="button" data-cancel>Cancel</button><button class="btn primary" type="submit">${expense ? "Save changes" : "Record expense"}</button></div>
  </form>`;
}

function bindExpenseForm(m, { event, available, expense, onDone }) {
  const form = $("form", m.el);
  $("[data-cancel]", m.el).addEventListener("click", () => m.close());
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    clearFieldErrors(form);
    const v = formData(form);
    const amount = parseRWF(v.amount);
    const description = v.description.trim();
    const file = $("#f-receipt", form).files[0];
    if (!amount) return setFieldError(form, "amount", "Enter a whole amount in RWF.");
    if (amount > available) return setFieldError(form, "amount", `That's more than the verified funds available (${formatRWF(available)}).`);
    if (description.length < 2 || description.length > 200) return setFieldError(form, "description", "Use 2 to 200 characters.");
    const fileProblem = checkFile(file);
    if (fileProblem) return setFieldError(form, "receipt", fileProblem);

    const btn = $('button[type="submit"]', form);
    setBusy(btn, true, "Saving…");
    try {
      const path = file?.size ? await uploadReceipt(event, file) : null;
      if (expense) await rpc("update_expense", { p_expense_id: expense.id, p_amount: amount, p_description: description, p_receipt_path: path });
      else await rpc("record_expense", { p_event_id: event.id, p_amount: amount, p_description: description, p_receipt_path: path });
      toast(expense ? "Expense updated." : "Expense recorded.", "success");
      m.close();
      onDone?.();
    } catch (err) {
      formMessage(form, "error", err.message);
      setBusy(btn, false);
    }
  });
}

export function openExpenseDialog({ event, fin, onDone }) {
  const m = openModal({ title: `Record expense · ${event.name}`, content: expenseForm({ available: fin.available_funds }) });
  bindExpenseForm(m, { event, available: fin.available_funds, onDone });
}

function openEditDialog(expense, event, fin, onDone) {
  const available = fin.available_funds + expense.amount; // this expense's own amount is freed while editing
  const m = openModal({ title: "Edit expense", content: expenseForm({ expense, available }) });
  bindExpenseForm(m, { event, available, expense, onDone });
}

export async function renderExpenses({ outlet, query, isCurrent }) {
  const group = activeGroup();
  if (!group) {
    mount(outlet, html`<div class="page-head"><h1>Expenses</h1></div>${emptyState({ iconName: "users", title: "Pick or create a group first", text: "Expenses are recorded against events inside a group.", actions: html`<a class="btn primary" href="#/groups">Go to my groups</a>` })}`);
    return;
  }
  const manager = isManagerRole(group.role);

  const draw = async () => {
    const view = freshView(outlet);
    await loadInto(view, {
      isCurrent,
      skeleton: skeletonCards(2),
      load: async () => {
        const events = (await fetchEvents([group.id])).filter((e) => e.status !== "cancelled");
        const event = events.find((e) => e.id === query.event) ?? events[0] ?? null;
        if (!event) return { events, event: null };
        const [fin, expenses] = await Promise.all([fetchEventFinancials(event.id), fetchExpenses({ eventId: event.id, limit: 100 })]);
        return { events, event, fin, expenses };
      },
      render: ({ events, event, fin, expenses }) => {
        if (!event) {
          mount(view, html`<div class="page-head"><h1>Expenses</h1></div>${emptyState({ iconName: "calendar", title: "No events to spend against", text: "Create an event and collect contributions first.", actions: html`<a class="btn" href="#/events">View events</a>` })}`);
          return;
        }
        mount(view, html`<div class="page-head"><div><h1>Expenses</h1><p class="sub">in ${group.name}</p></div>
          <div class="actions">
            <div class="field" style="min-width:220px"><label class="sr-only" for="f-ev">Event</label>
              <select class="select" id="f-ev" data-event>${events.map((e) => html`<option value="${e.id}" ${e.id === event.id ? "selected" : ""}>${e.name}</option>`)}</select></div>
            ${manager ? html`<button class="btn primary" type="button" data-add>${icon("plus")} Record expense</button>` : ""}</div></div>
          <div class="grid cols-4">
            ${statCard({ label: "Verified collected", value: formatRWF(fin.paid_total), tone: "green", iconName: "shield" })}
            ${statCard({ label: "Total expenses", value: formatRWF(fin.expenses_total), tone: "violet", iconName: "receipt" })}
            ${statCard({ label: "Available funds", value: formatRWF(fin.available_funds), hint: "Verified − expenses", tone: "cyan", iconName: "wallet" })}
            ${statCard({ label: "Pending (not counted)", value: formatRWF(fin.pending_total), iconName: "clock" })}
          </div>
          <div class="section"><div class="section-head"><h2>History</h2></div>
            ${expenses.length
              ? html`<div class="card flush"><div class="list">${expenses.map((x) => expenseRow(x, { canEdit: manager, showEvent: false }))}</div></div>`
              : emptyState({ iconName: "receipt", title: "No expenses recorded", text: manager ? "Record what you spend, and attach receipts for transparency." : "Admins and treasurers record expenses here." })}</div>
          ${manager ? "" : html`<p class="faint" style="margin-top:16px">Only admins and treasurers can add or edit expenses.</p>`}`);

        on(view, "change", "[data-event]", (_, s) => navigate(`/expenses?event=${s.value}`));
        on(view, "click", "[data-receipt]", (_, b) => openReceipt(b.dataset.receipt));
        on(view, "click", "[data-add]", () => openExpenseDialog({ event, fin, onDone: draw }));
        on(view, "click", "[data-edit-expense]", (_, b) => {
          const x = expenses.find((e) => e.id === b.dataset.editExpense);
          if (x) openEditDialog(x, event, fin, draw);
        });
      },
    });
  };
  await draw();
}
