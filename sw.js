const CACHE = "platplant-v2";
const FILES = ["./", "./index.html", "./planten-db.js", "./manifest.webmanifest", "./icon-192.png", "./icon-512.png"];

self.addEventListener("install", e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(FILES))); self.skipWaiting(); });
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))));
  self.clients.claim();
});
self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin) return;
  e.respondWith(
    fetch(e.request).then(r => {
      if (r.ok) { const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); }
      return r.ok ? r : caches.match(e.request).then(m => m || r);
    }).catch(() => caches.match(e.request).then(r => r || caches.match("./index.html")))
  );
});

/* ---------- daily check in the background ---------- */
function openDb() {
  return new Promise((res, rej) => {
    const r = indexedDB.open("platplant", 1);
    r.onupgradeneeded = () => { r.result.createObjectStore("plants", { keyPath: "id" }); r.result.createObjectStore("settings"); };
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
}
function req(db, name, mode, fn) {
  return new Promise((res, rej) => {
    const t = db.transaction(name, mode);
    const q = fn(t.objectStore(name));
    t.oncomplete = () => res(q && q.result);
    t.onerror = () => rej(t.error);
  });
}
const ymd = d => `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-${String(d.getDate()).padStart(2,"0")}`;
const parseYmd = s => { const [y,m,d] = String(s).split("-").map(Number); return new Date(y, m-1, d); };
function season(d) { const m = d.getMonth() + 1; return m >= 4 && m <= 9 ? "groei" : (m === 3 || m === 10) ? "overgang" : "rust"; }
function num(v, d) { const n = Number(v); return v !== "" && v !== null && v !== undefined && Number.isFinite(n) ? n : d; }
function intervalFor(p, s) {
  const g = Math.min(60, Math.max(1, num(p.waterGroeiDagen, 7)));
  const r = Math.min(90, Math.max(1, num(p.waterRustDagen, g * 2)));
  return s === "groei" ? g : s === "rust" ? r : Math.round((g + r) / 2);
}
function needsWater(p, today, s) {
  if (!p.lastWatered) return true;
  const next = parseYmd(p.lastWatered); next.setDate(next.getDate() + intervalFor(p, s));
  return next <= parseYmd(ymd(today));
}
function namesText(list) {
  if (list.length === 1) return list[0];
  if (list.length <= 4) return list.slice(0, -1).join(", ") + " en " + list[list.length - 1];
  return list.slice(0, 3).join(", ") + ` en nog ${list.length - 3} andere`;
}
async function checkPlants() {
  const now = new Date(), hour = now.getHours();
  if (hour < 8 || hour >= 22) return;
  const db = await openDb();
  const settings = (await req(db, "settings", "readonly", s => s.get("meldingen"))) || {};
  if (!settings.aan) return;
  const today = ymd(now);
  if ((await req(db, "settings", "readonly", s => s.get("laatsteMelding"))) === today) return;
  const plants = (await req(db, "plants", "readonly", s => s.getAll())) || [];
  const s = season(now);
  const due = plants.filter(p => needsWater(p, now, s)).map(p => p.label || "Plant");
  if (!due.length) return;
  await self.registration.showNotification("Plat & Plant", {
    body: `${due.length === 1 ? "Water nodig" : `${due.length} planten hebben water nodig`}: ${namesText(due)}.`,
    icon: "icon-192.png", badge: "icon-192.png", tag: "water",
    silent: !!settings.stil, ...(settings.stil ? {} : { vibrate: [200, 100, 200] })
  });
  await req(db, "settings", "readwrite", st => st.put(today, "laatsteMelding"));
}
self.addEventListener("periodicsync", e => { if (e.tag === "plant-check") e.waitUntil(checkPlants().catch(() => {})); });
self.addEventListener("notificationclick", e => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(list => {
    const c = list.find(w => "focus" in w);
    return c ? c.focus() : self.clients.openWindow("./");
  }));
});
