// Edge Script Bunny (MIDDLEWARE) — endpoint de version + relevé d'installations + tableau de bord privé.
//
// Routes gérées (le reste passe vers l'origine, site servi normalement) :
//   • /version.json  → relève le ping anonyme (telemetry/installs.json) + renvoie la politique de version.
//   • /telemetry/*   → 403 (les données d'installation ne sont jamais publiques).
//   • /parc?key=…    → tableau de bord privé (réparti­tion des builds, machines). Protégé par STATS_KEY.
//
// Secrets (Edge Scripting → Environment) :
//   STORAGE_ZONE, STORAGE_ACCESS_KEY, STORAGE_HOST (= storage.bunnycdn.com), STATS_KEY (clé d'accès au /parc).

import * as BunnySDK from "@bunny.net/edgescript-sdk";

const STORAGE_HOST = Deno.env.get("STORAGE_HOST") ?? "storage.bunnycdn.com";
const STORAGE_ZONE = Deno.env.get("STORAGE_ZONE") ?? "";
const STORAGE_KEY = Deno.env.get("STORAGE_ACCESS_KEY") ?? "";
const STATS_KEY = Deno.env.get("STATS_KEY") ?? "";
const INSTALLS_PATH = "telemetry/installs.json";
const POLICY_PATH = "version.json";

async function storageGet(path) {
  const r = await fetch(`https://${STORAGE_HOST}/${STORAGE_ZONE}/${path}`, { headers: { AccessKey: STORAGE_KEY } });
  return r.status === 200 ? await r.text() : null;
}
async function storagePut(path, body) {
  await fetch(`https://${STORAGE_HOST}/${STORAGE_ZONE}/${path}`, {
    method: "PUT", headers: { AccessKey: STORAGE_KEY, "Content-Type": "application/json" }, body,
  });
}

async function recordPing(params) {
  const id = params.get("id");
  if (!id) return;
  let installs = {};
  const raw = await storageGet(INSTALLS_PATH);
  if (raw) { try { installs = JSON.parse(raw); } catch (_) { installs = {}; } }
  const now = new Date().toISOString();
  const prev = installs[id] ?? {};
  installs[id] = {
    build: Number(params.get("build")) || prev.build || 0,
    os: params.get("os") ?? prev.os ?? "",
    v: params.get("v") ?? prev.v ?? "",
    firstSeen: prev.firstSeen ?? now,
    lastSeen: now,
    count: (prev.count ?? 0) + 1,
  };
  await storagePut(INSTALLS_PATH, JSON.stringify(installs));
}

function esc(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}

function renderDashboard(installs) {
  const entries = Object.entries(installs);
  const total = entries.length;
  const byBuild = {};
  for (const [, v] of entries) { const b = v.build || 0; byBuild[b] = (byBuild[b] || 0) + 1; }
  const builds = Object.keys(byBuild).map(Number).sort((a, b) => b - a);
  const maxN = Math.max(1, ...Object.values(byBuild));
  const bars = builds.map((b) =>
    `<div class=bar><span class=lbl>build ${b}</span><span class=track><span class=fill style="width:${Math.round(byBuild[b] / maxN * 100)}%"></span></span><span class=n>${byBuild[b]}</span></div>`
  ).join("");
  const rows = entries
    .sort((a, b) => String(b[1].lastSeen || "").localeCompare(String(a[1].lastSeen || "")))
    .map(([id, v]) =>
      `<tr><td class=mono>${esc(id.slice(0, 8))}…</td><td>${esc(v.build ?? "?")}</td><td>${esc((v.os || "").slice(0, 40))}</td><td>${esc(v.v || "")}</td><td>${esc(String(v.lastSeen || "").slice(0, 16).replace("T", " "))}</td><td class=r>${esc(v.count ?? 0)}</td></tr>`
    ).join("");
  return `<!DOCTYPE html><html lang=fr><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>Parc — GPXManagement</title>
<style>
:root{--bg:#F2EEE4;--ink:#15241D;--sec:#5c6b62;--card:#FBF8F1;--line:#ddd5c4;--green:#0F7A57}
@media(prefers-color-scheme:dark){:root{--bg:#0D1A16;--ink:#ECE6D6;--sec:#9aa89f;--card:#152420;--line:#26352f;--green:#3FB389}}
body{margin:0;background:var(--bg);color:var(--ink);font-family:-apple-system,system-ui,sans-serif;font-size:15px;line-height:1.5}
.wrap{max-width:820px;margin:0 auto;padding:32px 22px}
h1{font-size:26px;margin:0 0 2px}.sub{color:var(--sec);margin:0 0 24px}
.bar{display:flex;align-items:center;gap:12px;margin:7px 0}.lbl{width:80px;color:var(--sec);font-size:13px}
.track{flex:1;height:18px;background:var(--line);border-radius:6px;overflow:hidden}.fill{display:block;height:100%;background:var(--green)}
.n{width:36px;text-align:right;font-variant-numeric:tabular-nums;font-weight:700}
table{width:100%;border-collapse:collapse;margin-top:24px;font-size:13.5px}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line)}
th{color:var(--sec);font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.04em}
.mono{font-family:ui-monospace,Menlo,monospace}.r{text-align:right}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px 20px;margin-bottom:22px}
</style></head><body><div class=wrap>
<h1>Parc installé</h1><p class=sub>${total} machine(s) · données anonymes</p>
<div class=card><h3 style="margin:0 0 10px">Répartition par build</h3>${bars || "<p class=sub>Aucune donnée.</p>"}</div>
<table><thead><tr><th>Machine</th><th>Build</th><th>macOS</th><th>Version</th><th>Vue le</th><th class=r>×</th></tr></thead><tbody>${rows}</tbody></table>
</div></body></html>`;
}

BunnySDK.net.http.servePullZone().onOriginRequest(async (ctx) => {
  const url = new URL(ctx.request.url);

  // Tableau de bord privé (protégé par clé).
  if (url.pathname === "/parc" || url.pathname === "/parc/") {
    if (!STATS_KEY || url.searchParams.get("key") !== STATS_KEY) {
      return new Response("Forbidden", { status: 403 });
    }
    const raw = await storageGet(INSTALLS_PATH);
    let installs = {};
    if (raw) { try { installs = JSON.parse(raw); } catch (_) { installs = {}; } }
    return new Response(renderDashboard(installs), {
      headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" },
    });
  }

  // Données d'installation jamais publiques.
  if (url.pathname.startsWith("/telemetry/")) {
    return new Response("Forbidden", { status: 403 });
  }

  // Tout sauf /version.json : passthrough vers l'origine (site servi normalement).
  if (!url.pathname.endsWith("/version.json")) return ctx.request;

  // /version.json : relève le ping (sans bloquer) puis court-circuite avec la politique.
  try { await recordPing(url.searchParams); } catch (_) { /* ignore */ }
  const policy = await storageGet(POLICY_PATH);
  return new Response(policy ?? '{"latestBuild":0,"minimumBuild":0}', {
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
});
