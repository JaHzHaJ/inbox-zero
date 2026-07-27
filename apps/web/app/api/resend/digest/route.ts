import { NextResponse } from "next/server";
import { withEmailAccount, withError } from "@/utils/middleware";
import { captureException, SafeError } from "@/utils/error";
import prisma from "@/utils/prisma";
import type { Logger } from "@/utils/logger";
import { createUnsubscribeToken } from "@/utils/unsubscribe";
import {
  getDigestScheduleProgression,
  isDigestScheduleDue,
} from "@/utils/digest/schedule";
import { sendDigest } from "@/utils/digest/send-digest";
import type { ParsedMessage } from "@/utils/types";
import {
  sendDigestEmailBody,
  storedDigestContentSchema,
  type Digest,
} from "./validation";
import { DigestStatus } from "@/generated/prisma/enums";
import { extractNameFromEmail } from "../../../../utils/email";
import {
  DIGEST_BUCKET_LABELS,
  DIGEST_BUCKET_ORDER,
  getDigestBucket,
} from "@/utils/digest/action-buckets";
import {
  getRecipientRole,
  sortDigestItemsByDateDesc,
} from "@/utils/digest/digest-item-meta";
import { createEmailProvider } from "@/utils/email/provider";
import { getRepliedThreadDates } from "@/utils/reply-tracker/already-replied";
import { getEmailUrlForOptionalMessage } from "@/utils/url";
import { sleep } from "@/utils/sleep";
import { withQstashOrInternal } from "@/utils/qstash";

export const maxDuration = 60;

type SendEmailResult = {
  success: boolean;
  message: string;
};

export const GET = withEmailAccount("resend/digest", async (request) => {
  // send to self
  const emailAccountId = request.auth.emailAccountId;

  const logger = request.logger.with({
    force: true,
  });

  logger.info("Sending digest email to user GET");

  const result = await sendEmail({ emailAccountId, force: true, logger });

  return NextResponse.json(result);
});

export const POST = withError(
  "resend/digest",
  withQstashOrInternal(async (request) => {
    const json = await request.json();
    const { success, data, error } = sendDigestEmailBody.safeParse(json);

    if (!success) {
      request.logger.error("Invalid request body", { error });
      return NextResponse.json(
        { error: "Invalid request body" },
        { status: 400 },
      );
    }
    const { emailAccountId } = data;

    const logger = request.logger.with({ emailAccountId });

    logger.info("Sending digest email to user POST");

    try {
      const result = await sendEmail({ emailAccountId, logger });
      return NextResponse.json(result);
    } catch (error) {
      logger.error("Error sending digest email", { error });
      captureException(error, { emailAccountId });
      // Return 200 to prevent queue retries — failed digests are already marked
      // FAILED in the DB, and retrying won't help (expired tokens, timeouts, etc.)
      return NextResponse.json({
        success: false,
        error: "Error sending digest email",
      });
    }
  }),
);

/** Date du plus ancien mail present au recap : borne basse de la recherche. */
function earliestItemDate(
  digests: { items: { messageId: string }[] }[],
  messageMap: Map<string, ParsedMessage>,
): Date {
  let earliest = Number.POSITIVE_INFINITY;

  for (const digest of digests) {
    for (const item of digest.items) {
      const message = messageMap.get(item.messageId);
      if (!message) continue;
      const time = new Date(message.date).getTime();
      if (time < earliest) earliest = time;
    }
  }

  return Number.isFinite(earliest)
    ? new Date(earliest)
    : new Date(Date.now() - 7 * 24 * 60 * 60 * 1000);
}

/** Solde des digests sans envoyer de mail : rien a signaler. */
async function closeDigestsWithoutSending(digestIds: string[]) {
  if (!digestIds.length) return;

  await prisma.$transaction([
    prisma.digest.updateMany({
      where: { id: { in: digestIds } },
      data: { status: DigestStatus.SENT, sentAt: new Date() },
    }),
    prisma.digestItem.updateMany({
      where: { digestId: { in: digestIds } },
      data: { content: "[REDACTED]" },
    }),
  ]);
}

