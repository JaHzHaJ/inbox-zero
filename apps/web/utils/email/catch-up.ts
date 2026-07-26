import { ActionType } from "@/generated/prisma/enums";
import { emailToContentForAI } from "@/utils/ai/content-sanitizer";
import { runWithBoundedConcurrency } from "@/utils/async";
import { processDigestItem } from "@/utils/digest/process-digest-item";
import { createEmailProvider } from "@/utils/email/provider";
import type { EmailProvider } from "@/utils/email/types";
import type { Logger } from "@/utils/logger";
import { getPremiumUserFilter } from "@/utils/premium";
import prisma from "@/utils/prisma";
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
const CATCH_UP_MAX_THREADS_PER_PASS = 40;
const CATCH_UP_RULES_CONCURRENCY = 3;
// Bornee volontairement : after() de Next lance ses jobs sans limite de
// concurrence et le provider claude-code ouvre un sous-processus par appel.
const CATCH_UP_DIGEST_CONCURRENCY = 2;
const CATCH_UP_PAGE_SIZE = 50;

export type CatchUpAccountResult = {
  emailAccountId: string;
  email: string;
  candidateCount: number;
  newThreadCount: number;
  processedCount: number;
  digestItemsCreated: number;
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
  const runStartedAt = new Date();

  logger.info("Rattrapage des mails non traites", {
    after,
    pageCount,
    candidateCount: candidates.length,
    newThreadCount: newestPerThread.length,
    batchSize: batch.length,
  });

  const results = await runWithBoundedConcurrency({
    items: batch,
    concurrency: CATCH_UP_RULES_CONCURRENCY,
    run: async (message) => {
      if (Date.now() > deadlineAt) return false;

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

  const digestItemsCreated = await drainDigestItems({
    emailAccountId,
    runStartedAt,
    candidates,
    deadlineAt,
    logger,
  });

  return {
    emailAccountId,
    email,
    candidateCount: candidates.length,
    newThreadCount: newestPerThread.length,
    processedCount,
    digestItemsCreated,
    remaining: Math.max(0, newestPerThread.length - batch.length),
  };
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
 */
async function drainDigestItems({
  emailAccountId,
  runStartedAt,
  candidates,
  deadlineAt,
  logger,
}: {
  emailAccountId: string;
  runStartedAt: Date;
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
        createdAt: { gte: runStartedAt },
      },
    },
    select: {
      id: true,
      executedRule: { select: { messageId: true } },
    },
  });

  if (!pending.length) return 0;

  const messagesById = new Map(
    candidates.map((message) => [message.id, message]),
  );
  let created = 0;

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
    },
  });

  logger.info("Items de recap produits en synchrone", {
    pending: pending.length,
    created,
  });

  return created;
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
