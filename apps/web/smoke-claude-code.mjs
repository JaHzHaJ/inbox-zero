// Smoke test: mirrors exactly what utils/llms/cli-provider.ts does with the
// claude-code provider, and what the digest summarizer asks of it
// (generateObject + zod schema). Run from apps/web: node smoke-claude-code.mjs
import { claudeCode } from "ai-sdk-provider-claude-code";
import { generateObject } from "ai";
import { z } from "zod";

const modelName = process.argv[2] ?? "haiku";

const model = claudeCode(modelName, {
  settingSources: [],
  allowedTools: [],
  permissionMode: "default",
  sandbox: { enabled: true, failIfUnavailable: false },
});

const start = Date.now();
const result = await generateObject({
  model,
  schema: z.object({ content: z.string() }),
  system:
    "You are an assistant that summarizes emails for a daily digest. Summarize concisely in the language of the email.",
  prompt:
    "Summarize this email: 'Bonjour, la réunion de chantier du lot 3 est déplacée à jeudi 14h en mairie. Merci de confirmer votre présence et d'apporter le PV précédent.'",
});

console.log(`OK model=${modelName} in ${Date.now() - start}ms`);
console.log("summary:", JSON.stringify(result.object.content));
console.log("usage:", JSON.stringify(result.usage));
