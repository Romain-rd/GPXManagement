// Edge Script Bunny — endpoint de version + relevé d'installations (historique du parc).
//
// Rôle : intercepte les requêtes vers /version.json. Pour chaque appel de l'app
//   (…/version.json?build=9&id=<uuid-anonyme>&os=…&v=…), il :
//     1. enregistre/maj le ping dans Bunny Storage (telemetry/installs.json) ;
//     2. renvoie la politique de version (le version.json statique publié par deploy-web.sh).
//
// Confidentialité : seul un identifiant d'installation ANONYME + build + version macOS sont stockés,
//   sur ta propre infra Bunny. Aucun tiers.
//
// Déploiement (console Bunny → Edge Scripting) :
//   - Créer un script, coller ce fichier.
//   - Le rattacher au Pull Zone du site, déclencheur sur le chemin "/version.json".
//   - Secrets (Edge Scripting → Environment) :
//       STORAGE_ZONE        = <nom de ta Storage Zone> (ex: gpxmanagement)
//       STORAGE_ACCESS_KEY  = <mot de passe / AccessKey de la Storage Zone>
//       STORAGE_HOST        = storage.bunnycdn.com   (ou le host régional, ex: ny.storage.bunnycdn.com)
//
// Note d'échelle : installs.json est lu→modifié→réécrit à chaque ping. Suffisant pour une alpha
//   (faible volume). Pour un parc important, préférer des logs append-only ou une vraie base.

import * as BunnySDK from "@bunny.net/edgescript-sdk";

const STORAGE_HOST = Deno.env.get("STORAGE_HOST") ?? "storage.bunnycdn.com";
const STORAGE_ZONE = Deno.env.get("STORAGE_ZONE") ?? "";
const STORAGE_KEY = Deno.env.get("STORAGE_ACCESS_KEY") ?? "";
const INSTALLS_PATH = "telemetry/installs.json";
const POLICY_PATH = "version.json";

async function storageGet(path) {
  const r = await fetch(`https://${STORAGE_HOST}/${STORAGE_ZONE}/${path}`, {
    headers: { AccessKey: STORAGE_KEY },
  });
  return r.status === 200 ? await r.text() : null;
}

async function storagePut(path, body) {
  await fetch(`https://${STORAGE_HOST}/${STORAGE_ZONE}/${path}`, {
    method: "PUT",
    headers: { AccessKey: STORAGE_KEY, "Content-Type": "application/json" },
    body,
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

BunnySDK.net.http.serve(async (req) => {
  const url = new URL(req.url);
  // Le relevé ne doit jamais empêcher de répondre la politique.
  try { await recordPing(url.searchParams); } catch (_) { /* ignore */ }
  const policy = await storageGet(POLICY_PATH);
  return new Response(policy ?? '{"latestBuild":0,"minimumBuild":0}', {
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
});
