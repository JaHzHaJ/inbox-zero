import type { ParsedMessage } from "@/utils/types";

/**
 * "cc" only when the account is in copy and not a direct recipient, so the
 * badge stays rare. Outlook's rawRecipients are authoritative; header strings
 * are the cross-provider fallback.
 */
export function getRecipientRole(
  message: Pick<ParsedMessage, "rawRecipients" | "headers">,
  accountEmail: string,
): "to" | "cc" {
  const normalized = accountEmail.trim().toLowerCase();
  const raw = message.rawRecipients;

  if (raw?.toRecipients?.length || raw?.ccRecipients?.length) {
    const inList = (
      recipients?:
        | { emailAddress?: { address?: string | null } | null }[]
        | null,
    ) =>
      !!recipients?.some(
        (recipient) =>
          recipient.emailAddress?.address?.toLowerCase() === normalized,
      );

    if (inList(raw.ccRecipients) && !inList(raw.toRecipients)) return "cc";
    return "to";
  }

  const toHeader = message.headers.to?.toLowerCase() ?? "";
  const ccHeader = message.headers.cc?.toLowerCase() ?? "";
  if (ccHeader.includes(normalized) && !toHeader.includes(normalized)) {
    return "cc";
  }
  return "to";
}

/**
 * Sorts a digest section in place, newest first. Items whose date is missing
 * or unparsable sink to the end instead of poisoning the comparison.
 */
export function sortDigestItemsByDateDesc<T extends { date?: string }>(
  items: T[],
): T[] {
  const toTime = (date?: string) => {
    if (!date) return Number.NEGATIVE_INFINITY;
    const time = new Date(date).getTime();
    return Number.isNaN(time) ? Number.NEGATIVE_INFINITY : time;
  };
  return items.sort((a, b) => toTime(b.date) - toTime(a.date));
}
