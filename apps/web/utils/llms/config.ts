export const DEFAULT_PROVIDER = "DEFAULT";

export const Provider = {
  OPEN_AI: "openai",
  AZURE: "azure",
  AZURE_FOUNDRY: "azure-foundry",
  VERTEX: "vertex",
  ANTHROPIC: "anthropic",
  BEDROCK: "bedrock",
  GOOGLE: "google",
  GROQ: "groq",
  OPENROUTER: "openrouter",
  AI_GATEWAY: "aigateway",
  OLLAMA: "ollama",
  OPENAI_COMPATIBLE: "openai-compatible",
  CODEX_CLI: "codex-cli",
  CLAUDE_CODE: "claude-code",
};

export const providerOptions: { label: string; value: string }[] = [
  { label: "Default", value: DEFAULT_PROVIDER },
  { label: "Anthropic", value: Provider.ANTHROPIC },
  { label: "OpenAI", value: Provider.OPEN_AI },
  { label: "Azure OpenAI", value: Provider.AZURE },
  { label: "Google", value: Provider.GOOGLE },
  { label: "Groq", value: Provider.GROQ },
  { label: "OpenRouter", value: Provider.OPENROUTER },
  { label: "Vercel AI Gateway", value: Provider.AI_GATEWAY },
  { label: "Claude Code (CLI, sans clé API)", value: Provider.CLAUDE_CODE },
];

/**
 * Fournisseurs qui ne prennent pas de cle API : ils s'appuient sur un outil
 * local deja authentifie (CLI) ou sur un serveur local. Leur imposer une cle
 * empecherait purement et simplement de les selectionner.
 */
const PROVIDERS_WITHOUT_API_KEY: string[] = [
  Provider.CLAUDE_CODE,
  Provider.CODEX_CLI,
  Provider.OLLAMA,
];

export function providerNeedsApiKey(provider: string | null | undefined) {
  return !!provider && !PROVIDERS_WITHOUT_API_KEY.includes(provider);
}
