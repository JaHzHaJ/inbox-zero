import type { ParsedMessage } from "@/utils/types";

/**
 * Out-of-office and other machine-generated replies. Exchange/Outlook and
 * Gmail all prefix the subject, so a normalized prefix match is reliable
 * without access to raw Auto-Submitted headers (which the parsed message
 * doesn't carry).
 *
 * Prefixes are compared accent-insensitively and case-insensitively.
 */
const AUTO_REPLY_SUBJECT_PREFIXES = [
  // Exchange / Outlook
  "automatic reply",
  "reponse automatique",
  "automatische antwort",
  "respuesta automatica",
  // Common vacation responders
  "out of office",
  "out-of-office",
  "absence du bureau",
  "reponse d'absence",
  "message d'absence",
  "auto reply",
  "auto-reply",
  "autoreply",
  "auto:",
];

/** Bounces and delivery notifications come from these mailbox names. */
const AUTOMATED_SENDER_MARKERS = ["mailer-daemon@", "postmaster@"];

function normalize(value: string): string {
  return value.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").trim();
}

export function isAutoReplySubject(subject: string | undefined): boolean {
  if (!subject) return false;
  const normalized = normalize(subject);
  return AUTO_REPLY_SUBJECT_PREFIXES.some((prefix) =>
    normalized.startsWith(prefix),
  );
}

export function isAutoReplyMessage(
  message: Pick<ParsedMessage, "headers">,
): boolean {
  if (isAutoReplySubject(message.headers.subject)) return true;

  const from = normalize(message.headers.from ?? "");
  return AUTOMATED_SENDER_MARKERS.some((marker) => from.includes(marker));
}
