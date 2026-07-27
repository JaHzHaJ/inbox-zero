import { ActionType } from "@/generated/prisma/enums";
import { emailToContentForAI } from "@/utils/ai/content-sanitizer";
import { runWithBoundedConcurrency } from "@/utils/async";
import { processDigestItem } from "@/utils/digest/process-digest-item";
import { createEmailProvider } from "@/utils/email/provider";
import type { EmailProvider } from "@/utils/email/types";
import type { Logger } from "@/utils/logger";
import { getPremiumUserFilter } from "@/utils/premium";
import prisma from "@/utils/prisma";
import {
  acquireOwnedLock,
  clearOwnedLock,
  markOwnedLockProcessed,
} from "@/utils/redis/owned-lock";
import type { ParsedMessage } from "@/utils/types";
import { processHistoryForUser } from "@/utils/webhook/outlook/process-history";

/**
 * Sans abonnement Microsoft Graph (impossible sans URL publique), rien ne
 * declenche le classement des nouveaux mails. Ce rattrapage rejoue les regles
 * sur une fenetre glissante, ce qui couvre aussi les journees ou aucun poste
 * n'etait allume.
 */
export const CATCH_UP_LOOKBACK_DAYS = 3;

// Ce qu'on LISTE aupres de Graph : metadonnees seulement, quasi gratuit.
const CATCH_UP_MAX_CANDIDATES = 300;
// Ce qu'on FAIT PASSER dans les regles par passe : couteux (appels au modele).
// Mesure sur le poste : un fil coute ~1 a 2 min au provider claude-code, donc
// une douzaine de fils sature deja le budget de 240 s d'une passe.
const CATCH_UP_MAX_THREADS_PER_PASS = 12;
const CATCH_UP_RULES_CONCURRENCY = 3;
// Part du budget reservee a la phase « regles » : le reste est garanti au drain,
// qui est ce qui produit reellement le recap. Sans cette reserve, les regles
// consomment toute l'echeance et le drain ne fait rien (constate le 27/07).
const CATCH_UP_RULES_BUDGET_RATIO = 0.55;
// Bornee volontairement : after() de Next lance ses jobs sans limite de
// concurrence et le provider claude-code ouvre un sous-processus par appel.
const CATCH_UP_DIGEST_CONCURRENCY = 2;
const CATCH_UP_PAGE_SIZE = 50;
// Messages envoyes repris par passe. Sans abonnement Graph, c'est le seul moyen
// pour l'application de savoir que Cecile a repondu : c'est ce qui retire
// l'etiquette « a repondre » et alimente le filtre du recap.
const CATCH_UP_MAX_SENT_PER_PASS = 40;
const CATCH_UP_SENT_CONCURRENCY = 3;
const CATCH_UP_SENT_PROCESSING_TTL_SECONDS = 15 * 60;
const CATCH_UP_SENT_PROCESSED_TTL_SECONDS = 30 * 24 * 60 * 60;

export type CatchUpAccountResult = {
  emailAccountId: string;
  email: string;
  candidateCount: number;
  newThreadCount: number;
  processedCount: number;
  digestItemsCreated: number;
  /** Items refuses temporairement (quota 24 h) : ils restent a faire. */
  digestItemsDeferred: number;
  /** Messages envoyes repris : c'est ce qui solde les « a repondre ». */
  sentProcessedCount: number;
  remaining: number;
};

export async function getEmailAccountsToCatchUp() {
  return prisma.emailAccount.findMany({
    where: {
      account: { disconnectedAt: null, refresh_token: { not: null } },
      // Sans planning de recap le rattrapage n'a pas d'objet : ce filtre ecarte
      // de fait le compte de test de l'emulateur.
      digestSchedule: { isNot: null },
      ...getPremiumUserFilter({ minimumTier: "PLUS_MONTHLY" }),
    },
    select: {
      id: true,
      email: true,
      account: { select: { provider: true } },
    },
  });
}

