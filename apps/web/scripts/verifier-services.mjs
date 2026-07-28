/**
 * Verifie que les services dont depend " Gestion Mails " repondent vraiment :
 * base de donnees, Redis, et (en option) le fournisseur d'IA.
 *
 * Le MODE n'est pas un reglage a part : il est DEDUIT du .env. Si la base est
 * sur localhost, c'est le mode local (Docker) ; sinon le mode partage
 * (Supabase + Upstash). Rien a synchroniser, aucun fichier d'etat qui pourrait
 * mentir sur la realite.
 *
 * Usage, depuis apps/web :
 *   node scripts/verifier-services.mjs
 *   node scripts/verifier-services.mjs --avec-ia
 */

import { existsSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import dotenv from "dotenv";
import pg from "pg";
import { Redis } from "@upstash/redis";

const racine = path.resolve(import.meta.dirname, "..");

// --env <chemin> : verifier une AUTRE configuration que celle en service.
// C'est ce qui permet de controler le mode inactif sans rien basculer en
// production -- sans quoi " les deux modes a egalite " resterait un voeu pieux.
const indexEnv = process.argv.indexOf("--env");
const cheminEnv =
  indexEnv !== -1 && process.argv[indexEnv + 1]
    ? path.resolve(process.argv[indexEnv + 1])
    : path.join(racine, ".env");

if (!existsSync(cheminEnv)) {
  console.log(`\n  [ECHEC] Fichier de configuration introuvable : ${cheminEnv}\n`);
  process.exit(1);
}

// Meme ordre que Next : .env pose la base commune, .env.local (propre au poste)
// a le dernier mot.
dotenv.config({ path: cheminEnv, quiet: true });
dotenv.config({
  path: path.join(racine, ".env.local"),
  override: true,
  quiet: true,
});

const AVEC_IA = process.argv.includes("--avec-ia");

let echecs = 0;
const ok = (texte) => console.log(`  [OK]    ${texte}`);
const info = (texte) => console.log(`          ${texte}`);
const echec = (texte, remede) => {
  echecs++;
  console.log(`  [ECHEC] ${texte}`);
  if (remede) for (const l of remede.split("\n")) console.log(`          ${l}`);
};

function detecterMode() {
  const url = process.env.DATABASE_URL ?? "";
  if (!url) return "inconnu";
  return /localhost|127\.0\.0\.1|@db:/.test(url) ? "local" : "partage";
}

/** Masque le mot de passe : ce script finit dans des journaux. */
function sansSecret(url) {
  return String(url).replace(/(:\/\/[^:]+:)[^@]+@/, "$1***@");
}

async function verifierBase(mode) {
  const url = process.env.DATABASE_URL;
  if (!url) {
    echec(
      "DATABASE_URL est absente du .env",
      "Recopier le .env depuis le dossier OneDrive « Gestion Mails ».",
    );
    return;
  }
  info(`base : ${sansSecret(url)}`);

  const client = new pg.Client({ connectionString: url });
  try {
    await client.connect();
  } catch (erreur) {
    const message = String(erreur?.message ?? erreur);
    // Nommer la panne plutot que de recracher l'erreur brute : c'est tout
    // l'interet de ce script pour quelqu'un qui revient de conges.
    if (/Tenant or user not found|password authentication/i.test(message)) {
      echec(
        "identifiants refuses par la base",
        "Le mot de passe du .env ne correspond plus.\n" +
          "Supabase → Settings → Database → Reset database password,\n" +
          "puis reporter la valeur dans DATABASE_URL et DIRECT_URL.",
      );
    } else if (/ENOTFOUND|EAI_AGAIN/i.test(message)) {
      echec(
        "serveur de base introuvable (DNS)",
        mode === "local"
          ? "Les conteneurs Docker sont-ils demarres ? .claude\\ensure-stack.cmd"
          : "Pas de reseau, ou l'adresse du projet Supabase a change.",
      );
    } else if (/ETIMEDOUT|ECONNREFUSED/i.test(message)) {
      echec(
        "base injoignable",
        mode === "local"
          ? "Docker Desktop est-il allume ? Les conteneurs tournent-ils ?"
          : "PROJET SUPABASE PROBABLEMENT EN PAUSE (palier gratuit : mise en\n" +
              "pause apres 7 jours sans activite, typiquement au retour de conges).\n" +
              "Ouvrir https://supabase.com/dashboard et cliquer « Restore project ».\n" +
              "Les donnees sont intactes : AUCUNE restauration n'est necessaire.",
      );
    } else {
      echec(`connexion a la base impossible : ${message}`);
    }
    return;
  }

  try {
    const { rows } = await client.query(
      'select (select count(*) from "EmailAccount")::int as comptes,' +
        ' (select count(*) from "Rule")::int as regles,' +
        ' (select count(*) from "_prisma_migrations")::int as migrations',
    );
    const { comptes, regles, migrations } = rows[0];
    if (comptes === 0 && regles === 0) {
      echec(
        "la base repond mais elle est VIDE",
        "Restaurer la derniere sauvegarde : remise-en-service.cmd",
      );
    } else {
      ok(
        `base : ${comptes} compte(s) de messagerie, ${regles} regles, ${migrations} migrations`,
      );
    }
  } catch (erreur) {
    const message = String(erreur?.message ?? erreur);
    if (/does not exist/i.test(message)) {
      echec(
        "la base repond mais les tables sont absentes",
        "Restaurer la derniere sauvegarde : remise-en-service.cmd",
      );
    } else {
      echec(`lecture de la base impossible : ${message}`);
    }
  } finally {
    await client.end().catch(() => {});
  }
}

async function verifierRedis(mode) {
  const url = process.env.UPSTASH_REDIS_URL;
  const token = process.env.UPSTASH_REDIS_TOKEN;
  if (!url || !token) {
    echec("UPSTASH_REDIS_URL ou UPSTASH_REDIS_TOKEN est absente du .env");
    return;
  }
  info(`redis : ${url}`);
  if (mode === "partage" && !url.startsWith("https://")) {
    echec(
      "en mode partage, l'adresse Redis doit etre en https://",
      "Une adresse locale ici veut dire que les deux postes ne partageraient\n" +
        "pas leurs verrous : ils traiteraient les memes mails deux fois.",
    );
    return;
  }

  const redis = new Redis({ url, token });
  const cle = `verif:${Date.now()}`;
  try {
    await redis.set(cle, "ping", { ex: 30 });
    const lu = await redis.get(cle);
    if (lu !== "ping") {
      echec(`Redis a repondu « ${lu} » au lieu de « ping »`);
      return;
    }
    // EVAL n'est pas un detail : TOUS les verrous entre postes reposent sur un
    // petit script Lua (utils/redis/owned-lock.ts). Un Redis qui accepte
    // SET/GET mais refuse EVAL laisserait passer des recaps en double.
    const resultat = await redis.eval(
      'if redis.call("GET", KEYS[1]) == ARGV[1] then return 1 else return 0 end',
      [cle],
      ["ping"],
    );
    if (Number(resultat) !== 1) {
      echec("Redis accepte SET/GET mais son moteur de scripts repond mal");
      return;
    }
    await redis.del(cle);
    ok("redis : lecture, ecriture et verrous (EVAL) fonctionnels");
  } catch (erreur) {
    const message = String(erreur?.message ?? erreur);
    if (/unauthorized|401/i.test(message)) {
      echec(
        "Redis refuse le jeton",
        "Recopier UPSTASH_REDIS_TOKEN depuis la console Upstash (encadre « REST API »).",
      );
    } else if (/ECONNREFUSED|fetch failed/i.test(message)) {
      echec(
        "Redis injoignable",
        mode === "local"
          ? "Le conteneur redis-http est-il demarre ? .claude\\ensure-stack.cmd"
          : "Verifier l'adresse Upstash et la connexion reseau.",
      );
    } else {
      echec(`Redis : ${message}`);
    }
  }
}

async function verifierIa() {
  const chaine = process.env.DEFAULT_LLMS ?? "";
  if (!chaine) {
    echec(
      "aucun fournisseur d'IA configure (DEFAULT_LLMS vide)",
      "Lancer .claude\\configurer-ia.cmd pour choisir.",
    );
    return;
  }
  info(`ia : ${chaine}`);
  const premier = chaine.split(",")[0]?.split(":")[0];
  if (premier === "claude-code") {
    // Le programme s'installe avec les dependances, mais la SESSION est propre
    // a chaque machine : c'est le trou classique sur un poste neuf.
    const { spawnSync } = await import("node:child_process");
    const r = spawnSync(
      process.execPath,
      [path.join(racine, "smoke-claude-code.mjs"), "haiku"],
      { cwd: racine, encoding: "utf8", timeout: 180000 },
    );
    if (r.status === 0) ok("ia : le CLI Claude repond");
    else
      echec(
        "le CLI Claude ne repond pas",
        "Ouvrir un terminal, taper « claude », se connecter avec le compte de\n" +
          "l'abonnement, puis relancer cette verification.",
      );
  } else if (!process.env.LLM_API_KEY) {
    echec(
      `le fournisseur « ${premier} » attend une cle API, LLM_API_KEY est vide`,
      "Lancer .claude\\configurer-ia.cmd pour la renseigner.",
    );
  } else {
    ok(`ia : fournisseur « ${premier} » avec cle API renseignee`);
  }
}

const mode = detecterMode();
console.log(
  `\n=== Verification des services — mode ${mode.toUpperCase()} ===\n`,
);
if (mode === "local") info("base et Redis dans Docker, sur ce poste");
if (mode === "partage") info("base Supabase et Redis Upstash, partages entre postes");

await verifierBase(mode);
await verifierRedis(mode);
if (AVEC_IA) await verifierIa();

console.log(
  echecs === 0
    ? "\nTout repond.\n"
    : `\n${echecs} verification(s) en echec — voir ci-dessus.\n`,
);

// process.exit() immediat fait planter Node ( " Assertion failed:
// !(handle->flags & UV_HANDLE_CLOSING) " ) : les connexions HTTP gardees
// ouvertes par le client Redis sont encore en cours de fermeture. On pose le
// code de sortie et on laisse Node finir proprement, avec un filet si un
// descripteur restait bloque.
process.exitCode = echecs === 0 ? 0 : 1;
setTimeout(() => process.exit(process.exitCode), 2000).unref();
