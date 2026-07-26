import { describe, expect, it } from "vitest";
import {
  getRecipientRole,
  sortDigestItemsByDateDesc,
} from "./digest-item-meta";

const ME = "cecile@laminga.fr";

function outlookMessage({
  to = [] as string[],
  cc = [] as string[],
}): Parameters<typeof getRecipientRole>[0] {
  return {
    rawRecipients: {
      toRecipients: to.map((address) => ({ emailAddress: { address } })),
      ccRecipients: cc.map((address) => ({ emailAddress: { address } })),
    },
    headers: { to: "", from: "", date: "", subject: "" },
  };
}

function headerMessage({
  to = "",
  cc = "",
}): Parameters<typeof getRecipientRole>[0] {
  return { headers: { to, cc, from: "", date: "", subject: "" } };
}

describe("getRecipientRole", () => {
  it("returns 'to' when the account is a direct recipient (rawRecipients)", () => {
    expect(getRecipientRole(outlookMessage({ to: [ME] }), ME)).toBe("to");
  });

  it("returns 'cc' when the account is only in copy (rawRecipients)", () => {
    expect(
      getRecipientRole(outlookMessage({ to: ["autre@x.fr"], cc: [ME] }), ME),
    ).toBe("cc");
  });

  it("prefers 'to' when the account is both direct recipient and in copy", () => {
    expect(getRecipientRole(outlookMessage({ to: [ME], cc: [ME] }), ME)).toBe(
      "to",
    );
  });

  it("is case-insensitive on addresses", () => {
    expect(
      getRecipientRole(
        outlookMessage({ to: ["x@y.fr"], cc: [ME.toUpperCase()] }),
        ME,
      ),
    ).toBe("cc");
  });

  it("falls back to header strings when rawRecipients is absent", () => {
    expect(
      getRecipientRole(
        headerMessage({ to: "Un Autre <autre@x.fr>", cc: `Moi <${ME}>` }),
        ME,
      ),
    ).toBe("cc");
  });

  it("defaults to 'to' when nothing matches", () => {
    expect(getRecipientRole(headerMessage({}), ME)).toBe("to");
  });
});

describe("sortDigestItemsByDateDesc", () => {
  it("sorts newest first", () => {
    const items = [
      { subject: "vieux", date: "2026-07-21T08:00:00Z" },
      { subject: "récent", date: "2026-07-24T10:00:00Z" },
      { subject: "moyen", date: "2026-07-22T09:00:00Z" },
    ];
    expect(sortDigestItemsByDateDesc(items).map((i) => i.subject)).toEqual([
      "récent",
      "moyen",
      "vieux",
    ]);
  });

  it("sinks missing or invalid dates to the end", () => {
    const items = [
      { subject: "sans date" },
      { subject: "daté", date: "2026-07-24T10:00:00Z" },
      { subject: "invalide", date: "pas-une-date" },
    ];
    const sorted = sortDigestItemsByDateDesc(items).map((i) => i.subject);
    expect(sorted[0]).toBe("daté");
    expect(sorted.slice(1)).toEqual(
      expect.arrayContaining(["sans date", "invalide"]),
    );
  });
});
