// Shared fixtures for unit tests (not imported by production code).
import type { NormalisedMessage, ProviderInput, ToolSpec } from "./providers/types.ts";

export const WEATHER_TOOL: ToolSpec = {
  name: "log_water",
  description: "Log a water intake entry",
  input_schema: {
    type: "object",
    $schema: "http://json-schema.org/draft-07/schema#",
    additionalProperties: false,
    properties: {
      amount_ml: { type: "integer", minimum: 1, maximum: 5000, description: "Amount in ml" },
      logged_at: { type: "string", format: "date-time" },
      note: { type: ["string", "null"], format: "email", maxLength: 200 },
      tags: { type: "array", items: { type: "string", enum: ["a", "b"] }, maxItems: 3 },
    },
    required: ["amount_ml"],
  },
};

/** user text -> assistant (thinking + text + tool_call) -> user tool_result. */
export function conversation(opaqueProvider: "anthropic" | "openai" | "gemini"): NormalisedMessage[] {
  return [
    { role: "user", content: [{ type: "text", text: "Log 500 ml of water" }] },
    {
      role: "assistant",
      content: [
        { type: "opaque", provider: opaqueProvider, data: { type: "thinking", thinking: "hmm", signature: "sig-1" } },
        { type: "text", text: "Logging it." },
        {
          type: "tool_call",
          id: "call_1",
          name: "log_water",
          arguments: { amount_ml: 500 },
          provider_meta: { thought_signature: "gem-sig" },
        },
      ],
    },
    {
      role: "user",
      content: [{
        type: "tool_result",
        tool_call_id: "call_1",
        name: "log_water",
        content: '{"ok":true}',
        is_error: false,
      }],
    },
  ];
}

export function input(messages: NormalisedMessage[], tools: ToolSpec[] = [WEATHER_TOOL]): ProviderInput {
  return { model: "m-1", system: "You are a coach.", messages, tools, maxTokens: 1024 };
}

export function bodyOf(init: RequestInit): Record<string, unknown> {
  return JSON.parse(String(init.body));
}

export function headersOf(init: RequestInit): Record<string, string> {
  return init.headers as Record<string, string>;
}
