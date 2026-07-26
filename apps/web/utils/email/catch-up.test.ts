import { beforeEach, describe, expect, it, vi } from "vitest";
import prisma from "@/utils/__mocks__/prisma";
import { createTestLogger } from "@/__tests__/helpers";
import { catchUpEmailAccount, getEmailAccountsToCatchUp } from "./catch-up";
import { createEmailProvider } from "@/utils/email/provider";
import { processHistoryForUser } from "@/utils/webhook/outlook/process-history";
import { processDigestItem } from "@/utils/digest/process-digest-item";
import type { ParsedMessage } from "@/utils/types";

vi.mock("@/utils/prisma");
vi.mock("@/utils/email/provider", () => ({
  createEmailProvider: vi.fn(),
}));
vi.mock("@/utils/webhook/outlook/process-history", () => ({
  processHistoryForUser: vi.fn(),
}));
vi.mock("@/utils/digest/process-digest-item", () => ({
  processDigestItem: vi.fn(),
}));
vi.mock("@/utils/ai/content-sanitizer", () => ({
  emailToContentForAI: vi.fn(() => "contenu"),
}));
vi.mock("@/utils/premium", () => ({
  getPremiumUserFilter: vi.fn(() => ({})),
}));

const logger = createTestLogger();

function makeMessage(
  id: string,
  threadId: string,
  date: string,
): ParsedMessage {
  return {
    id,
    threadId,
    date,
    historyId: "1",
    inline: [],
    snippet: "",
    subject: `Objet ${id}`,
    headers: {
      date,
      from: "expediteur@example.com",
      to: "user@example.com",
      subject: `Objet ${id}`,
    },
  } as ParsedMessage;
}

let getMessagesWithPagination: ReturnType<typeof vi.fn>;

function mockProviderMessages(messages: ParsedMessage[]) {
  getMessagesWithPagination = vi
    .fn()
    .mockResolvedValue({ messages, nextPageToken: undefined });
  vi.mocked(createEmailProvider).mockResolvedValue({
    getMessagesWithPagination,
  } as never);
}

function baseArgs(
  overrides: Partial<Parameters<typeof catchUpEmailAccount>[0]> = {},
) {
  return {
    emailAccountId: "email-account-1",
    email: "user@example.com",
    after: new Date("2026-07-23T00:00:00Z"),
    deadlineAt: Date.now() + 60_000,
    logger,
    ...overrides,
  };
}

