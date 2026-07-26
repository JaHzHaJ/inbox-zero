import { NextResponse } from "next/server";
import { digestBody } from "./validation";
import { processDigestItem } from "@/utils/digest/process-digest-item";
import { withError } from "@/utils/middleware";
import { withQstashOrInternal } from "@/utils/qstash";

export const POST = withError(
  "digest",
  withQstashOrInternal(async (request) => {
    let logger = request.logger;

    try {
      const body = digestBody.parse(await request.json());

      logger = logger.with({
        emailAccountId: body.emailAccountId,
        messageId: body.message.id,
      });

      await processDigestItem(body, logger);

      return new NextResponse("OK", { status: 200 });
    } catch (error) {
      logger.error("Failed to process digest", { error });
      return new NextResponse("Internal Server Error", { status: 500 });
    }
  }),
);
