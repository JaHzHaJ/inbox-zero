import { NextResponse } from "next/server";
import { subDays } from "date-fns/subDays";
import prisma from "@/utils/prisma";
import { withError } from "@/utils/middleware";
import { hasCronSecret, hasPostCronSecret } from "@/utils/cron";
import { captureException } from "@/utils/error";
import type { Logger } from "@/utils/logger";
import { getPremiumUserFilter } from "@/utils/premium";
import { enqueueBackgroundJob } from "@/utils/queue/dispatch";
import { getInternalApiHeaders, getInternalApiUrl } from "@/utils/internal-api";

export const maxDuration = 300;
const RESEND_DIGEST_TOPIC = "resend-digest";

export const GET = withError("cron/resend/digest/all", async (request) => {
  if (!hasCronSecret(request)) {
    captureException(new Error("Unauthorized request: api/resend/digest/all"));
    return new Response("Unauthorized", { status: 401 });
  }

  // ?sync=1 : attend le resultat reel de l'envoi au lieu de le confier a
  // after(). Sans cela la reponse revient avant que Resend n'ait rien recu, et
  // le journal du cron ne prouve rien.
  const sync = new URL(request.url).searchParams.get("sync") === "1";
  const result = await sendDigestAllUpdate(request.logger, { sync });

  return NextResponse.json(result);
});

export const POST = withError("cron/resend/digest/all", async (request) => {
  if (!(await hasPostCronSecret(request))) {
    captureException(
      new Error("Unauthorized cron request: api/resend/digest/all"),
    );
    return new Response("Unauthorized", { status: 401 });
  }

  const result = await sendDigestAllUpdate(request.logger);

  return NextResponse.json(result);
});

async function sendDigestAllUpdate(
  logger: Logger,
  { sync = false }: { sync?: boolean } = {},
) {
  logger.info("Sending digest all update", { sync });

  const now = new Date();

  // Get all email accounts that are due for a digest
  const emailAccounts = await prisma.emailAccount.findMany({
    where: {
      digestSchedule: {
        nextOccurrenceAt: { lte: now },
      },
      ...getPremiumUserFilter({ minimumTier: "PLUS_MONTHLY" }),
      createdAt: {
        lt: subDays(now, 1),
      },
    },
    select: {
      id: true,
      email: true,
    },
  });

  logger.info("Sending digest to users", {
    eligibleAccounts: emailAccounts.length,
  });

  const sent: { emailAccountId: string; status: number; body: string }[] = [];

  for (const emailAccount of emailAccounts) {
    try {
      if (sync) {
        const response = await fetch(
          `${getInternalApiUrl()}/api/resend/digest`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              ...getInternalApiHeaders(),
            },
            body: JSON.stringify({ emailAccountId: emailAccount.id }),
          },
        );

        sent.push({
          emailAccountId: emailAccount.id,
          status: response.status,
          body: await response.text(),
        });
        continue;
      }

      await enqueueBackgroundJob({
        topic: RESEND_DIGEST_TOPIC,
        body: { emailAccountId: emailAccount.id },
        qstash: {
          queueName: "email-digest-all",
          parallelism: 3,
          path: "/api/resend/digest",
        },
        logger,
      });
    } catch (error) {
      logger.error("Failed to enqueue digest send", {
        emailAccountId: emailAccount.id,
        error,
      });
      logger.trace("Failed digest enqueue for account email", {
        email: emailAccount.email,
        error,
      });
    }
  }

  logger.info("All requests initiated", { count: emailAccounts.length });
  return { count: emailAccounts.length, ...(sync ? { sent } : {}) };
}
