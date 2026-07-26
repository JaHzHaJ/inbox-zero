import { describe, expect, it } from "vitest";
import { DigestBucket, SystemType } from "@/generated/prisma/enums";
import {
  DIGEST_BUCKET_LABELS,
  DIGEST_BUCKET_ORDER,
  DigestSection,
  getDigestBucket,
} from "./action-buckets";

describe("getDigestBucket", () => {
  it("routes emails needing a response to 'to reply'", () => {
    expect(getDigestBucket({ systemType: SystemType.TO_REPLY })).toBe(
      DigestSection.TO_REPLY,
    );
  });

  it("routes informational system types to 'fyi'", () => {
    for (const systemType of [
      SystemType.FYI,
      SystemType.AWAITING_REPLY,
      SystemType.CALENDAR,
    ]) {
      expect(getDigestBucket({ systemType })).toBe(DigestSection.FYI);
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
      expect(getDigestBucket({ systemType })).toBe(DigestSection.NO_ACTION);
    }
  });

  it("falls back to 'fyi' for custom rules with no system type", () => {
    expect(getDigestBucket({ systemType: null })).toBe(DigestSection.FYI);
    expect(getDigestBucket(undefined)).toBe(DigestSection.FYI);
  });

  it("maps every SystemType to one of the three buckets", () => {
    const buckets = Object.values(SystemType).map((systemType) =>
      getDigestBucket({ systemType }),
    );

    expect(buckets).toHaveLength(Object.values(SystemType).length);
    expect(new Set(buckets)).toEqual(new Set(DIGEST_BUCKET_ORDER));
  });

  it("lets the per-rule override win over the system type", () => {
    expect(
      getDigestBucket({
        systemType: SystemType.NEWSLETTER,
        digestBucket: DigestBucket.TO_REPLY,
      }),
    ).toBe(DigestSection.TO_REPLY);
  });

  it("applies the override to custom rules without a system type", () => {
    expect(
      getDigestBucket({
        systemType: null,
        digestBucket: DigestBucket.NO_ACTION,
      }),
    ).toBe(DigestSection.NO_ACTION);
  });

  it("maps every override value to one of the three sections", () => {
    const sections = Object.values(DigestBucket).map((digestBucket) =>
      getDigestBucket({ digestBucket }),
    );

    expect(new Set(sections)).toEqual(new Set(DIGEST_BUCKET_ORDER));
  });
});

describe("digest bucket presentation", () => {
  it("orders sections: to reply, then fyi, then no action", () => {
    expect(DIGEST_BUCKET_ORDER).toEqual([
      DigestSection.TO_REPLY,
      DigestSection.FYI,
      DigestSection.NO_ACTION,
    ]);
  });

  it("labels every bucket", () => {
    for (const bucket of DIGEST_BUCKET_ORDER) {
      expect(DIGEST_BUCKET_LABELS[bucket]).toBeTruthy();
    }
  });
});
