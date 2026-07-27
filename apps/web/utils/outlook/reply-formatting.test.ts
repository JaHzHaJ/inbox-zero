import { describe, expect, it } from "vitest";
import { createOutlookReplyContent } from "./reply";

const message = {
  headers: {
    date: "2026-07-27T08:52:00Z",
    from: "Corinne Guette <secretariat@example.com>",
    to: "user@example.com",
    subject: "Facture APD",
  },
  textPlain: "Message d'origine.",
  textHtml: "",
} as never;

describe("mise en forme des brouillons", () => {
  it("garde la police Outlook par defaut quand rien n'est configure", () => {
    const { html } = createOutlookReplyContent({
      textContent: "Bonjour,",
      message,
    });

    expect(html).toContain("font-family: Aptos, Calibri, Arial");
    expect(html).toContain("font-size: 12pt");
  });

  it("applique la police configuree sur le compte", () => {
    const { html } = createOutlookReplyContent({
      textContent: "Bonjour,",
      message,
      fontFamily: "Garamond, serif",
      fontSize: 11,
    });

    expect(html).toContain("font-family: Garamond, serif");
    expect(html).toContain("font-size: 11pt");
    expect(html).not.toContain("Aptos");
  });

  it("n'ajoute PAS de signature : generate-draft l'a deja mise dans le contenu", () => {
    // Garde-fou de non-regression. Ajouter la signature ici la faisait
    // apparaitre EN DOUBLE dans le brouillon (constate le 27/07) : le contenu
    // recu contient deja la signature, ajoutee juste apres la redaction.
    const { html } = createOutlookReplyContent({
      textContent: "Bonjour,\n\nBien cordialement,\nCecile",
      message,
      fontFamily: "Garamond, serif",
      fontSize: 11,
    });

    const occurrences = html.split("Bien cordialement").length - 1;
    expect(occurrences).toBe(1);
  });

  it("laisse la structure du corps intacte", () => {
    const { html } = createOutlookReplyContent({
      textContent: "Bonjour,",
      message,
    });

    expect(html).toContain("</div>\n<br>");
    expect(html).not.toContain("</div>\n\n<br>");
  });
});
