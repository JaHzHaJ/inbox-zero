import type { ParsedMessage } from "@/utils/types";
import {
  buildQuotedPlainText,
  quotePlainTextContent,
} from "@/utils/email/quoted-plain-text";
import { convertNewlinesToBr, escapeHtml } from "@/utils/string";

/** Police Outlook par defaut : conservee quand rien n'est configure. */
const DEFAULT_FONT_FAMILY = "Aptos, Calibri, Arial, Helvetica, sans-serif";
const DEFAULT_FONT_SIZE_PT = 12;

export const createOutlookReplyContent = ({
  textContent,
  htmlContent,
  message,
  fontFamily,
  fontSize,
}: {
  textContent?: string;
  htmlContent?: string;
  message: Pick<ParsedMessage, "headers" | "textPlain" | "textHtml">;
  /** Police du corps. Null/absent = police par defaut du fournisseur. */
  fontFamily?: string | null;
  /** Taille en points. Null/absent = taille par defaut du fournisseur. */
  fontSize?: number | null;
}): {
  html: string;
  text: string;
} => {
  const quotedDate = formatEmailDate(new Date(message.headers.date));
  const quotedHeader = `On ${quotedDate}, ${message.headers.from} wrote:`;

  // Detect text direction from original message
  const textDirection = detectTextDirection(textContent || "");
  const dirAttribute = `dir="${textDirection}"`;

  // Format plain text version with proper quoting
  const quotedContent = quotePlainTextContent(message.textPlain);
  const plainText = buildQuotedPlainText({
    textContent,
    quotedHeader,
    quotedContent,
  });

  const messageContent =
    message.textHtml ||
    (message.textPlain ? convertNewlinesToBr(message.textPlain) : "");

  const contentHtml =
    htmlContent || (textContent ? convertNewlinesToBr(textContent) : "");

  // Police configurable par compte ; a defaut, celle d'Outlook.
  const outlookFontStyle = `font-family: ${fontFamily || DEFAULT_FONT_FAMILY}; font-size: ${fontSize || DEFAULT_FONT_SIZE_PT}pt; color: rgb(0, 0, 0);`;

  // La signature n'est PAS ajoutee ici : generate-draft.ts l'ajoute deja au
  // contenu juste apres la redaction. L'ajouter une seconde fois la ferait
  // apparaitre en double dans le brouillon.

  // Format HTML version with Outlook-style formatting
  const html =
    `<div ${dirAttribute} style="${outlookFontStyle}">${contentHtml}</div>
<br>
<div style="border-top: 1px solid #e1e1e1; padding-top: 10px; margin-top: 10px;">
  <div ${dirAttribute} style="font-size: 11pt; color: rgb(0, 0, 0);">${escapeHtml(quotedHeader)}<br></div>
  <div style="margin-top: 10px;">
    ${messageContent}
  </div>
</div>`.trim();

  return {
    text: plainText,
    html,
  };
};

function detectTextDirection(text: string): "ltr" | "rtl" {
  // Basic RTL detection - checks for RTL characters at the start of the text
  const rtlRegex =
    /[\u0591-\u07FF\u200F\u202B\u202E\uFB1D-\uFDFD\uFE70-\uFEFC]/;
  return rtlRegex.test(text.trim().charAt(0)) ? "rtl" : "ltr";
}

export function formatEmailDate(date: Date): string {
  const weekday = date.toLocaleString("en-US", { weekday: "short" });
  const month = date.toLocaleString("en-US", { month: "short" });
  const day = date.getDate();
  const year = date.getFullYear();
  const hour = date.getHours();
  const minute = date.getMinutes();

  // Format: "Thu, 6 Feb 2025 at 23:23"
  return `${weekday}, ${day} ${month} ${year} at ${hour}:${minute.toString().padStart(2, "0")}`;
}
