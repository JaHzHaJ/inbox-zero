import { beforeEach, describe, expect, it, vi } from "vitest";
import { getEmail, getEmailAccount } from "@/__tests__/helpers";
import { DigestDetailLevel } from "@/generated/prisma/enums";
import { aiSummarizeEmailForDigest } from "./summarize-email-for-digest";

const { createGenerateObjectMock, generateObjectMock, getModelForUseCaseMock } =
  vi.hoisted(() => ({
    createGenerateObjectMock: vi.fn(),
    generateObjectMock: vi.fn(),
    getModelForUseCaseMock: vi.fn(),
  }));

vi.mock("@/utils/llms", () => ({
  createGenerateObject: createGenerateObjectMock,
}));

vi.mock("@/utils/llms/use-cases", async () => {
  const actual = await vi.importActual<typeof import("@/utils/llms/use-cases")>(
    "@/utils/llms/use-cases",
  );

  return {
    ...actual,
    getModelForUseCase: getModelForUseCaseMock,
  };
});

const emailAccount = { ...getEmailAccount(), name: null };

async function summarizeWith(detailLevel?: DigestDetailLevel) {
  await aiSummarizeEmailForDigest({
    ruleName: "toReply",
    emailAccount,
    detailLevel,
    messageToSummarize: getEmail({
      from: "sender@example.com",
      subject: "Quarterly update",
      content: "Several things happened this quarter.",
    }),
  });

  return generateObjectMock.mock.calls[0][0].system as string;
}

describe("aiSummarizeEmailForDigest detail level", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    createGenerateObjectMock.mockReturnValue(generateObjectMock);
    generateObjectMock.mockResolvedValue({ object: { content: "A summary." } });
    getModelForUseCaseMock.mockReturnValue({ model: "test-model" });
  });

  it("asks for key points at KEY_POINTS", async () => {
    const system = await summarizeWith(DigestDetailLevel.KEY_POINTS);

    expect(system).toContain("1-5 key points");
    expect(system).not.toContain("exactly ONE sentence");
  });

  it("constrains the summary to a single line at ONE_LINE", async () => {
    const system = await summarizeWith(DigestDetailLevel.ONE_LINE);

    expect(system).toContain("exactly ONE sentence");
    expect(system).toContain("Do NOT use newlines");
  });

  it("defaults to key points when no level is given", async () => {
    const system = await summarizeWith(undefined);

    expect(system).toContain("1-5 key points");
  });

  it("keeps the shared guidelines regardless of level", async () => {
    const system = await summarizeWith(DigestDetailLevel.ONE_LINE);

    // The detail level tunes length only; it must not drop the base rules.
    expect(system).toContain("Do NOT mention the sender's name");
  });

  it("uses the economy model, not the default one", async () => {
    await summarizeWith(DigestDetailLevel.KEY_POINTS);

    expect(getModelForUseCaseMock).toHaveBeenCalledWith(
      emailAccount.user,
      "digest-email-summary",
    );
  });
});
