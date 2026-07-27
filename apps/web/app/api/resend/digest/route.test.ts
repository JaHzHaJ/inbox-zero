import { beforeEach, describe, expect, it, vi } from "vitest";
import prisma from "@/utils/__mocks__/prisma";
import { DigestStatus } from "@/generated/prisma/enums";
import { sendDigest } from "@/utils/digest/send-digest";
import { createEmailProvider } from "@/utils/email/provider";

vi.mock("@/utils/prisma");
vi.mock("@/utils/digest/send-digest", () => ({ sendDigest: vi.fn() }));
vi.mock("@/utils/email/provider", () => ({ createEmailProvider: vi.fn() }));
vi.mock("@/utils/unsubscribe", () => ({
  createUnsubscribeToken: vi.fn().mockResolvedValue("token-1"),
}));
vi.mock("@/utils/qstash", () => ({
  withQstashOrInternal:
    (handler: (request: Request) => Promise<Response>) => (request: Request) =>
      handler(request),
}));
vi.mock("@/utils/error", async () => {
  const actual =
    await vi.importActual<typeof import("@/utils/error")>("@/utils/error");
  return { ...actual, captureException: vi.fn() };
});
vi.mock("@/utils/middleware", async () => {
  const helpers = await vi.importActual<typeof import("@/__tests__/helpers")>(
    "@/__tests__/helpers",
  );

  return {
    ...helpers.createWithErrorTestMiddleware(),
    withEmailAccount: vi.fn(),
  };
});

import { POST } from "./route";

const emailAccountId = "email-account-1";
const scheduleId = "schedule-1";
// Volontairement dans le passe : isDigestScheduleDue compare a l'heure reelle.
const dueAt = new Date("2026-07-20T05:00:00.000Z");
const previousOccurrence = new Date("2026-07-17T05:00:00.000Z");

function request() {
  return new Request("http://localhost:3000/api/resend/digest", {
    method: "POST",
    body: JSON.stringify({ emailAccountId }),
  });
}

function setupDueSchedule() {
  vi.mocked(prisma.emailAccount.findUnique).mockResolvedValue({
    email: "user@example.com",
    account: { provider: "microsoft", refresh_token: "refresh" },
  } as never);

  vi.mocked(prisma.schedule.findUnique).mockResolvedValue({
    id: scheduleId,
    intervalDays: null,
    occurrences: 1,
    daysOfWeek: 62,
    timeOfDay: new Date("1970-01-01T06:00:00.000Z"),
    lastOccurrenceAt: previousOccurrence,
    nextOccurrenceAt: dueAt,
  } as never);

  vi.mocked(createEmailProvider).mockResolvedValue({
    getMessagesBatch: vi.fn().mockResolvedValue([
      {
        id: "msg-1",
        threadId: "thread-1",
        date: "2026-07-26T09:00:00.000Z",
        headers: {
          from: "Fournisseur <fournisseur@example.com>",
          to: "user@example.com",
          subject: "Facture 2026-07",
          date: "2026-07-26T09:00:00.000Z",
        },
      },
    ]),
  } as never);

  vi.mocked(prisma.digest.findMany).mockResolvedValue([
    {
      id: "digest-1",
      items: [
        {
          messageId: "msg-1",
          content: JSON.stringify({ content: "Facture a regler." }),
          action: {
            executedRule: {
              rule: {
                name: "Factures",
                systemType: null,
                digestBucket: null,
              },
            },
          },
        },
      ],
    },
  ] as never);

  vi.mocked(prisma.digest.updateMany).mockResolvedValue({ count: 1 } as never);
  vi.mocked(prisma.$transaction).mockResolvedValue([] as never);
}

describe("reservation du creneau de recap", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    setupDueSchedule();
  });

  it("n'envoie rien quand un autre poste a deja pris le creneau", async () => {
    vi.mocked(prisma.schedule.updateMany).mockResolvedValue({
      count: 0,
    } as never);

    const response = await POST(request());

    await expect(response.json()).resolves.toEqual({
      success: true,
      message: "Digest slot already claimed",
    });
    expect(sendDigest).not.toHaveBeenCalled();
    // La reservation a lieu apres la lecture des digests, mais avant de les
    // marquer en cours : le perdant ne doit rien avoir modifie.
    expect(prisma.digest.updateMany).not.toHaveBeenCalled();
  });

  it("ne consomme pas le creneau quand il n'y a rien a envoyer", async () => {
    vi.mocked(prisma.digest.findMany).mockResolvedValue([] as never);

    const response = await POST(request());

    await expect(response.json()).resolves.toEqual({
      success: true,
      message: "No digests to process",
    });
    // Le creneau reste ouvert : la repetition de la tache reessaiera dans la
    // journee des qu'un item existera.
    expect(prisma.schedule.updateMany).not.toHaveBeenCalled();
    expect(sendDigest).not.toHaveBeenCalled();
  });

  it("reserve le creneau sur la valeur exacte de nextOccurrenceAt", async () => {
    vi.mocked(prisma.schedule.updateMany).mockResolvedValue({
      count: 1,
    } as never);

    await POST(request());

    expect(prisma.schedule.updateMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: {
          id: scheduleId,
          emailAccountId,
          nextOccurrenceAt: dueAt,
        },
      }),
    );
    expect(sendDigest).toHaveBeenCalled();
  });

  it("n'avance plus le planning dans la transaction finale", async () => {
    vi.mocked(prisma.schedule.updateMany).mockResolvedValue({
      count: 1,
    } as never);

    await POST(request());

    // Le planning est avance une seule fois, par la reservation.
    expect(prisma.schedule.update).not.toHaveBeenCalled();
    expect(prisma.schedule.updateMany).toHaveBeenCalledTimes(1);
  });

  it("rend le creneau quand l'envoi echoue", async () => {
    vi.mocked(prisma.schedule.updateMany).mockResolvedValue({
      count: 1,
    } as never);
    vi.mocked(sendDigest).mockRejectedValue(new Error("Resend indisponible"));

    const response = await POST(request());

    await expect(response.json()).resolves.toMatchObject({ success: false });
    expect(prisma.schedule.updateMany).toHaveBeenLastCalledWith({
      where: { id: scheduleId, emailAccountId },
      data: {
        lastOccurrenceAt: previousOccurrence,
        nextOccurrenceAt: dueAt,
      },
    });
    expect(prisma.digest.updateMany).toHaveBeenLastCalledWith(
      expect.objectContaining({
        data: { status: DigestStatus.FAILED },
      }),
    );
  });

  it("ne reserve pas quand le planning n'est pas du", async () => {
    vi.mocked(prisma.schedule.findUnique).mockResolvedValue({
      id: scheduleId,
      intervalDays: null,
      occurrences: 1,
      daysOfWeek: 62,
      timeOfDay: new Date("1970-01-01T06:00:00.000Z"),
      lastOccurrenceAt: previousOccurrence,
      nextOccurrenceAt: new Date("2099-01-01T00:00:00.000Z"),
    } as never);

    const response = await POST(request());

    await expect(response.json()).resolves.toEqual({
      success: true,
      message: "Digest schedule is not due yet",
    });
    expect(prisma.schedule.updateMany).not.toHaveBeenCalled();
  });
});
