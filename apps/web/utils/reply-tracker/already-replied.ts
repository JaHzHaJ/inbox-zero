import type { EmailProvider } from "@/utils/email/types";
import type { Logger } from "@/utils/logger";

/**
 * « L'utilisateur a-t-il deja repondu ? » — regle metier partagee.
 *
 * Le classement se fait par lots (toutes les 30 min, plus le rattrapage sur
 * 3 jours), pas en temps reel : un mail recu a 8h52 peut n'etre traite qu'a
 * 10h04, bien apres une reponse ecrite a 8h54. Toute decision prise sur ce mail
 * doit donc verifier l'etat REEL du fil, jamais supposer qu'il est intact.
 *
 * Deux usages : ne pas rediger un brouillon devenu inutile, et ne pas
 * resignaler dans le recap un fil deja traite.
 */

/** Envois relus pour detecter les reponses : large, mais un seul appel. */
const SENT_LOOKUP_MAX = 200;

/**
 * Fil de discussion -> date du dernier message envoye par l'utilisateur.
 * Un seul appel au fournisseur, a reutiliser pour tout un lot.
 */
export async function getRepliedThreadDates({
  provider,
  since,
  logger,
  maxSent = SENT_LOOKUP_MAX,
}: {
  provider: EmailProvider;
  since: Date;
  logger: Logger;
  maxSent?: number;
}): Promise<Map<string, number>> {
  const replied = new Map<string, number>();

  try {
    const sent = await provider.getSentMessages(maxSent);

    for (const message of sent) {
      const time = new Date(message.date).getTime();
      if (Number.isNaN(time) || time < since.getTime()) continue;

      const known = replied.get(message.threadId);
      if (!known || time > known) replied.set(message.threadId, time);
    }
  } catch (error) {
    // Degradation gracieuse : en cas de doute on n'ecarte rien. Mieux vaut un
    // brouillon en trop ou un recap trop complet qu'une information perdue.
    logger.error(
      "Lecture des envois impossible, regle « deja repondu » ignoree",
      {
        error,
      },
    );
  }

  return replied;
}

/**
 * Vrai si un message a ete envoye sur ce fil APRES le message considere.
 * Pour un seul message : prefere getRepliedThreadDates sur un lot.
 */
export async function hasRepliedSince({
  provider,
  threadId,
  messageDate,
  logger,
  maxSent = 50,
}: {
  provider: EmailProvider;
  threadId: string;
  messageDate: Date;
  logger: Logger;
  maxSent?: number;
}): Promise<boolean> {
  if (Number.isNaN(messageDate.getTime())) return false;

  const replied = await getRepliedThreadDates({
    provider,
    since: messageDate,
    logger,
    maxSent,
  });

  const repliedAt = replied.get(threadId);
  return !!repliedAt && repliedAt > messageDate.getTime();
}