async function getDigestSchedule({
  emailAccountId,
}: {
  emailAccountId: string;
}) {
  return prisma.schedule.findUnique({
    where: { emailAccountId },
    select: {
      id: true,
      intervalDays: true,
      occurrences: true,
      daysOfWeek: true,
      timeOfDay: true,
      lastOccurrenceAt: true,
      nextOccurrenceAt: true,
    },
  });
}

async function sendEmail({
  emailAccountId,
  force,
  logger,
}: {
  emailAccountId: string;
  force?: boolean;
  logger: Logger;
}): Promise<SendEmailResult> {
  logger.info("Sending digest email");
  const now = new Date();

  const emailAccount = await prisma.emailAccount.findUnique({
    where: { id: emailAccountId },
    select: {
      email: true,
      account: { select: { provider: true, refresh_token: true } },
    },
  });

  if (!emailAccount) {
    throw new Error("Email account not found");
  }

  if (!emailAccount.account.refresh_token) {
    logger.warn("Skipping digest: account has no refresh token");
    return { success: false, message: "Account has no refresh token" };
  }

  const emailProvider = await createEmailProvider({
    emailAccountId,
    provider: emailAccount.account.provider,
    logger,
  });

  const digestScheduleData = await getDigestSchedule({ emailAccountId });
  const digestScheduleProgression = digestScheduleData
    ? getDigestScheduleProgression(digestScheduleData, now)
    : null;
  // Le creneau est reserve en amont de l'envoi : on doit pouvoir le rendre si
  // l'envoi echoue, sinon la journee est perdue.
  let claimedSchedule = false;

  if (!force) {
    if (!digestScheduleData) {
      logger.info("Skipping digest send because no schedule is configured");
      return { success: true, message: "Digest schedule is not configured" };
    }

    if (!isDigestScheduleDue(digestScheduleData, now)) {
      logger.info("Skipping digest send because schedule is not due", {
        nextOccurrenceAt: digestScheduleData.nextOccurrenceAt,
      });
      return { success: true, message: "Digest schedule is not due yet" };
    }

    if (!digestScheduleProgression) {
      logger.error("Missing digest schedule progression");
      return { success: false, message: "Digest schedule is not usable" };
    }
  }

  const pendingDigests = await prisma.digest.findMany({
    where: {
      emailAccountId,
      status: DigestStatus.PENDING,
    },
    select: {
      id: true,
      items: {
        select: {
          messageId: true,
          threadId: true,
          content: true,
          action: {
            select: {
              executedRule: {
                select: {
                  rule: {
                    select: {
                      name: true,
                      systemType: true,
                      digestBucket: true,
                    },
                  },
                },
              },
            },
          },
        },
      },
    },
  });

  // Rien a envoyer : on ne touche PAS au planning. Le creneau reste du, et la
  // repetition de la tache enverra le recap des qu'un item existera. Le
  // consommer ici ferait perdre la journee entiere des que le rattrapage
  // echoue, ce qui s'est produit le 27/07.
  if (pendingDigests.length === 0 && !force) {
    logger.info("Aucun digest en attente : creneau laisse ouvert");
    return { success: true, message: "No digests to process" };
  }

  if (!force && digestScheduleData && digestScheduleProgression) {
    // Reserve le creneau juste avant d'envoyer. Plusieurs postes partagent la
    // meme base : sans cela ils passent tous la verification et envoient chacun
    // leur recap. La condition porte sur la valeur exacte relue, ce qui en fait
    // une comparaison-et-echange : un seul poste obtient count = 1.
    const claim = await prisma.schedule.updateMany({
      where: {
        id: digestScheduleData.id,
        emailAccountId,
        nextOccurrenceAt: digestScheduleData.nextOccurrenceAt,
      },
      data: digestScheduleProgression,
    });

    if (claim.count === 0) {
      logger.info("Digest slot already claimed by another machine", {
        nextOccurrenceAt: digestScheduleData.nextOccurrenceAt,
      });
      return { success: true, message: "Digest slot already claimed" };
    }

    claimedSchedule = true;
  }

  if (pendingDigests.length) {
    // Mark all found digests as processing
    await prisma.digest.updateMany({
      where: {
        id: {
          in: pendingDigests.map((d) => d.id),
        },
      },
      data: {
        status: DigestStatus.PROCESSING,
      },
    });
  }

  try {
    if (pendingDigests.length === 0) {
      // When force is true, send an empty digest to indicate the system is working
      logger.info("Force sending empty digest", { emailAccountId });
    }

    // Store the digest IDs for the final update
    const processedDigestIds = pendingDigests.map((d) => d.id);

    const messageIds = pendingDigests.flatMap((digest) =>
      digest.items.map((item) => item.messageId),
    );

    logger.info("Fetching batch of messages");

    const messages: ParsedMessage[] = [];
    if (messageIds.length > 0) {
      const batchSize = 100;

      // Can't fetch more then 100 messages at a time, so fetch in batches
      // and wait 2 seconds to avoid rate limiting
      // TODO: Refactor into the provider if used elsewhere
      for (let i = 0; i < messageIds.length; i += batchSize) {
        const batch = messageIds.slice(i, i + batchSize);
        const batchResults = await emailProvider.getMessagesBatch(batch);
        messages.push(...batchResults);

        if (i + batchSize < messageIds.length) {
          await sleep(2000);
        }
      }
    }

    logger.info("Fetched batch of messages");

    // Create a message lookup map for O(1) access
    const messageMap = new Map(messages.map((m) => [m.id, m]));

    // Seeded in display order: the email template iterates Object.keys, so
    // insertion order decides the section order. Empty buckets are pruned below.
    const initialBuckets = Object.fromEntries(
      DIGEST_BUCKET_ORDER.map((bucket) => [bucket, []]),
    ) as Digest;

    // Transform and group in a single pass
    // Regle metier : le recap ne porte que sur les mails auxquels Cecile n'a
    // PAS deja repondu. Le filtre est applique ici, a l'envoi, et non a la
    // creation de l'item : c'est le seul moment qui capte une reponse ecrite
    // entre la constitution du recap et son depart.
    const repliedThreads = await getRepliedThreadDates({
      provider: emailProvider,
      since: earliestItemDate(pendingDigests, messageMap),
      logger,
    });
    let repliedSkipped = 0;

    const executedRulesByRule = pendingDigests.reduce((acc, digest) => {
      digest.items.forEach((item) => {
        const message = messageMap.get(item.messageId);
        if (!message) {
          logger.warn("Message not found, skipping digest item", {
            messageId: item.messageId,
          });
          return;
        }

        const repliedAt = repliedThreads.get(item.threadId);
        if (repliedAt && repliedAt > new Date(message.date).getTime()) {
          repliedSkipped++;
          return;
        }

        const bucket = getDigestBucket(item.action?.executedRule?.rule);

        if (!acc[bucket]) {
          acc[bucket] = [];
        }

        let parsedContent: unknown;
        try {
          parsedContent = JSON.parse(item.content);
        } catch (error) {
          logger.warn("Failed to parse digest item content, skipping item", {
            messageId: item.messageId,
            digestId: digest.id,
            error: error instanceof Error ? error.message : "Unknown error",
          });
          return; // Skip this item and continue with the next one
        }

        const contentResult =
          storedDigestContentSchema.safeParse(parsedContent);

        if (contentResult.success) {
          acc[bucket].push({
            content: contentResult.data.content,
            from: extractNameFromEmail(message?.headers?.from || ""),
            subject: message?.headers?.subject || "",
            date: message.headers.date || message.date || undefined,
            role: getRecipientRole(message, emailAccount.email),
            url:
              message.externalUrl ||
              getEmailUrlForOptionalMessage({
                messageId: message.id,
                threadId: message.threadId,
                emailAddress: emailAccount.email,
                provider: emailAccount.account.provider,
              }) ||
              undefined,
          });
        } else {
          logger.warn("Failed to validate digest content structure", {
            messageId: item.messageId,
            digestId: digest.id,
            error: contentResult.error,
          });
        }
      });
      return acc;
    }, initialBuckets);

    // Drop the seeded buckets that never received an item, so the email
    // doesn't render empty sections.
    for (const bucket of DIGEST_BUCKET_ORDER) {
      if (!executedRulesByRule[bucket]?.length) {
        delete executedRulesByRule[bucket];
      }
    }

    // Newest first inside each section.
    for (const bucket of Object.keys(executedRulesByRule)) {
      const items = executedRulesByRule[bucket];
      if (items) sortDigestItemsByDateDesc(items);
    }

    if (Object.keys(executedRulesByRule).length === 0) {
      // Cas nominal : Cecile a repondu a tout. Les digests sont soldes, sinon
      // ils resteraient en PROCESSING et reviendraient indefiniment.
      if (repliedSkipped > 0) {
        logger.info("Recap vide : tous les fils ont recu une reponse", {
          repliedSkipped,
        });
        await closeDigestsWithoutSending(
          pendingDigests.map((digest) => digest.id),
        );
        return {
          success: true,
          message: `Nothing to send: ${repliedSkipped} thread(s) already replied`,
        };
      }

      logger.info("No executed rules found, skipping digest email");
      return {
        success: true,
        message: "No executed rules found, skipping digest email",
      };
    }

    const token = await createUnsubscribeToken({ emailAccountId });

    logger.info("Sending digest", { repliedSkipped });

    await sendDigest({
      emailAccountId,
      userEmail: emailAccount.email,
      unsubscribeToken: token,
      date: new Date(),
      ruleNames: DIGEST_BUCKET_LABELS,
      itemsByRule: executedRulesByRule,
      logger,
    });

    logger.info("Digest sent");

    // Only update database if email sending succeeded
    // Use a transaction to ensure atomicity - all updates succeed or none are applied
    await prisma.$transaction([
      // Le planning a deja ete avance par la reservation du creneau.
      // Mark only the processed digests as sent
      prisma.digest.updateMany({
        where: {
          id: {
            in: processedDigestIds,
          },
        },
        data: {
          status: DigestStatus.SENT,
          sentAt: new Date(),
        },
      }),
      // Redact all DigestItems for the processed digests
      prisma.digestItem.updateMany({
        data: { content: "[REDACTED]" },
        where: {
          digestId: {
            in: processedDigestIds,
          },
        },
      }),
    ]);
  } catch (error) {
    await prisma.digest.updateMany({
      where: {
        id: {
          in: pendingDigests.map((d) => d.id),
        },
      },
      data: {
        status: DigestStatus.FAILED,
      },
    });

    // Rend le creneau reserve : sans cela le recap du jour serait definitivement
    // saute. Les digests de cette tentative restent en FAILED (comportement
    // amont), mais la passe suivante enverra ceux constitues entre-temps.
    if (claimedSchedule && digestScheduleData) {
      await prisma.schedule
        .updateMany({
          where: { id: digestScheduleData.id, emailAccountId },
          data: {
            lastOccurrenceAt: digestScheduleData.lastOccurrenceAt,
            nextOccurrenceAt: digestScheduleData.nextOccurrenceAt,
          },
        })
        .catch((restoreError) => {
          logger.error("Failed to restore digest schedule slot", {
            error: restoreError,
          });
        });
    }

    logger.error("Error sending digest email", { error });
    captureException(error);
    throw new SafeError("Error sending digest email", 500);
  }

  return { success: true, message: "Digest email sent successfully" };
}