describe("catchUpEmailAccount", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(prisma.executedRule.findMany).mockResolvedValue([] as never);
    vi.mocked(prisma.executedAction.findMany).mockResolvedValue([] as never);
    vi.mocked(processHistoryForUser).mockResolvedValue(undefined as never);
  });

  it("ne repasse pas un message qui a deja un ExecutedRule", async () => {
    mockProviderMessages([
      makeMessage("msg-1", "thread-1", "2026-07-24T08:00:00Z"),
      makeMessage("msg-2", "thread-2", "2026-07-24T09:00:00Z"),
    ]);
    vi.mocked(prisma.executedRule.findMany).mockResolvedValue([
      { messageId: "msg-1" },
    ] as never);

    const result = await catchUpEmailAccount(baseArgs());

    expect(result.candidateCount).toBe(2);
    expect(result.newThreadCount).toBe(1);
    expect(processHistoryForUser).toHaveBeenCalledTimes(1);
    expect(processHistoryForUser).toHaveBeenCalledWith(
      expect.objectContaining({
        resourceData: { id: "msg-2", conversationId: "thread-2" },
      }),
    );
  });

  it("dedoublonne sur ExecutedRule et jamais sur EmailMessage", async () => {
    mockProviderMessages([
      makeMessage("msg-1", "thread-1", "2026-07-24T08:00:00Z"),
    ]);

    await catchUpEmailAccount(baseArgs());

    // EmailMessage n'est alimentee que par le chargement des statistiques :
    // s'en servir ferait sauter des mails jamais passes dans les regles.
    expect(prisma.emailMessage.findMany).not.toHaveBeenCalled();
    expect(prisma.executedRule.findMany).toHaveBeenCalledWith({
      where: {
        emailAccountId: "email-account-1",
        messageId: { in: ["msg-1"] },
      },
      select: { messageId: true },
    });
  });

  it("ne liste que la boite de reception", async () => {
    mockProviderMessages([
      makeMessage("msg-1", "thread-1", "2026-07-24T08:00:00Z"),
    ]);

    await catchUpEmailAccount(baseArgs());

    // Sans inboxOnly, les mails ranges dans les sous-dossiers sont ecartes par
    // processHistoryForUser sans ExecutedRule : ils reviennent a chaque passe.
    expect(getMessagesWithPagination).toHaveBeenCalledWith(
      expect.objectContaining({ inboxOnly: true }),
    );
  });

  it("ne traite que le message le plus recent d'un fil", async () => {
    mockProviderMessages([
      makeMessage("msg-ancien", "thread-1", "2026-07-24T08:00:00Z"),
      makeMessage("msg-milieu", "thread-1", "2026-07-24T12:00:00Z"),
      makeMessage("msg-recent", "thread-1", "2026-07-25T18:00:00Z"),
    ]);

    const result = await catchUpEmailAccount(baseArgs());

    expect(result.newThreadCount).toBe(1);
    expect(processHistoryForUser).toHaveBeenCalledTimes(1);
    expect(processHistoryForUser).toHaveBeenCalledWith(
      expect.objectContaining({
        resourceData: { id: "msg-recent", conversationId: "thread-1" },
      }),
    );
  });

  it("signale le reste a faire au-dela du plafond par passe", async () => {
    const messages = Array.from({ length: 45 }, (_, index) =>
      makeMessage(`msg-${index}`, `thread-${index}`, "2026-07-24T08:00:00Z"),
    );
    mockProviderMessages(messages);

    const result = await catchUpEmailAccount(baseArgs());

    expect(result.newThreadCount).toBe(45);
    expect(result.processedCount).toBe(40);
    expect(result.remaining).toBe(5);
  });

  it("s'interrompt sans jeter quand l'echeance est depassee", async () => {
    mockProviderMessages([
      makeMessage("msg-1", "thread-1", "2026-07-24T08:00:00Z"),
    ]);

    const result = await catchUpEmailAccount(
      baseArgs({ deadlineAt: Date.now() - 1 }),
    );

    expect(processHistoryForUser).not.toHaveBeenCalled();
    expect(result.processedCount).toBe(0);
  });

  it("produit les items de recap en synchrone avant de rendre la main", async () => {
    mockProviderMessages([
      makeMessage("msg-1", "thread-1", "2026-07-24T08:00:00Z"),
    ]);
    vi.mocked(prisma.executedAction.findMany).mockResolvedValue([
      { id: "action-1", executedRule: { messageId: "msg-1" } },
    ] as never);
    vi.mocked(processDigestItem).mockResolvedValue({ status: "created" });

    const result = await catchUpEmailAccount(baseArgs());

    expect(processDigestItem).toHaveBeenCalledWith(
      expect.objectContaining({
        emailAccountId: "email-account-1",
        actionId: "action-1",
        message: expect.objectContaining({ id: "msg-1", content: "contenu" }),
      }),
      expect.anything(),
    );
    expect(result.digestItemsCreated).toBe(1);
  });
});

describe("getEmailAccountsToCatchUp", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(prisma.emailAccount.findMany).mockResolvedValue([] as never);
  });

  it("exclut les comptes sans planning de recap et les comptes deconnectes", async () => {
    await getEmailAccountsToCatchUp();

    expect(prisma.emailAccount.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({
          digestSchedule: { isNot: null },
          account: { disconnectedAt: null, refresh_token: { not: null } },
        }),
      }),
    );
  });
});
