import { DigestStatus } from "@/generated/prisma/enums";
import prisma from "@/utils/prisma";
import type { Logger } from "@/utils/logger";

// Au-dela de ce delai, un envoi encore "en cours" est considere comme abandonne.
// Large volontairement : un envoi normal prend une douzaine de secondes, mais un
// poste qui rame ne doit pas etre declare mort a tort.
export const ENVOI_ABANDONNE_MINUTES = 30;

/**
 * Rend les creneaux de recap dont l'envoi n'a jamais abouti.
 *
 * Le creneau du jour est reserve juste avant l'envoi, et rendu si l'envoi
 * echoue. Mais si le poste disparait entre les deux -- capot rabattu, coupure,
 * arret de Windows -- aucun code ne s'execute : le creneau reste consomme, les
 * digests restent en PROCESSING, et PERSONNE ne prend le relais. Symptome : pas
 * de recap ce matin-la, et rien dans les journaux pour l'expliquer.
 *
 * Avec plusieurs postes le cas devient bien plus probable : il suffit que celui
 * qui a gagne le creneau soit referme pendant que l'autre tourne.
 *
 * On remet donc les digests en attente et on rend le creneau du immediatement.
 * Idempotent : deux postes qui le font en meme temps aboutissent au meme etat.
 */
export async function recupererCreneauxAbandonnes(logger: Logger) {
  const limite = new Date(Date.now() - ENVOI_ABANDONNE_MINUTES * 60 * 1000);

  const abandonnes = await prisma.digest.findMany({
    where: { status: DigestStatus.PROCESSING, updatedAt: { lt: limite } },
    select: { id: true, emailAccountId: true },
  });
  if (abandonnes.length === 0) return { digests: 0, comptes: 0 };

  const emailAccountIds = [...new Set(abandonnes.map((d) => d.emailAccountId))];
  logger.warn("Envoi de recap abandonne : creneau rendu", {
    digests: abandonnes.length,
    emailAccountIds,
  });

  await prisma.digest.updateMany({
    where: { id: { in: abandonnes.map((d) => d.id) } },
    data: { status: DigestStatus.PENDING },
  });

  // Rendre le creneau du tout de suite. On ne restaure pas l'ancienne date
  // (elle est perdue) : le seul objectif est que le recap parte enfin.
  // La condition sur nextOccurrenceAt evite de reculer un planning deja correct.
  const maintenant = new Date();
  await prisma.schedule.updateMany({
    where: {
      emailAccountId: { in: emailAccountIds },
      nextOccurrenceAt: { gt: maintenant },
    },
    data: { nextOccurrenceAt: maintenant },
  });

  return { digests: abandonnes.length, comptes: emailAccountIds.length };
}
