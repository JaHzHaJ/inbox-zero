import { DigestDetailLevel, DigestStatus } from "@/generated/prisma/enums";
import type { DigestBody } from "@/app/api/ai/digest/validation";
import type { StoredDigestContent } from "@/app/api/resend/digest/validation";
import { aiSummarizeEmailForDigest } from "@/utils/ai/digest/summarize-email-for-digest";
import {
  releaseDigestSummarySlot,
  reserveDigestSummarySlot,
} from "@/utils/digest/summary-limit";
import { env } from "@/env";
import type { Logger } from "@/utils/logger";
import { checkHasAccess } from "@/utils/premium/server";
import prisma from "@/utils/prisma";
import {
  acquireOwnedLock,
  clearOwnedLock,
  markOwnedLockProcessed,
} from "@/utils/redis/owned-lock";
import { getEmailAccountWithAi } from "@/utils/user/get";

/**
 * `deferred` designe un refus TEMPORAIRE (quota 24 h atteint) : l'item doit
 * rester a faire. `skipped` designe un refus DEFINITIF (pas d'acces, mail
 * venant de nous, regle sans nom, resume juge inutile) : inutile d'y revenir.
 * Confondre les deux fait disparaitre des mails pendant 7 jours.
 */
export type ProcessDigestItemStatus =
  | "created"
  | "skipped"
  | "deferred"
  | "already-handled";

const DIGEST_ITEM_PROCESSING_TTL_SECONDS = 15 * 60;
const DIGEST_ITEM_PROCESSED_TTL_SECONDS = 7 * 24 * 60 * 60;
const DIGEST_ITEM_PROCESSED_STATUS = "processed";

function getDigestItemKey(emailAccountId: string, actionId: string) {
  return `digest-item:${emailAccountId}:${actionId}`;
}

/**
 * Le rattrapage traite les items en synchrone AVANT de repondre, alors que le
 * chemin webhook passe par enqueueDigestItem puis after(). Les deux peuvent
 * donc viser la meme action, et sur plusieurs postes partageant la meme base.
 * Le verrou (deja utilise pour le suivi des messages sortants) garantit un
 * seul appel au modele par action.
 */
export async function processDigestItem(
  body: DigestBody,
  logger: Logger,
): Promise<{ status: ProcessDigestItemStatus }> {
  const { emailAccountId, actionId } = body;
  const key = actionId ? getDigestItemKey(emailAccountId, actionId) : null;

  const lockToken = key
    ? await acquireOwnedLock({
        key,
        processingTtlSeconds: DIGEST_ITEM_PROCESSING_TTL_SECONDS,
      })
    : null;

  if (key && !lockToken) {
    logger.info("Digest item deja traite ou en cours, on passe");
    return { status: "already-handled" };
  }

  try {
    const status = await runDigestItem(body, logger);

    if (key && lockToken) {
      if (status === "deferred") {
        // Refus temporaire : on LIBERE le verrou, sinon l'item serait perdu
        // pendant toute la duree de vie du marqueur (constate le 27/07 : neuf
        // mails invisibles au recap alors que le quota s'etait libere).
        await clearOwnedLock({ key, lockToken });
      } else {
        // Refus definitif ou item cree : on marque, pour que le job after()
        // qui arrivera ensuite ne refasse pas l'appel au modele.
        await markOwnedLockProcessed({
          key,
          lockToken,
          processedStatus: DIGEST_ITEM_PROCESSED_STATUS,
          processedTtlSeconds: DIGEST_ITEM_PROCESSED_TTL_SECONDS,
        });
      }
    }

    return { status };
  } catch (error) {
    // Echec : on libere pour qu'une passe ulterieure puisse retenter.
    if (key && lockToken) {
      try {
        await clearOwnedLock({ key, lockToken });
      } catch (clearError) {
        logger.error("Failed to clear digest item lock", { error: clearError });
      }
    }
    throw error;
  }
}

