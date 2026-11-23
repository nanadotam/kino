const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

// macOS shows sizes in base-10 units, so match it.
function fmt(b) {
  if (b == null) return "—";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (b >= 1000 && i < u.length - 1) { b /= 1000; i++; }
  return (i >= 3 ? b.toFixed(1) : Math.round(b)) + " " + u[i];
}

const state = {
  tab: "clean",
  scan: null,
  selected: new Set(),
  large: [],
  largeSel: new Set(),
  busy: false,
};

/* ---------- toast & dialog ---------- */
let toastTimer;
function toast(msg, error = false) {
  const t = $("#toast");
  t.textContent = msg;
  t.className = "toast" + (error ? " error" : "");
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (t.hidden = true), 4000);
}

function dialog({ title, html, ok = "OK", destructive = false }) {
  return new Promise((resolve) => {
    $("#dlg-title").textContent = title;
    $("#dlg-body").innerHTML = html;
    const okBtn = $("#dlg-ok");
    okBtn.textContent = ok;
    okBtn.className = "btn" + (destructive ? " destructive" : "");
    $("#dialog").hidden = false;
    okBtn.focus();
    const done = (v) => {
      $("#dialog").hidden = true;
      okBtn.onclick = $("#dlg-cancel").onclick = null;
      document.removeEventListener("keydown", onKey);
      resolve(v);
    };
    const onKey = (e) => { if (e.key === "Escape") done(false); };
    document.addEventListener("keydown", onKey);
    okBtn.onclick = () => done(true);
    $("#dlg-cancel").onclick = () => done(false);
  });
}

/* ---------- disk ---------- */
function renderDisk(free, total) {
  if (!total) return;
  $("#free").textContent = fmt(free);
  const used = total - free;
  const pct = (used / total) * 100;
  $("#disk-fill").style.width = pct.toFixed(1) + "%";
  $("#disk-fill").classList.toggle("full", pct > 90);
  $("#disk-caption").textContent = `${fmt(used)} used of ${fmt(total)}` + (pct > 90 ? " · your disk is almost full" : "");
}
async function refreshDisk() {
  const d = await invoke("disk");
  renderDisk(d.free, d.total);
}

/* ---------- tabs ---------- */
document.querySelectorAll(".tab").forEach((b) =>
  b.addEventListener("click", () => {
    state.tab = b.dataset.tab;
    document.querySelectorAll(".tab").forEach((x) => x.classList.toggle("active", x === b));
    for (const p of ["clean", "large", "storage"]) $("#panel-" + p).hidden = p !== state.tab;
    renderActionBar();
  })
);

/* ---------- action bar ---------- */
function renderActionBar() {
  const bar = $("#actionbar"), btn = $("#action-btn"), txt = $("#action-text");
  bar.hidden = state.tab === "storage";
  let n = 0, bytes = 0;
  if (state.tab === "clean") {
    for (const it of state.scan?.items ?? []) if (state.selected.has(it.id)) { n++; bytes += it.bytes; }
    btn.textContent = "Clean selected";
    btn.className = "btn";
  } else {
    for (const f of state.large) if (state.largeSel.has(f.path)) { n++; bytes += f.bytes; }
    btn.textContent = "Move to Trash";
    btn.className = "btn destructive";
  }
  txt.textContent = n ? `${n} selected · ${fmt(bytes)}` : "Nothing selected";
  btn.disabled = !n || state.busy;
  let cleanBytes = 0;
  for (const it of state.scan?.items ?? []) if (state.selected.has(it.id)) cleanBytes += it.bytes;
  $("#selected-total").textContent = fmt(state.tab === "large" ? bytes : cleanBytes);
}

$("#action-btn").addEventListener("click", () => (state.tab === "clean" ? doClean() : doTrashLarge()));

/* ---------- scan ---------- */
let unlistenProgress;
async function scan() {
  $("#scanning").hidden = false;
  $("#clean-content").hidden = true;
  $("#scan-fill").style.width = "0";
  unlistenProgress?.();
  unlistenProgress = await listen("scan-progress", (e) => {
    const { done, total, label } = e.payload;
    $("#scan-fill").style.width = (done / total) * 100 + "%";
    $("#scan-label").textContent = label;
  });
  try {
    const r = await invoke("scan_junk");
    state.scan = r;
    state.selected = new Set(r.items.filter((i) => !i.risky).map((i) => i.id));
    renderDisk(r.free, r.total);
    renderClean();
  } catch (e) {
    toast("Scan failed: " + e, true);
  } finally {
    unlistenProgress?.();
    $("#scanning").hidden = true;
    $("#clean-content").hidden = false;
  }
}

function itemRow(it) {
  return `<label class="item">
    <input type="checkbox" data-id="${esc(it.id)}" ${state.selected.has(it.id) ? "checked" : ""}/>
    <div class="grow">
      <div class="strong name">${esc(it.name)}${it.risky ? '<span class="badge warn">Careful</span>' : ""}</div>
      <div class="muted xs">${esc(it.note)}</div>
      ${it.path ? `<div class="muted path">${esc(it.path)}</div>` : ""}
    </div>
    <div class="size">${fmt(it.bytes)}</div>
  </label>`;
}

