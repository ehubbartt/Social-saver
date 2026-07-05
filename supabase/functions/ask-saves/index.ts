// Conversational recommendations over the caller's own saves —
// "where should I eat this weekend?", "what did I save for Tokyo?".
// Answers are grounded strictly in the user's saved items; the model
// returns the ids of the saves it recommends so the app can render them.
//
// Secrets required: ANTHROPIC_API_KEY

import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";

const ANSWER_SCHEMA = {
  type: "object",
  properties: {
    answer: {
      type: "string",
      description: "Conversational answer grounded only in the user's saves",
    },
    save_ids: {
      type: "array",
      items: { type: "string" },
      description: "ids of the saves recommended or referenced in the answer, best first. Empty if none apply.",
    },
  },
  required: ["answer", "save_ids"],
  additionalProperties: false,
};

interface Answer {
  answer: string;
  save_ids: string[];
}

Deno.serve(async (req) => {
  try {
    const { question } = await req.json().catch(() => ({}));
    if (!question || typeof question !== "string" || question.length > 500) {
      return json({ error: "A 'question' of up to 500 characters is required" }, 400);
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: req.headers.get("Authorization")! } } },
    );
    const { data: userData, error: userError } = await supabase.auth.getUser();
    if (userError || !userData.user) return json({ error: "Unauthorized" }, 401);

    const [{ data: saves }, { data: lists }] = await Promise.all([
      supabase
        .from("saves")
        .select("id, title, summary, content_type, source_platform, created_at, save_places(place:places(name, city, country))")
        .order("created_at", { ascending: false })
        .limit(200),
      supabase.from("lists").select("name, emoji, list_items(save_id)"),
    ]);

    if (!saves || saves.length === 0) {
      return json({
        answer: "You haven't saved anything yet — share a video from TikTok or Instagram and I'll have something to work with!",
        save_ids: [],
      });
    }

    // Compact representation to keep the prompt small.
    const catalog = saves.map((save) => ({
      id: save.id,
      title: save.title,
      summary: save.summary,
      type: save.content_type,
      places: (save.save_places ?? []).map((join: { place: { name: string; city: string; country: string } }) =>
        [join.place.name, join.place.city, join.place.country].filter(Boolean).join(", ")
      ),
      saved: save.created_at?.slice(0, 10),
    }));

    const listCatalog = (lists ?? []).map((list) => ({
      name: `${list.emoji ?? ""} ${list.name}`.trim(),
      save_ids: (list.list_items ?? []).map((item: { save_id: string }) => item.save_id),
    }));

    const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
    const response = await anthropic.messages.create({
      model: "claude-opus-4-8",
      max_tokens: 1500,
      thinking: { type: "adaptive" },
      output_config: { format: { type: "json_schema", schema: ANSWER_SCHEMA } },
      messages: [
        {
          role: "user",
          content: [
            "You help someone decide what to do using ONLY their personal",
            "saved items from TikTok/Instagram below. Recommend specific saves",
            "by title, explain briefly why they fit the question, and be",
            "decisive — pick favorites rather than listing everything. If",
            "nothing in the saves fits, say so honestly instead of inventing",
            "options. Keep the answer to a short paragraph or a few bullets.",
            "",
            `Their saved items (JSON): ${JSON.stringify(catalog)}`,
            `Their lists (JSON): ${JSON.stringify(listCatalog)}`,
            "",
            `Question: ${question}`,
          ].join("\n"),
        },
      ],
    });

    const textBlocks = response.content.filter((block) => block.type === "text");
    const text = textBlocks[textBlocks.length - 1];
    if (!text || text.type !== "text") {
      throw new Error(`No text in model response (stop_reason: ${response.stop_reason})`);
    }
    const parsed = JSON.parse(text.text) as Answer;

    // Only pass back ids that really belong to this user's saves.
    const knownIds = new Set(saves.map((save) => save.id));
    parsed.save_ids = parsed.save_ids.filter((id) => knownIds.has(id));

    return json(parsed);
  } catch (error) {
    console.error("ask-saves failed:", error);
    return json({ error: String(error) }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
