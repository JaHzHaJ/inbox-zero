import { describe, expect, it, vi } from "vitest";
import { createTestLogger } from "@/__tests__/helpers";
import { getRepliedThreadDates, hasRepliedSince } from "./already-replied";

const logger = createTestLogger();

function providerAvecEnvois(envois: { threadId: string; date: string }[]) {
  return {
    getSentMessages: vi.fn().mockResolvedValue(envois),
  } as never;
}

describe("hasRepliedSince", () => {
  it("detecte une reponse posterieure au message", async () => {
    const provider = providerAvecEnvois([
      { threadId: "fil-1", date: "2026-07-27T08:54:00Z" },
    ]);

    await expect(
      hasRepliedSince({
        provider,
        threadId: "fil-1",
        messageDate: new Date("2026-07-27T08:52:00Z"),
        logger,
      }),
    ).resolves.toBe(true);
  });

  it("ignore une reponse anterieure au message", async () => {
    // Cas reel : l'utilisatrice repond a 8h54, l'expediteur relance a 9h33.
    // Le brouillon pour la relance doit bien etre redige.
    const provider = providerAvecEnvois([
      { threadId: "fil-1", date: "2026-07-27T08:54:00Z" },
    ]);

    await expect(
      hasRepliedSince({
        provider,
        threadId: "fil-1",
        messageDate: new Date("2026-07-27T09:33:00Z"),
        logger,
      }),
    ).resolves.toBe(false);
  });

  it("ne confond pas deux fils", async () => {
    const provider = providerAvecEnvois([
      { threadId: "fil-2", date: "2026-07-27T10:00:00Z" },
    ]);

    await expect(
      hasRepliedSince({
        provider,
        threadId: "fil-1",
        messageDate: new Date("2026-07-27T08:52:00Z"),
        logger,
      }),
    ).resolves.toBe(false);
  });

  it("ne bloque rien si la lecture des envois echoue", async () => {
    const provider = {
      getSentMessages: vi.fn().mockRejectedValue(new Error("Graph HS")),
    } as never;

    // En cas de doute on n'ecarte rien : mieux vaut un brouillon en trop.
    await expect(
      hasRepliedSince({
        provider,
        threadId: "fil-1",
        messageDate: new Date("2026-07-27T08:52:00Z"),
        logger,
      }),
    ).resolves.toBe(false);
  });

  it("tolere une date de message invalide", async () => {
    const provider = providerAvecEnvois([
      { threadId: "fil-1", date: "2026-07-27T10:00:00Z" },
    ]);

    await expect(
      hasRepliedSince({
        provider,
        threadId: "fil-1",
        messageDate: new Date("pas une date"),
        logger,
      }),
    ).resolves.toBe(false);
  });
});

describe("getRepliedThreadDates", () => {
  it("retient l'envoi le plus recent par fil et ecarte ceux hors fenetre", async () => {
    const provider = providerAvecEnvois([
      { threadId: "fil-1", date: "2026-07-27T09:00:00Z" },
      { threadId: "fil-1", date: "2026-07-27T11:00:00Z" },
      { threadId: "fil-2", date: "2026-07-20T09:00:00Z" },
    ]);

    const dates = await getRepliedThreadDates({
      provider,
      since: new Date("2026-07-25T00:00:00Z"),
      logger,
    });

    expect(dates.get("fil-1")).toBe(new Date("2026-07-27T11:00:00Z").getTime());
    expect(dates.has("fil-2")).toBe(false);
  });
});
