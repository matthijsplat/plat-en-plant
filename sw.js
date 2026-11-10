const CACHE = "gietgenoten-v6";
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
    const r = indexedDB.open("platplant");
    r.onupgradeneeded = () => {
      const d = r.result;
      if (!d.objectStoreNames.contains("plants")) d.createObjectStore("plants", { keyPath: "id" });
      if (!d.objectStoreNames.contains("settings")) d.createObjectStore("settings");
    };
    r.onsuccess = () => { const d = r.result; d.onversionchange = () => d.close(); res(d); };
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
/* Bij een gedeelde lijst: haal de actuele planten op uit de database van het huishouden. */
async function cloudPlants(db) {
  const cfg = await req(db, "settings", "readonly", s => s.get("cloud"));
  if (!cfg || cfg.status !== "active" || !cfg.household || !cfg.session) return null;
  try {
    let s = cfg.session;
    if (s.expires_at - 60 < Date.now() / 1000) {
      const r = await fetch(cfg.url + "/auth/v1/token?grant_type=refresh_token", { method: "POST", headers: { apikey: cfg.key, "Content-Type": "application/json" }, body: JSON.stringify({ refresh_token: s.refresh_token }) });
      const j = await r.json();
      if (!r.ok || !j.access_token) throw 0;
      s = { access_token: j.access_token, refresh_token: j.refresh_token, expires_at: j.expires_at || Math.floor(Date.now() / 1000) + (j.expires_in || 3600), user_id: s.user_id };
      cfg.session = s;
      await req(db, "settings", "readwrite", st => st.put(cfg, "cloud"));
    }
    const r = await fetch(`${cfg.url}/rest/v1/plants?select=id,data&household_id=eq.${encodeURIComponent(cfg.household)}`, { headers: { apikey: cfg.key, Authorization: "Bearer " + s.access_token } });
    if (!r.ok) throw 0;
    return (await r.json()).map(x => ({ ...(x.data || {}), id: x.id }));
  } catch {
    return (await req(db, "settings", "readonly", st => st.get("cloudCache"))) || [];
  }
}
async function checkPlants() {
  const now = new Date(), hour = now.getHours();
  if (hour < 8 || hour >= 22) return;
  const db = await openDb();
  const settings = (await req(db, "settings", "readonly", s => s.get("meldingen"))) || {};
  if (!settings.aan || settings.push) return;
  const today = ymd(now);
  if ((await req(db, "settings", "readonly", s => s.get("laatsteMelding"))) === today) return;
  const plants = (await cloudPlants(db)) ?? ((await req(db, "plants", "readonly", st => st.getAll())) || []);
  const s = season(now);
  if (!plants.some(p => needsWater(p, now, s))) return;
  await showDue(plants, settings);
  await req(db, "settings", "readwrite", st => st.put(today, "laatsteMelding"));
  db.close();
}
function amountFor(p, s) {
  const ml = Math.min(5000, Math.max(10, num(p.waterMl, 200)));
  return s === "rust" ? Math.max(10, Math.round(ml * 0.8 / 10) * 10) : ml;
}
function needsFood(p, today, s) {
  const w = num(p.voedingWeken, 0);
  if (!w || s !== "groei") return false;
  if (!p.lastFed) return true;
  const next = parseYmd(p.lastFed); next.setDate(next.getDate() + w * 7);
  return next <= parseYmd(ymd(today));
}
/* Per plant een regel, bijvoorbeeld "Kerstcactus: 120 ml water + voeding" */
function dueMessage(plants, now) {
  const s = season(now);
  const water = plants.filter(p => needsWater(p, now, s));
  const foodOnly = plants.filter(p => !needsWater(p, now, s) && needsFood(p, now, s));
  const lines = water.map(p => `${p.label || "Plant"}: ${amountFor(p, s)} ml water${needsFood(p, now, s) ? " + voeding" : ""}`);
  const shown = lines.slice(0, 7);
  if (lines.length > 7) shown.push(`en nog ${lines.length - 7} andere`);
  if (foodOnly.length) shown.push(`Voeding bij de volgende waterbeurt: ${namesText(foodOnly.map(p => p.label || "Plant"))}`);
  const title = water.length === 1 ? `${water[0].label || "Een plant"} heeft water nodig`
    : water.length ? `${water.length} planten hebben water nodig` : "Gietgenoten";
  return { title, body: shown.length ? shown.join("\n") : "Alle planten hebben op dit moment genoeg water.", count: water.length };
}
function showDue(plants, settings) {
  const m = dueMessage(plants, new Date());
  return self.registration.showNotification(m.title, {
    body: m.body,
    icon: "icon-192.png", badge: "icon-192.png", tag: "water",
    silent: !!settings.stil, ...(settings.stil ? {} : { vibrate: [200, 100, 200] })
  });
}
/* Melding op een vast tijdstip, verstuurd door de eigen Supabase van het huishouden */
async function onPush() {
  const db = await openDb();
  const settings = (await req(db, "settings", "readonly", s => s.get("meldingen"))) || {};
  const plants = (await cloudPlants(db)) ?? ((await req(db, "plants", "readonly", st => st.getAll())) || []);
  await showDue(plants, settings);
  db.close();
}
self.addEventListener("push", e => {
  e.waitUntil(onPush().catch(() => self.registration.showNotification("Gietgenoten", { body: "Bekijk welke planten water nodig hebben.", icon: "icon-192.png", tag: "water" })));
});
self.addEventListener("periodicsync", e => { if (e.tag === "plant-check") e.waitUntil(checkPlants().catch(() => {})); });
self.addEventListener("notificationclick", e => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(list => {
    const c = list.find(w => "focus" in w);
    return c ? c.focus() : self.clients.openWindow("./");
  }));
});