export async function catchUpEmailAccount({
  emailAccountId,
  email,
  after,
  deadlineAt,
  logger,
}: {
  emailAccountId: string;
  email: string;
  after: Date;
  deadlineAt: number;
  logger: Logger;
}): Promise<CatchUpAccountResult> {
  const provider = await createEmailProvider({
    emailAccountId,
    provider: "microsoft",
    logger,
  });

  const { messages: candidates, pageCount } = await listMessagesSince({
    provider,
    after,
    maxMessages: CATCH_UP_MAX_CANDIDATES,
  });

  const newestPerThread = await getUnprocessedThreads({
    emailAccountId,
    candidates,
  });

  const batch = newestPerThread.slice(0, CATCH_UP_MAX_THREADS_PER_PASS);

  logger.info("Rattrapage des mails non traites", {
    after,
    pageCount,
    candidateCount: candidates.length,
    newThreadCount: newestPerThread.length,
    batchSize: batch.length,
  });

  // On solde d'abord les actions restees sans item lors des passes precedentes
  // (quota atteint, serveur arrete, echeance depassee) : c'est du travail deja
  // paye cote regles, et c'est lui qui alimente le recap du jour.
  const drainedFirst = await drainDigestItems({
    emailAccountId,
    since: after,
    candidates,
    deadlineAt,
    logger: logger.with({ phase: "solde" }),
  });

  const rulesDeadlineAt =
    Date.now() + (deadlineAt - Date.now()) * CATCH_UP_RULES_BUDGET_RATIO;

  const results = await runWithBoundedConcurrency({
    items: batch,
    concurrency: CATCH_UP_RULES_CONCURRENCY,
    run: async (message) => {
      if (Date.now() > rulesDeadlineAt) return false;

      await processHistoryForUser({
        emailAddress: email,
        resourceData: { id: message.id, conversationId: message.threadId },
        logger: logger.with({ messageId: message.id }),
      });

      return true;
    },
  });

  let processedCount = 0;
  for (const { item: message, result } of results) {
    if (result.status === "fulfilled") {
      if (result.value) processedCount++;
      continue;
    }

    logger.error("Echec du traitement d'un mail pendant le rattrapage", {
      messageId: message.id,
      error: result.reason,
    });
  }

  // Second passage, pour les actions que la phase « regles » vient de creer.
  const drainedAfter = await drainDigestItems({
    emailAccountId,
    since: after,
    candidates,
    deadlineAt,
    logger: logger.with({ phase: "nouveaux" }),
  });

  const sentResult = await catchUpSentMessages({
    emailAccountId,
    email,
    provider,
    after,
    deadlineAt,
    logger: logger.with({ phase: "envoyes" }),
  });

  // Un fil non traite faute de temps reste a faire : il doit compter dans
  // « remaining » pour que le script rappelle la route.
  const notProcessed = batch.length - processedCount;

  const digestItemsDeferred = drainedFirst.deferred + drainedAfter.deferred;

  return {
    emailAccountId,
    email,
    candidateCount: candidates.length,
    newThreadCount: newestPerThread.length,
    processedCount,
    digestItemsCreated: drainedFirst.created + drainedAfter.created,
    digestItemsDeferred,
    sentProcessedCount: sentResult.processed,
    // Tout ce qui reste a faire pese ici, pour que le script rappelle la route
    // dans la foulee au lieu d'attendre la repetition suivante.
    remaining: Math.max(
      0,
      newestPerThread.length -
        batch.length +
        notProcessed +
        digestItemsDeferred +
        sentResult.pending,
    ),
  };
}