async function runDigestItem(
  { emailAccountId, actionId, message }: DigestBody,
  logger: Logger,
): Promise<ProcessDigestItemStatus> {
  const emailAccount = await getEmailAccountWithAi({ emailAccountId });
  if (!emailAccount) {
    throw new Error("Email account not found");
  }

  const hasDigestAccess = await checkHasAccess({
    userId: emailAccount.userId,
    minimumTier: "PLUS_MONTHLY",
  });
  if (!hasDigestAccess) {
    logger.info("Skipping digest item because plan does not include it");
    return "skipped";
  }

  // Don't summarize Digest emails (this will actually block all emails that we send, but that's okay)
  if (message.from === env.RESEND_FROM_EMAIL) {
    logger.info("Skipping digest item because it is from us");
    return "skipped";
  }

  const ruleName = actionId
    ? await getRuleNameByExecutedAction(actionId)
    : null;

  if (!ruleName) {
    logger.warn("Rule name not found for executed action", { actionId });
    return "skipped";
  }

  const detailLevel = await getDigestDetailLevel({ emailAccountId });

  // Subject-only digests are rendered from the message headers at send
  // time, so there is nothing to summarize: skip the model call and don't
  // spend a slot of the 24h summary budget on it.
  if (detailLevel === DigestDetailLevel.SUBJECT_ONLY) {
    logger.info("Storing digest item without a summary", { detailLevel });

    await upsertDigest({
      messageId: message.id || "",
      threadId: message.threadId || "",
      emailAccountId,
      actionId,
      content: { content: "" },
      logger,
    });

    return "created";
  }

  const summaryReservation = await reserveDigestSummarySlot({
    emailAccountId,
    maxSummariesPer24h: env.DIGEST_MAX_SUMMARIES_PER_24H,
  });
  if (!summaryReservation.reserved) {
    // Temporaire : le compteur glissant se libere au fil des 24 h.
    logger.warn("Item de recap reporte : quota de resumes 24 h atteint", {
      maxSummariesPer24h: env.DIGEST_MAX_SUMMARIES_PER_24H,
    });
    return "deferred";
  }

  let shouldReleaseSummaryReservation = !!summaryReservation.reservationId;

  try {
    const summary = await aiSummarizeEmailForDigest({
      ruleName,
      emailAccount,
      detailLevel,
      messageToSummarize: {
        ...message,
        to: message.to || "",
      },
    });

    if (!summary?.content) {
      logger.info("Skipping digest item because it is not worth summarizing");
      return "skipped";
    }

    await upsertDigest({
      messageId: message.id || "",
      threadId: message.threadId || "",
      emailAccountId,
      actionId,
      content: summary,
      logger,
    });

    // Keep Prisma fallback reservations releasable on success to avoid
    // counting a placeholder row in addition to the persisted digest item.
    shouldReleaseSummaryReservation =
      summaryReservation.reservationSource === "prisma";

    return "created";
  } finally {
    if (summaryReservation.reservationId && shouldReleaseSummaryReservation) {
      await releaseDigestSummarySlot({
        emailAccountId,
        reservationId: summaryReservation.reservationId,
        reservationSource: summaryReservation.reservationSource,
      }).catch((error) => {
        logger.error("Failed to release digest summary reservation", {
          error,
        });
      });
    }
  }
}

async function findOrCreateDigest(
  emailAccountId: string,
  messageId: string,
  threadId: string,
) {
  const digestWithItem = await prisma.digest.findFirst({
    where: {
      emailAccountId,
      status: DigestStatus.PENDING,
    },
    orderBy: {
      createdAt: "asc",
    },
    include: {
      items: {
        where: { messageId, threadId },
        take: 1,
      },
    },
  });

  if (digestWithItem) {
    return digestWithItem;
  }

  return await prisma.digest.create({
    data: {
      emailAccountId,
      status: DigestStatus.PENDING,
    },
    include: {
      items: {
        where: { messageId, threadId },
        take: 1,
      },
    },
  });
}

async function updateDigestItem(
  itemId: string,
  contentString: string,
  actionId?: string,
) {
  return await prisma.digestItem.update({
    where: { id: itemId },
    data: {
      content: contentString,
      ...(actionId && { actionId }),
    },
  });
}

async function createDigestItem({
  digestId,
  messageId,
  threadId,
  contentString,
  actionId,
}: {
  digestId: string;
  messageId: string;
  threadId: string;
  contentString: string;
  actionId?: string;
}) {
  return await prisma.digestItem.upsert({
    where: {
      digestId_threadId_messageId: {
        digestId,
        threadId,
        messageId,
      },
    },
    update: {
      content: contentString,
      ...(actionId && { actionId }),
    },
    create: {
      messageId,
      threadId,
      content: contentString,
      digestId,
      ...(actionId && { actionId }),
    },
  });
}

async function upsertDigest({
  messageId,
  threadId,
  emailAccountId,
  actionId,
  content,
  logger,
}: {
  messageId: string;
  threadId: string;
  emailAccountId: string;
  actionId?: string;
  content: StoredDigestContent;
  logger: Logger;
}) {
  try {
    const digest = await findOrCreateDigest(
      emailAccountId,
      messageId,
      threadId,
    );
    const existingItem = digest.items[0];
    const contentString = JSON.stringify(content);

    if (existingItem) {
      logger.info("Updating existing digest item");
      await updateDigestItem(existingItem.id, contentString, actionId);
    } else {
      logger.info("Creating new digest item");
      await createDigestItem({
        digestId: digest.id,
        messageId,
        threadId,
        contentString,
        actionId,
      });
    }
  } catch (error) {
    logger.error("Failed to upsert digest", { error });
    throw error;
  }
}

async function getDigestDetailLevel({
  emailAccountId,
}: {
  emailAccountId: string;
}): Promise<DigestDetailLevel> {
  const emailAccount = await prisma.emailAccount.findUnique({
    where: { id: emailAccountId },
    select: { digestDetailLevel: true },
  });

  return emailAccount?.digestDetailLevel ?? DigestDetailLevel.KEY_POINTS;
}

async function getRuleNameByExecutedAction(
  actionId: string,
): Promise<string | undefined> {
  const executedAction = await prisma.executedAction.findUnique({
    where: { id: actionId },
    select: {
      executedRule: {
        select: {
          rule: {
            select: {
              name: true,
            },
          },
        },
      },
    },
  });

  if (!executedAction) {
    throw new Error("Executed action not found");
  }

  return executedAction.executedRule?.rule?.name;
}
