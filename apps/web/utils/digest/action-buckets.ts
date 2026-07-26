import { SystemType } from "@/generated/prisma/enums";

/**
 * The digest is grouped by "action required" rather than by rule.
 * Keys are camelCase so they can be used directly as digest section keys.
 */
export const DigestBucket = {
  TO_REPLY: "toReply",
  FYI: "fyi",
  NO_ACTION: "noAction",
} as const;

export type DigestBucket = (typeof DigestBucket)[keyof typeof DigestBucket];

/** Section order in the digest email. */
export const DIGEST_BUCKET_ORDER: DigestBucket[] = [
  DigestBucket.TO_REPLY,
  DigestBucket.FYI,
  DigestBucket.NO_ACTION,
];

export const DIGEST_BUCKET_LABELS: Record<DigestBucket, string> = {
  [DigestBucket.TO_REPLY]: "À répondre",
  [DigestBucket.FYI]: "Pour information",
  [DigestBucket.NO_ACTION]: "Aucune action nécessaire",
};

/**
 * Rules are routed by system type, not by name: names are user-editable and
 * get translated, system types don't. Declared as a full Record so adding a
 * SystemType upstream fails the build here instead of silently defaulting.
 */
const SYSTEM_TYPE_TO_BUCKET: Record<SystemType, DigestBucket> = {
  [SystemType.TO_REPLY]: DigestBucket.TO_REPLY,
  [SystemType.FYI]: DigestBucket.FYI,
  [SystemType.AWAITING_REPLY]: DigestBucket.FYI,
  [SystemType.CALENDAR]: DigestBucket.FYI,
  [SystemType.ACTIONED]: DigestBucket.NO_ACTION,
  [SystemType.COLD_EMAIL]: DigestBucket.NO_ACTION,
  [SystemType.NEWSLETTER]: DigestBucket.NO_ACTION,
  [SystemType.MARKETING]: DigestBucket.NO_ACTION,
  [SystemType.RECEIPT]: DigestBucket.NO_ACTION,
  [SystemType.NOTIFICATION]: DigestBucket.NO_ACTION,
};

/**
 * Custom rules have no system type. They fall back to "for information"
 * so they still show up rather than being dropped from the digest.
 */
export function getDigestBucket(
  systemType: SystemType | null | undefined,
): DigestBucket {
  if (!systemType) return DigestBucket.FYI;
  return SYSTEM_TYPE_TO_BUCKET[systemType] ?? DigestBucket.FYI;
}