function renderClean() {
  const r = state.scan;
  const safe = r.items.filter((i) => !i.risky), careful = r.items.filter((i) => i.risky);
  $("#safe-list").innerHTML = safe.length
    ? safe.map(itemRow).join("")
    : `<div class="empty"><div class="ico-lg">✨</div><div class="strong">All clean</div><div class="muted sm">No app junk worth clearing right now.</div></div>`;
  $("#careful-wrap").hidden = !careful.length;
  $("#careful-list").innerHTML = careful.map(itemRow).join("");
  document.querySelectorAll("#clean-content input[type=checkbox]").forEach((cb) =>
    cb.addEventListener("change", () => {
      cb.checked ? state.selected.add(cb.dataset.id) : state.selected.delete(cb.dataset.id);
      renderActionBar();
    })
  );
  $("#trash-size").textContent = r.trash_bytes != null
    ? `Files you already deleted · ${fmt(r.trash_bytes)}`
    : "Files you already deleted.";
  const adminTotal = r.admin.reduce((s, a) => s + (a.bytes || 0), 0);
  const snaps = r.admin.find((a) => a.id === "snapshots");
  $("#admin-desc").textContent = `System caches and logs · ${fmt(adminTotal)}` + (snaps ? " · plus Time Machine snapshots" : "");
  renderActionBar();
}

$("#rescan").addEventListener("click", scan);
$("#select-all").addEventListener("click", () => {
  for (const i of state.scan?.items ?? []) if (!i.risky) state.selected.add(i.id);
  renderClean();
});
$("#select-none").addEventListener("click", () => { state.selected.clear(); renderClean(); });

async function doClean() {
  const items = state.scan.items.filter((i) => state.selected.has(i.id));
  const bytes = items.reduce((s, i) => s + i.bytes, 0);
  const risky = items.filter((i) => i.risky);
  const ok = await dialog({
    title: `Clear ${items.length} item${items.length > 1 ? "s" : ""}?`,
    html: `About <b>${fmt(bytes)}</b> will be removed for good. It doesn't go to the Trash. Apps rebuild their caches on their own.` +
      (risky.length ? `<br><br><span class="badge warn">Careful</span> This includes <b>${risky.map((r) => esc(r.name)).join(", ")}</b>, which can't be rebuilt.` : ""),
    ok: "Clean",
    destructive: risky.length > 0,
  });
  if (!ok) return;
  setBusy(true, "Cleaning…");
  try {
    const r = await invoke("clean", { ids: items.map((i) => i.id) });
    toast(`Done! Freed ${fmt(r.freed)}.`);
  } catch (e) {
    toast("Something went wrong: " + e, true);
  }
  setBusy(false);
  await scan();
}

function setBusy(b, label) {
  state.busy = b;
  if (b) $("#action-btn").textContent = label;
  renderActionBar();
}

/* ---------- trash ---------- */
$("#empty-trash").addEventListener("click", async () => {
  const ok = await dialog({
    title: "Empty the Trash?",
    html: "Everything in the Trash will be permanently deleted. macOS may ask whether Kino can control Finder. Click OK.",
    ok: "Empty Trash",
    destructive: true,
  });
  if (!ok) return;
  try {
    await invoke("empty_trash");
    toast("Trash emptied.");
    refreshDisk();
  } catch (e) {
    toast(String(e), true);
  }
});

/* ---------- admin ---------- */
$("#admin-btn").addEventListener("click", async () => {
  const admin = state.scan?.admin ?? [];
  const html =
    "These live in protected system folders. macOS will ask for the password you use to log in. Kino never sees or stores it.<div class='list card' style='margin-top:12px'>" +
    admin
      .map(
        (a) => `<label class="item"><input type="checkbox" class="adm" value="${esc(a.id)}" checked/>
          <div class="grow"><div class="strong">${esc(a.name)}</div><div class="muted xs">${esc(a.note)}</div></div>
          <div class="size">${a.bytes != null ? fmt(a.bytes) : ""}</div></label>`
      )
      .join("") +
    "</div>";
  const ok = await dialog({ title: "Clean system junk", html, ok: "Continue" });
  if (!ok) return;
  const ids = [...document.querySelectorAll(".adm:checked")].map((c) => c.value);
  if (!ids.length) return;
  const before = (await invoke("disk")).free;
  try {
    await invoke("clean_admin", { ids });
    const after = (await invoke("disk")).free;
    toast(`System junk cleaned. Freed about ${fmt(Math.max(0, after - before))}.`);
    scan();
  } catch (e) {
    if (e !== "cancelled") toast("Couldn't clean system junk: " + e, true);
  }
});

