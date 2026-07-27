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

  it("ajoute la signature sous le corps, avant le message cite", () => {
    const { html } = createOutlookReplyContent({
      textContent: "Bonjour,",
      message,
      signatureHtml: "<p>Bien cordialement,<br>Cecile</p>",
    });

    const posCorps = html.indexOf("Bonjour,");
    const posSignature = html.indexOf("Bien cordialement");
    const posCitation = html.indexOf("wrote:");

    expect(posSignature).toBeGreaterThan(posCorps);
    expect(posCitation).toBeGreaterThan(posSignature);
  });

  it("laisse la sortie inchangee quand il n'y a pas de signature", () => {
    // Garde-fou de non-regression : le bloc signature ne doit pas introduire de
    // ligne vide, sous peine de casser tous les tests de rendu existants.
    const { html } = createOutlookReplyContent({
      textContent: "Bonjour,",
      message,
    });

    expect(html).not.toContain("</div>\n\n<br>");
    expect(html).toContain("</div>\n<br>");
  });

  it("habille la signature de la meme police que le corps", () => {
    const { html } = createOutlookReplyContent({
      textContent: "Bonjour,",
      message,
      fontFamily: "Garamond, serif",
      fontSize: 11,
      signatureHtml: "<p>Cecile</p>",
    });

    // Deux blocs a la meme police : le corps et la signature. Sans cela Outlook
    // rendrait la signature dans sa police par defaut.
    const occurrences = html.split("font-family: Garamond, serif").length - 1;
    expect(occurrences).toBe(2);
  });
});