/**
 * Rejoue les messages ENVOYES depuis `after`. processHistoryForUser les accepte
 * et declenche handleOutboundMessage, qui retire l'etiquette de relance et met
 * a jour le suivi des reponses. Sans abonnement Graph, c'est le seul moment ou
 * l'application apprend que Cecile a repondu.
 *
 * Dedoublonnage propre a cette passe : un message envoye ne cree PAS
 * d'ExecutedRule, on ne peut donc pas reutiliser le filtre de la boite de
 * reception. Sans marqueur, les memes envois seraient rejoues a chaque passe.
 */
async function catchUpSentMessages({
  emailAccountId,
  email,
  provider,
  after,
  deadlineAt,
  logger,
}: {
  emailAccountId: string;
  email: string;
  provider: EmailProvider;
  after: Date;
  deadlineAt: number;
  logger: Logger;
}) {
  if (Date.now() > deadlineAt) return 0;

  // Trie par date d'envoi decroissante cote fournisseur : on prend large puis
  // on coupe sur la fenetre.
  const sent = (await provider.getSentMessages(CATCH_UP_MAX_SENT_PER_PASS * 2))
    .filter((message) => new Date(message.date).getTime() >= after.getTime())
    .slice(0, CATCH_UP_MAX_SENT_PER_PASS);

  if (!sent.length) return { processed: 0, pending: 0 };

  let processed = 0;
  let pending = 0;

  await runWithBoundedConcurrency({
    items: sent,
    concurrency: CATCH_UP_SENT_CONCURRENCY,
    run: async (message) => {
      // Echeance atteinte : le message reste a faire, il doit peser dans
      // « remaining » pour que le script rappelle la route tout de suite.
      if (Date.now() > deadlineAt) {
        pending++;
        return;
      }

      const key = `catchup-sent:${emailAccountId}:${message.id}`;
      const lockToken = await acquireOwnedLock({
        key,
        processingTtlSeconds: CATCH_UP_SENT_PROCESSING_TTL_SECONDS,
      });
      if (!lockToken) return;

      try {
        await processHistoryForUser({
          emailAddress: email,
          resourceData: { id: message.id, conversationId: message.threadId },
          logger: logger.with({ messageId: message.id }),
        });

        await markOwnedLockProcessed({
          key,
          lockToken,
          processedStatus: "processed",
          processedTtlSeconds: CATCH_UP_SENT_PROCESSED_TTL_SECONDS,
        });
        processed++;
      } catch (error) {
        // Liberer, sinon un echec passager rendrait la reponse invisible.
        await clearOwnedLock({ key, lockToken });
        logger.error("Echec du traitement d'un message envoye", {
          messageId: message.id,
          error,
        });
      }
    },
  });

  logger.info("Messages envoyes repris", {
    candidats: sent.length,
    traites: processed,
    restants: pending,
  });

  return { processed, pending };
}

/**
 * Le dedoublonnage s'appuie sur ExecutedRule, PAS sur EmailMessage : cette
 * derniere n'est alimentee que par le chargement des statistiques, elle peut
 * donc etre en avance sur le traitement reel et ferait sauter des mails.
 * runRules ecrit un ExecutedRule meme quand aucune regle ne correspond.
 */
async function getUnprocessedThreads({
  emailAccountId,
  candidates,
}: {
  emailAccountId: string;
  candidates: ParsedMessage[];
}) {
  if (!candidates.length) return [];

  const alreadyProcessed = await prisma.executedRule.findMany({
    where: {
      emailAccountId,
      messageId: { in: candidates.map((message) => message.id) },
    },
    select: { messageId: true },
  });
  const processedIds = new Set(
    alreadyProcessed.map((executed) => executed.messageId),
  );

  const newestPerThread = new Map<string, ParsedMessage>();
  for (const message of candidates) {
    if (processedIds.has(message.id)) continue;

    const existing = newestPerThread.get(message.threadId);
    // Le plus RECENT du fil : c'est lui qui reflete l'etat courant de la
    // conversation dans le recap (objet, date, lien).
    if (
      !existing ||
      new Date(message.date).getTime() > new Date(existing.date).getTime()
    ) {
      newestPerThread.set(message.threadId, message);
    }
  }

  return [...newestPerThread.values()].sort(
    (left, right) =>
      new Date(left.date).getTime() - new Date(right.date).getTime(),
  );
}

