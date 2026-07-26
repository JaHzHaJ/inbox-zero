import {
  DigestBucket as DigestBucketOverride,
  SystemType,
} from "@/generated/prisma/enums";

/**
 * The digest is grouped by "action required" rather than by rule.
 * Keys are camelCase so they can be used directly as digest section keys.
 */
export const DigestSection = {
  TO_REPLY: "toReply",
  FYI: "fyi",
  NO_ACTION: "noAction",
} as const;

export type DigestSection = (typeof DigestSection)[keyof typeof DigestSection];

/** Section order in the digest email. */
export const DIGEST_BUCKET_ORDER: DigestSection[] = [
  DigestSection.TO_REPLY,
  DigestSection.FYI,
  DigestSection.NO_ACTION,
];

export const DIGEST_BUCKET_LABELS: Record<DigestSection, string> = {
  [DigestSection.TO_REPLY]: "À répondre",
  [DigestSection.FYI]: "Pour information",
  [DigestSection.NO_ACTION]: "Aucune action nécessaire",
};

/**
 * Rules are routed by system type, not by name: names are user-editable and
 * get translated, system types don't. Declared as a full Record so adding a
 * SystemType upstream fails the build here instead of silently defaulting.
 */
const SYSTEM_TYPE_TO_SECTION: Record<SystemType, DigestSection> = {
  [SystemType.TO_REPLY]: DigestSection.TO_REPLY,
  [SystemType.FYI]: DigestSection.FYI,
  [SystemType.AWAITING_REPLY]: DigestSection.FYI,
  [SystemType.CALENDAR]: DigestSection.FYI,
  [SystemType.ACTIONED]: DigestSection.NO_ACTION,
  [SystemType.COLD_EMAIL]: DigestSection.NO_ACTION,
  [SystemType.NEWSLETTER]: DigestSection.NO_ACTION,
  [SystemType.MARKETING]: DigestSection.NO_ACTION,
  [SystemType.RECEIPT]: DigestSection.NO_ACTION,
  [SystemType.NOTIFICATION]: DigestSection.NO_ACTION,
};

/** Per-rule override (Rule.digestBucket) mapped onto section keys. */
const OVERRIDE_TO_SECTION: Record<DigestBucketOverride, DigestSection> = {
  [DigestBucketOverride.TO_REPLY]: DigestSection.TO_REPLY,
  [DigestBucketOverride.FYI]: DigestSection.FYI,
  [DigestBucketOverride.NO_ACTION]: DigestSection.NO_ACTION,
};

/**
 * The per-rule override wins over the system-type mapping. Custom rules
 * without either fall back to "for information" so they still show up
 * rather than being dropped from the digest.
 */
export function getDigestBucket(rule?: {
  systemType?: SystemType | null;
  digestBucket?: DigestBucketOverride | null;
}): DigestSection {
  if (rule?.digestBucket) return OVERRIDE_TO_SECTION[rule.digestBucket];
  if (!rule?.systemType) return DigestSection.FYI;
  return SYSTEM_TYPE_TO_SECTION[rule.systemType] ?? DigestSection.FYI;
}
