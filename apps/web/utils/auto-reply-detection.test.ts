import { describe, expect, it } from "vitest";
import { isAutoReplyMessage, isAutoReplySubject } from "./auto-reply-detection";

function message(subject: string, from = "collegue@agence.fr") {
  return { headers: { subject, from, to: "", date: "" } };
}

describe("isAutoReplySubject", () => {
  it("detects Exchange French OOF subjects", () => {
    expect(isAutoReplySubject("Réponse automatique : Avenant MOE APD")).toBe(
      true,
    );
    expect(isAutoReplySubject("réponse automatique: congés")).toBe(true);
  });

  it("detects Exchange English OOF subjects", () => {
    expect(isAutoReplySubject("Automatic reply: Project update")).toBe(true);
  });

  it("detects generic out-of-office prefixes", () => {
    expect(isAutoReplySubject("Out of Office - back on Monday")).toBe(true);
    expect(isAutoReplySubject("Absence du bureau")).toBe(true);
  });

  it("ignores ordinary subjects, even when they mention absence later", () => {
    expect(isAutoReplySubject("RE: planning des congés d'été")).toBe(false);
    expect(isAutoReplySubject("Projet avenant MOE APD")).toBe(false);
    expect(isAutoReplySubject(undefined)).toBe(false);
  });
});

describe("isAutoReplyMessage", () => {
  it("flags OOF by subject whatever the sender", () => {
    expect(
      isAutoReplyMessage(message("Réponse automatique : RE: OPR 31 rue Texel")),
    ).toBe(true);
  });

  it("flags bounce senders whatever the subject", () => {
    expect(
      isAutoReplyMessage(
        message(
          "Undeliverable: RE: dossier",
          "Mail Delivery <mailer-daemon@googlemail.com>",
        ),
      ),
    ).toBe(true);
  });

  it("keeps normal business mail untouched", () => {
    expect(
      isAutoReplyMessage(message("RE: Opé Saint Antoine - DIAGOBAH")),
    ).toBe(false);
  });
});
