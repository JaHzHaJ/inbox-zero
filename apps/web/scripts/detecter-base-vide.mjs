/**
 * Dit si la base du .env est VIDE (aucune table dans le schema public).
 *
 * Sert a l'installeur pour decider s'il faut creer le schema (prisma migrate
 * deploy) : une organisation neuve part d'une base sans aucune table, alors
 * que la base d'un poste supplementaire est deja peuplee et fait foi.
 *
 * Codes de sortie :
 *   0 = des tables existent (ne PAS migrer : la base fait foi)
 *   3 = base joignable et VIDE (premiere installation : migrer)
 *   1 = base injoignable ou erreur (ne rien conclure)
 *
 * Usage, depuis apps/web :
 *   node scripts/detecter-base-vide.mjs [--env <chemin>]
 */

import { existsSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import dotenv from "dotenv";
import pg from "pg";

const racine = path.resolve(import.meta.dirname, "..");

const indexEnv = process.argv.indexOf("--env");
const cheminEnv =
  indexEnv !== -1 && process.argv[indexEnv + 1]
    ? path.resolve(process.argv[indexEnv + 1])
    : path.join(racine, ".env");

if (!existsSync(cheminEnv)) {
  console.log(`  [ECHEC] Fichier de configuration introuvable : ${cheminEnv}`);
  process.exit(1);
}
dotenv.config({ path: cheminEnv, quiet: true });

// Meme ordre de priorite que prisma.config.ts : les migrations passent par la
// connexion directe quand elle existe.
const url =
  process.env.PREVIEW_DATABASE_URL_UNPOOLED ||
  process.env.DIRECT_URL ||
  process.env.DATABASE_URL_UNPOOLED ||
  process.env.DATABASE_URL;

if (!url) {
  console.log("  [ECHEC] Aucune URL de base dans la configuration.");
  process.exit(1);
}

const client = new pg.Client({ connectionString: url });
try {
  await client.connect();
} catch (erreur) {
  console.log(
    `  [ECHEC] Base injoignable : ${String(erreur?.message ?? erreur)}`,
  );
  process.exit(1);
}

try {
  const { rows } = await client.query(
    "select count(*)::int as tables from information_schema.tables" +
      " where table_schema = 'public' and table_type = 'BASE TABLE'",
  );
  const nb = rows[0].tables;
  if (nb === 0) {
    console.log("  base joignable et VIDE : premiere installation.");
    process.exitCode = 3;
  } else {
    console.log(`  base deja peuplee : ${nb} table(s).`);
    process.exitCode = 0;
  }
} catch (erreur) {
  console.log(
    `  [ECHEC] Lecture de la base impossible : ${String(erreur?.message ?? erreur)}`,
  );
  process.exitCode = 1;
} finally {
  await client.end().catch(() => {});
}
