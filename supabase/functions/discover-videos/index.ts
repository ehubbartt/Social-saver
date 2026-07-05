// Web discovery: find more short-form videos about a place via web search.
// Returns only URLs that actually appeared in search results.
//
// Request:  { place: "Katz's Delicatessen, New York, USA" }
// Response: { videos: [{ title, url, platform, description }] }
//
// Secrets required: ANTHROPIC_API_KEY

import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";

const VIDEOS_SCHEMA = {
  type: "object",
  properties: {
    videos: {
      type: "array",
      description: "Short-form videos about the place found via web search. Empty if none found.",
      items: {
        type: "object",
        properties: {
          title: { type: "string" },
          url: { type: "string", description: "URL copied exactly from a search result" },
          platform: { type: "string", enum: ["tiktok", "instagram", "youtube", "web"] },
          description: { type: ["string", "null"], description: "One line on what the video covers" },
        },
        required: ["title", "url", "platform", "description"],
        additionalProperties: false,
      },
    },
  },
  required: ["videos"],
  additionalProperties: false,
};

interface WebVideo {
  title: string;
  url: string;
  platform: string;
  description: string | null;
}

Deno.serve(async (req) => {
  try {
    const { place } = await req.json().catch(() => ({}));
    if (!place || typeof place !== "string" || place.length > 200) {
      return json({ error: "A 'place' string of up to 200 characters is required" }, 400);
    }

    // Auth gate only — no data access needed, but this endpoint spends API
    // budget, so it must not be callable anonymously.
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: req.headers.get("Authorization")! } } },
    );
    const { data: userData, error: userError } = await supabase.auth.getUser();
    if (userError || !userData.user) return json({ error: "Unauthorized" }, 401);

    const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
    const request = {
      model: "claude-opus-4-8",
      max_tokens: 2000,
      thinking: { type: "adaptive" as const },
      output_config: { format: { type: "json_schema" as const, schema: VIDEOS_SCHEMA } },
      tools: [{ type: "web_search_20260209" as const, name: "web_search" as const, max_uses: 5 }],
    };

    let messages: Anthropic.MessageParam[] = [
      {
        role: "user",
        content: [
          `Find short-form videos about this place: ${place}`,
          "",
          "Search the web for TikTok, Instagram Reels, and YouTube videos",
          "featuring it (try queries like 'site:tiktok.com <place>' and",
          "'<place> tiktok'). Rules:",
          "- Only include URLs copied exactly from search results. Never",
          "  construct or guess a URL.",
          "- Prefer links directly to a video (tiktok.com/@user/video/...,",
          "  instagram.com/reel/..., youtube.com/watch or /shorts).",
          "- Up to 8 results, best first. If you find nothing, return an",
          "  empty list rather than padding with loosely related links.",
        ].join("\n"),
      },
    ];

    let response = await anthropic.messages.create({ ...request, messages });
    let continuations = 0;
    while (response.stop_reason === "pause_turn" && continuations < 3) {
      messages = [
        ...messages,
        { role: "assistant", content: response.content as Anthropic.ContentBlockParam[] },
      ];
      response = await anthropic.messages.create({ ...request, messages });
      continuations++;
    }

    const textBlocks = response.content.filter((block) => block.type === "text");
    const text = textBlocks[textBlocks.length - 1];
    if (!text || text.type !== "text") {
      throw new Error(`No text in model response (stop_reason: ${response.stop_reason})`);
    }
    const parsed = JSON.parse(text.text) as { videos: WebVideo[] };

    // Server-side URL validation, same rule as everywhere else: real links only.
    parsed.videos = parsed.videos.filter((video) => {
      try {
        const url = new URL(video.url);
        return url.protocol === "https:" || url.protocol === "http:";
      } catch (_) {
        return false;
      }
    }).slice(0, 8);

    return json(parsed);
  } catch (error) {
    console.error("discover-videos failed:", error);
    return json({ error: String(error) }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