/* ---------- large files ---------- */
$("#find-large").addEventListener("click", async () => {
  const btn = $("#find-large");
  btn.disabled = true;
  btn.textContent = "Searching…";
  $("#large-empty").hidden = true;
  $("#large-list").hidden = false;
  $("#large-list").innerHTML = `<div class="scanning"><div class="spinner"></div><div class="muted sm">Looking through your files…</div></div>`;
  try {
    state.large = await invoke("find_large_files", { minMb: Number($("#min-size").value) });
    state.largeSel.clear();
    renderLarge();
  } catch (e) {
    toast("Search failed: " + e, true);
  }
  btn.disabled = false;
  btn.textContent = "Find";
});

function renderLarge() {
  const list = $("#large-list");
  if (!state.large.length) {
    list.innerHTML = `<div class="empty"><div class="ico-lg">✨</div><div class="strong">No big files found</div><div class="muted sm">Try a smaller size.</div></div>`;
  } else {
    list.innerHTML = state.large
      .map(
        (f, i) => `<label class="item">
        <input type="checkbox" data-i="${i}" ${state.largeSel.has(f.path) ? "checked" : ""}/>
        <div class="grow"><div class="strong name">${esc(f.name)}</div><div class="muted path">${esc(f.display)}</div></div>
        <button class="btn ghost sm reveal" data-i="${i}">Show</button>
        <div class="size">${fmt(f.bytes)}</div></label>`
      )
      .join("");
    list.querySelectorAll("input").forEach((cb) =>
      cb.addEventListener("change", () => {
        const p = state.large[cb.dataset.i].path;
        cb.checked ? state.largeSel.add(p) : state.largeSel.delete(p);
        renderActionBar();
      })
    );
    list.querySelectorAll(".reveal").forEach((b) =>
      b.addEventListener("click", (e) => {
        e.preventDefault();
        invoke("reveal", { path: state.large[b.dataset.i].path });
      })
    );
  }
  renderActionBar();
}

async function doTrashLarge() {
  const files = state.large.filter((f) => state.largeSel.has(f.path));
  const ok = await dialog({
    title: `Move ${files.length} file${files.length > 1 ? "s" : ""} to the Trash?`,
    html: `<b>${fmt(files.reduce((s, f) => s + f.bytes, 0))}</b>. You can still get them back from the Trash until you empty it.`,
    ok: "Move to Trash",
    destructive: true,
  });
  if (!ok) return;
  setBusy(true, "Moving…");
  try {
    const r = await invoke("trash_files", { paths: files.map((f) => f.path) });
    toast(`Moved to Trash (${fmt(r.freed)}). Empty the Trash to free the space.`);
    state.large = state.large.filter((f) => !state.largeSel.has(f.path));
    state.largeSel.clear();
  } catch (e) {
    toast("Couldn't move files: " + e, true);
  }
  setBusy(false);
  renderLarge();
}

/* ---------- storage ---------- */
$("#analyze").addEventListener("click", async () => {
  const btn = $("#analyze");
  btn.disabled = true;
  btn.textContent = "Analyzing…";
  $("#storage-empty").hidden = true;
  const list = $("#storage-list");
  list.hidden = false;
  list.innerHTML = `<div class="scanning"><div class="spinner"></div><div class="muted sm">Measuring folders…</div></div>`;
  try {
    const rows = await invoke("home_usage");
    const max = rows[0]?.bytes || 1;
    list.innerHTML = rows
      .map(
        (r) => `<div class="bar-row"><div class="name sm strong">${esc(r.name)}</div>
        <div class="track"><div style="width:${((r.bytes / max) * 100).toFixed(1)}%"></div></div>
        <div class="size">${fmt(r.bytes)}</div></div>`
      )
      .join("") || `<div class="empty muted sm">Nothing to show.</div>`;
  } catch (e) {
    toast("Couldn't analyze: " + e, true);
  }
  btn.disabled = false;
  btn.textContent = "Analyze";
});
$("#open-settings").addEventListener("click", () => invoke("open_storage_settings"));

/* ---------- onboarding ---------- */
let step = 0;
function showStep() {
  document.querySelectorAll(".tour-step").forEach((s) => (s.hidden = Number(s.dataset.step) !== step));
  document.querySelectorAll(".steps span").forEach((s, i) => s.classList.toggle("on", i === step));
  $("#tour-next").textContent = step === 2 ? "Get started" : "Next";
}
function openTour() { step = 0; showStep(); $("#tour").hidden = false; }
function closeTour() { $("#tour").hidden = true; localStorage.setItem("kino.toured", "1"); }
$("#tour-next").addEventListener("click", () => (step < 2 ? (step++, showStep()) : closeTour()));
$("#tour-skip").addEventListener("click", closeTour);
$("#help-btn").addEventListener("click", openTour);

/* ---------- start ---------- */
document.addEventListener("contextmenu", (e) => e.preventDefault());
if (!localStorage.getItem("kino.toured")) openTour();
refreshDisk();
scan();
