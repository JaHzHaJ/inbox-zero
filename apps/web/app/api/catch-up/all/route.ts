import { NextResponse } from "next/server";
import { subDays } from "date-fns/subDays";
import { withError } from "@/utils/middleware";
import { hasCronSecret, hasPostCronSecret } from "@/utils/cron";
import { captureException } from "@/utils/error";
import {
  CATCH_UP_LOOKBACK_DAYS,
  type CatchUpAccountResult,
  catchUpEmailAccount,
  getEmailAccountsToCatchUp,
} from "@/utils/email/catch-up";
import { isMicrosoftProvider } from "@/utils/email/provider-types";
import type { Logger } from "@/utils/logger";

export const maxDuration = 300;

// Node coupe les requetes a 300 s (server.requestTimeout, non modifie par Next).
// On s'arrete avant et on signale le reste a faire : le script cron rappelle.
const CATCH_UP_DEADLINE_MS = 240_000;

export const GET = withError("cron/catch-up/all", async (request) => {
  if (!hasCronSecret(request)) {
    captureException(new Error("Unauthorized request: api/catch-up/all"));
    return new Response("Unauthorized", { status: 401 });
  }

  return NextResponse.json(await catchUpAll(request.logger));
});

export const POST = withError("cron/catch-up/all", async (request) => {
  if (!(await hasPostCronSecret(request))) {
    captureException(new Error("Unauthorized cron request: api/catch-up/all"));
    return new Response("Unauthorized", { status: 401 });
  }

  return NextResponse.json(await catchUpAll(request.logger));
});

async function catchUpAll(logger: Logger) {
  const deadlineAt = Date.now() + CATCH_UP_DEADLINE_MS;
  const after = subDays(new Date(), CATCH_UP_LOOKBACK_DAYS);
  const emailAccounts = await getEmailAccountsToCatchUp();

  logger.info("Rattrapage : comptes eligibles", {
    count: emailAccounts.length,
    after,
  });

  const accounts: (CatchUpAccountResult & { error?: true })[] = [];

  for (const emailAccount of emailAccounts) {
    if (!isMicrosoftProvider(emailAccount.account.provider)) {
      logger.info("Rattrapage non gere pour ce fournisseur", {
        emailAccountId: emailAccount.id,
        provider: emailAccount.account.provider,
      });
      continue;
    }

    try {
      accounts.push(
        await catchUpEmailAccount({
          emailAccountId: emailAccount.id,
          email: emailAccount.email,
          after,
          deadlineAt,
          logger: logger.with({ emailAccountId: emailAccount.id }),
        }),
      );
    } catch (error) {
      logger.error("Echec du rattrapage pour un compte", {
        emailAccountId: emailAccount.id,
        error,
      });
      accounts.push({
        emailAccountId: emailAccount.id,
        email: emailAccount.email,
        candidateCount: 0,
        newThreadCount: 0,
        processedCount: 0,
        digestItemsCreated: 0,
        remaining: -1,
        error: true,
      });
    }
  }

  // done=false tant qu'il reste des fils a traiter (ou qu'un compte a echoue) :
  // le script cron relance une passe.
  const done = accounts.every((account) => account.remaining === 0);

  return { done, lookbackDays: CATCH_UP_LOOKBACK_DAYS, accounts };
}
