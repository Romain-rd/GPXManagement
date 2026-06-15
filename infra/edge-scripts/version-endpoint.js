// Edge Script Bunny (MIDDLEWARE) — endpoint de version + relevé d'installations (historique du parc).
//
// IMPORTANT : un middleware s'exécute sur TOUTES les requêtes du Pull Zone. On ne doit donc agir que
// pour /version.json et **laisser passer tout le reste** vers l'origine (sinon tout le site renvoie
// le JSON de version). Avec `.onOriginRequest`, renvoyer une Response court-circuite vers cette réponse ;
// ne rien renvoyer (undefined) = passthrough normal vers l'origine.
//
// Pour /version.json :
//   1. enregistre/maj le ping anonyme dans Bunny Storage (telemetry/installs.json) ;
//   2. renvoie la politique de version (le version.json statique publié par deploy-web.sh).
//
// Confidentialité : identifiant d'installation ANONYME + build + version macOS uniquement, sur ton infra.
//
// Déploiement : Edge Scripting (Middleware) → Code editor (coller ce fichier) → Environment (secrets
//   ci-dessous) → Connected pull zones (GPXManagement) → Deploy. Aucun « trigger par chemin » à régler :
//   le filtrage est fait dans le code.
//   Secrets : STORAGE_ZONE, STORAGE_ACCESS_KEY, STORAGE_HOST (= storage.bunnycdn.com).

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

BunnySDK.net.http.servePullZone().onOriginRequest(async (ctx) => {
  const url = new URL(ctx.request.url);

  // Le dossier telemetry/ ne doit pas être lisible publiquement (données d'installation).
  // Le script, lui, y accède via l'API Storage (storage.bunnycdn.com), donc 403 ici ne le gêne pas.
  if (url.pathname.startsWith("/telemetry/")) {
    return new Response("Forbidden", { status: 403 });
  }

  // Tout sauf /version.json : renvoyer ctx.request = passthrough normal vers l'origine (site servi normalement).
  if (!url.pathname.endsWith("/version.json")) return ctx.request;

  // /version.json : on relève le ping (sans jamais bloquer) puis on court-circuite avec la politique.
  try { await recordPing(url.searchParams); } catch (_) { /* ignore */ }
  const policy = await storageGet(POLICY_PATH);
  return new Response(policy ?? '{"latestBuild":0,"minimumBuild":0}', {
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
});
