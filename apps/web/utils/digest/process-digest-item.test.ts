import { beforeEach, describe, expect, it, vi } from "vitest";
import prisma from "@/utils/__mocks__/prisma";
import { DigestDetailLevel, DigestStatus } from "@/generated/prisma/enums";
import { createTestLogger } from "@/__tests__/helpers";
import { processDigestItem } from "./process-digest-item";
import {
  acquireOwnedLock,
  clearOwnedLock,
  markOwnedLockProcessed,
} from "@/utils/redis/owned-lock";
import { aiSummarizeEmailForDigest } from "@/utils/ai/digest/summarize-email-for-digest";
import {
  releaseDigestSummarySlot,
  reserveDigestSummarySlot,
} from "@/utils/digest/summary-limit";
import { getEmailAccountWithAi } from "@/utils/user/get";
import { checkHasAccess } from "@/utils/premium/server";

vi.mock("@/utils/prisma");
vi.mock("@/utils/redis/owned-lock", () => ({
  acquireOwnedLock: vi.fn(),
  markOwnedLockProcessed: vi.fn(),
  clearOwnedLock: vi.fn(),
}));
vi.mock("@/utils/ai/digest/summarize-email-for-digest", () => ({
  aiSummarizeEmailForDigest: vi.fn(),
}));
vi.mock("@/utils/digest/summary-limit", () => ({
  reserveDigestSummarySlot: vi.fn(),
  releaseDigestSummarySlot: vi.fn(),
}));
vi.mock("@/utils/user/get", () => ({
  getEmailAccountWithAi: vi.fn(),
}));
vi.mock("@/utils/premium/server", () => ({
  checkHasAccess: vi.fn(),
}));
vi.mock("@/env", () => ({
  env: {
    RESEND_FROM_EMAIL: "Inbox Zero <digest@example.com>",
    DIGEST_MAX_SUMMARIES_PER_24H: 50,
  },
}));

const logger = createTestLogger();

const body = {
  emailAccountId: "email-account-1",
  actionId: "action-1",
  message: {
    id: "message-1",
    threadId: "thread-1",
    from: "expediteur@example.com",
    to: "user@example.com",
    subject: "Devis lot 3",
    content: "Le devis est en piece jointe.",
  },
};

const lockKey = "digest-item:email-account-1:action-1";

/** Cable le chemin nominal : compte trouve, acces OK, regle nommee, digest vide. */
function setupHappyPath(detailLevel = DigestDetailLevel.KEY_POINTS) {
  vi.mocked(acquireOwnedLock).mockResolvedValue("lock-token-1");
  vi.mocked(markOwnedLockProcessed).mockResolvedValue(true);
  vi.mocked(clearOwnedLock).mockResolvedValue(true);
  vi.mocked(releaseDigestSummarySlot).mockResolvedValue(undefined as never);
  vi.mocked(getEmailAccountWithAi).mockResolvedValue({
    id: "email-account-1",
    userId: "user-1",
  } as unknown as Awaited<ReturnType<typeof getEmailAccountWithAi>>);
  vi.mocked(checkHasAccess).mockResolvedValue(true);
  vi.mocked(prisma.executedAction.findUnique).mockResolvedValue({
    executedRule: { rule: { name: "Factures fournisseurs" } },
  } as never);
  vi.mocked(prisma.emailAccount.findUnique).mockResolvedValue({
    digestDetailLevel: detailLevel,
  } as never);
  vi.mocked(prisma.digest.findFirst).mockResolvedValue({
    id: "digest-1",
    status: DigestStatus.PENDING,
    items: [],
  } as never);
  vi.mocked(prisma.digestItem.upsert).mockResolvedValue({
    id: "digest-item-1",
  } as never);
  vi.mocked(reserveDigestSummarySlot).mockResolvedValue({
    reserved: true,
    reservationId: "reservation-1",
    reservationSource: "redis",
  } as never);
}

describe("processDigestItem", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("ne refait aucun appel IA quand le verrou est deja pris", async () => {
    vi.mocked(acquireOwnedLock).mockResolvedValue(null);

    const result = await processDigestItem(body, logger);

    expect(result).toEqual({ status: "already-handled" });
    // C'est le test qui prouve qu'un job after() arrivant apres le rattrapage
    // synchrone ne redeclenche pas le modele.
    expect(aiSummarizeEmailForDigest).not.toHaveBeenCalled();
    expect(getEmailAccountWithAi).not.toHaveBeenCalled();
    expect(markOwnedLockProcessed).not.toHaveBeenCalled();
  });

  it("marque le verrou comme traite apres un item cree", async () => {
    setupHappyPath();
    vi.mocked(aiSummarizeEmailForDigest).mockResolvedValue({
      content: "Devis a valider avant vendredi.",
    } as never);

    const result = await processDigestItem(body, logger);

    expect(result).toEqual({ status: "created" });
    expect(markOwnedLockProcessed).toHaveBeenCalledWith(
      expect.objectContaining({
        key: lockKey,
        lockToken: "lock-token-1",
        processedStatus: "processed",
      }),
    );
    expect(clearOwnedLock).not.toHaveBeenCalled();
  });

  it("marque le verrou comme traite meme quand le resume est juge inutile", async () => {
    setupHappyPath();
    vi.mocked(aiSummarizeEmailForDigest).mockResolvedValue(null as never);

    const result = await processDigestItem(body, logger);

    expect(result).toEqual({ status: "skipped" });
    // Sans ce marquage, le job after() refait l'appel au modele pour rien.
    expect(markOwnedLockProcessed).toHaveBeenCalled();
  });

  it("marque le verrou comme traite quand le quota de resumes est atteint", async () => {
    setupHappyPath();
    vi.mocked(reserveDigestSummarySlot).mockResolvedValue({
      reserved: false,
    } as never);

    const result = await processDigestItem(body, logger);

    expect(result).toEqual({ status: "skipped" });
    expect(aiSummarizeEmailForDigest).not.toHaveBeenCalled();
    expect(markOwnedLockProcessed).toHaveBeenCalled();
  });

  it("libere le verrou et propage l'erreur en cas d'echec", async () => {
    setupHappyPath();
    vi.mocked(aiSummarizeEmailForDigest).mockRejectedValue(
      new Error("modele indisponible"),
    );

    await expect(processDigestItem(body, logger)).rejects.toThrow(
      "modele indisponible",
    );

    expect(clearOwnedLock).toHaveBeenCalledWith({
      key: lockKey,
      lockToken: "lock-token-1",
    });
    expect(markOwnedLockProcessed).not.toHaveBeenCalled();
  });

  it("ne consomme pas de creneau de resume en SUBJECT_ONLY", async () => {
    setupHappyPath(DigestDetailLevel.SUBJECT_ONLY);

    const result = await processDigestItem(body, logger);

    expect(result).toEqual({ status: "created" });
    expect(reserveDigestSummarySlot).not.toHaveBeenCalled();
    expect(releaseDigestSummarySlot).not.toHaveBeenCalled();
    expect(aiSummarizeEmailForDigest).not.toHaveBeenCalled();
    expect(prisma.digestItem.upsert).toHaveBeenCalled();
  });
});