/**
 * Produit les items de recap AVANT que la route ne reponde. Les callbacks
 * after() ne demarrent qu'a la fermeture de la reponse : ils retomberont donc
 * sur un verrou deja marque comme traite et repartiront sans appel au modele.
 *
 * La fenetre est celle du rattrapage, PAS celle de la passe en cours : toute
 * action DIGEST sans item est du travail a faire, meme si elle a ete creee par
 * une passe anterieure qui a echoue (quota atteint, serveur arrete). Le verrou
 * evite le travail redondant.
 */
async function drainDigestItems({
  emailAccountId,
  since,
  candidates,
  deadlineAt,
  logger,
}: {
  emailAccountId: string;
  since: Date;
  candidates: ParsedMessage[];
  deadlineAt: number;
  logger: Logger;
}) {
  const pending = await prisma.executedAction.findMany({
    where: {
      type: ActionType.DIGEST,
      digestItems: { none: {} },
      executedRule: {
        emailAccountId,
        createdAt: { gte: since },
      },
    },
    select: {
      id: true,
      executedRule: { select: { messageId: true } },
    },
  });

  if (!pending.length) return { created: 0, deferred: 0 };

  const messagesById = new Map(
    candidates.map((message) => [message.id, message]),
  );
  let created = 0;
  let deferred = 0;

  await runWithBoundedConcurrency({
    items: pending,
    concurrency: CATCH_UP_DIGEST_CONCURRENCY,
    run: async (action) => {
      if (Date.now() > deadlineAt) return;

      const message = messagesById.get(action.executedRule.messageId);
      if (!message) return;

      const { status } = await processDigestItem(
        {
          emailAccountId,
          actionId: action.id,
          message: {
            id: message.id,
            threadId: message.threadId,
            from: message.headers.from,
            to: message.headers.to || "",
            subject: message.headers.subject,
            content: emailToContentForAI(message),
          },
        },
        logger.with({ actionId: action.id, messageId: message.id }),
      );

      if (status === "created") created++;
      if (status === "deferred") deferred++;
    },
  });

  // « deferred » doit rester visible : en silence, un quota atteint ressemble a
  // un rattrapage qui n'a rien trouve (piege du 27/07).
  const journaliser = deferred > 0 ? logger.warn : logger.info;
  journaliser.call(logger, "Items de recap produits en synchrone", {
    pending: pending.length,
    created,
    deferred,
  });

  return { created, deferred };
}

async function listMessagesSince({
  provider,
  after,
  maxMessages,
}: {
  provider: EmailProvider;
  after: Date;
  maxMessages: number;
}) {
  const messages: ParsedMessage[] = [];
  const seenMessageIds = new Set<string>();
  let pageToken: string | undefined;
  let pageCount = 0;

  while (messages.length < maxMessages) {
    const response = await provider.getMessagesWithPagination({
      after,
      maxResults: Math.min(CATCH_UP_PAGE_SIZE, maxMessages - messages.length),
      pageToken,
      // Indispensable : processHistoryForUser ecarte tout message qui n'est ni
      // dans la boite de reception ni dans les elements envoyes, SANS ecrire
      // d'ExecutedRule. Lister toute la boite ferait donc revenir a chaque
      // passe les mails ranges dans les sous-dossiers, indefiniment.
      inboxOnly: true,
    });
    pageCount++;

    for (const message of response.messages) {
      if (seenMessageIds.has(message.id)) continue;
      seenMessageIds.add(message.id);
      messages.push(message);
    }

    if (!response.nextPageToken || !response.messages.length) break;
    pageToken = response.nextPageToken;
  }

  return { messages, pageCount };
}
