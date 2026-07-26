import { beforeEach, describe, expect, it, vi } from "vitest";

const {
  envMock,
  captureExceptionMock,
  getEmailAccountsToCatchUpMock,
  catchUpEmailAccountMock,
} = vi.hoisted(() => ({
  envMock: { CRON_SECRET: "cron-secret" },
  captureExceptionMock: vi.fn(),
  getEmailAccountsToCatchUpMock: vi.fn(),
  catchUpEmailAccountMock: vi.fn(),
}));

vi.mock("@/env", () => ({ env: envMock }));

vi.mock("@/utils/error", () => ({
  captureException: (...args: unknown[]) => captureExceptionMock(...args),
}));

vi.mock("@/utils/email/catch-up", () => ({
  CATCH_UP_LOOKBACK_DAYS: 3,
  getEmailAccountsToCatchUp: (...args: unknown[]) =>
    getEmailAccountsToCatchUpMock(...args),
  catchUpEmailAccount: (...args: unknown[]) => catchUpEmailAccountMock(...args),
}));

vi.mock("@/utils/middleware", async () => {
  const { createWithErrorTestMiddleware } = await vi.importActual<
    typeof import("@/__tests__/helpers")
  >("@/__tests__/helpers");

  return createWithErrorTestMiddleware();
});

import { GET } from "./route";

const microsoftAccount = {
  id: "email-account-1",
  email: "user@example.com",
  account: { provider: "microsoft" },
};

const successResult = {
  emailAccountId: "email-account-1",
  email: "user@example.com",
  candidateCount: 12,
  newThreadCount: 3,
  processedCount: 3,
  digestItemsCreated: 2,
  remaining: 0,
};

describe("catch-up cron route", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    envMock.CRON_SECRET = "cron-secret";
    getEmailAccountsToCatchUpMock.mockResolvedValue([microsoftAccount]);
    catchUpEmailAccountMock.mockResolvedValue(successResult);
  });

  it("refuse une requete sans jeton cron", async () => {
    const response = await GET(
      new Request("http://localhost:3000/api/catch-up/all"),
    );

    expect(response.status).toBe(401);
    expect(getEmailAccountsToCatchUpMock).not.toHaveBeenCalled();
    expect(captureExceptionMock).toHaveBeenCalledTimes(1);
  });

  it("rattrape les comptes eligibles avec le jeton cron", async () => {
    const response = await GET(
      new Request("http://localhost:3000/api/catch-up/all", {
        headers: { authorization: "Bearer cron-secret" },
      }),
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({
      done: true,
      lookbackDays: 3,
      accounts: [successResult],
    });
    expect(captureExceptionMock).not.toHaveBeenCalled();
  });

  it("signale done=false quand il reste des fils a traiter", async () => {
    catchUpEmailAccountMock.mockResolvedValue({
      ...successResult,
      remaining: 5,
    });

    const response = await GET(
      new Request("http://localhost:3000/api/catch-up/all", {
        headers: { authorization: "Bearer cron-secret" },
      }),
    );

    await expect(response.json()).resolves.toMatchObject({ done: false });
  });

  it("ignore les fournisseurs non Microsoft", async () => {
    getEmailAccountsToCatchUpMock.mockResolvedValue([
      { ...microsoftAccount, account: { provider: "google" } },
    ]);

    const response = await GET(
      new Request("http://localhost:3000/api/catch-up/all", {
        headers: { authorization: "Bearer cron-secret" },
      }),
    );

    expect(catchUpEmailAccountMock).not.toHaveBeenCalled();
    await expect(response.json()).resolves.toMatchObject({
      done: true,
      accounts: [],
    });
  });

  it("n'interrompt pas la boucle si un compte echoue", async () => {
    catchUpEmailAccountMock.mockRejectedValue(new Error("Graph indisponible"));

    const response = await GET(
      new Request("http://localhost:3000/api/catch-up/all", {
        headers: { authorization: "Bearer cron-secret" },
      }),
    );

    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.done).toBe(false);
    expect(body.accounts[0]).toMatchObject({ error: true, remaining: -1 });
  });
});
