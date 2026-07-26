import { describe, expect, it } from "vitest";
import { SystemType } from "@/generated/prisma/enums";
import {
  DIGEST_BUCKET_LABELS,
  DIGEST_BUCKET_ORDER,
  DigestBucket,
  getDigestBucket,
} from "./action-buckets";

describe("getDigestBucket", () => {
  it("routes emails needing a response to 'to reply'", () => {
    expect(getDigestBucket(SystemType.TO_REPLY)).toBe(DigestBucket.TO_REPLY);
  });

  it("routes informational system types to 'fyi'", () => {
    for (const systemType of [
      SystemType.FYI,
      SystemType.AWAITING_REPLY,
      SystemType.CALENDAR,
    ]) {
      expect(getDigestBucket(systemType)).toBe(DigestBucket.FYI);
    }
  });

  it("folds the six no-action system types into a single bucket", () => {
    for (const systemType of [
      SystemType.ACTIONED,
      SystemType.COLD_EMAIL,
      SystemType.NEWSLETTER,
      SystemType.MARKETING,
      SystemType.RECEIPT,
      SystemType.NOTIFICATION,
    ]) {
      expect(getDigestBucket(systemType)).toBe(DigestBucket.NO_ACTION);
    }
  });

  it("falls back to 'fyi' for custom rules with no system type", () => {
    expect(getDigestBucket(null)).toBe(DigestBucket.FYI);
    expect(getDigestBucket(undefined)).toBe(DigestBucket.FYI);
  });

  it("maps every SystemType to one of the three buckets", () => {
    const buckets = Object.values(SystemType).map(getDigestBucket);

    expect(buckets).toHaveLength(Object.values(SystemType).length);
    expect(new Set(buckets)).toEqual(new Set(DIGEST_BUCKET_ORDER));
  });
});

describe("digest bucket presentation", () => {
  it("orders sections: to reply, then fyi, then no action", () => {
    expect(DIGEST_BUCKET_ORDER).toEqual([
      DigestBucket.TO_REPLY,
      DigestBucket.FYI,
      DigestBucket.NO_ACTION,
    ]);
  });

  it("labels every bucket", () => {
    for (const bucket of DIGEST_BUCKET_ORDER) {
      expect(DIGEST_BUCKET_LABELS[bucket]).toBeTruthy();
    }
  });
});
