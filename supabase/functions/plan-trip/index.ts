// Drafts a trip itinerary from the user's saved videos.
//
// Given a trip, Claude picks the saves relevant to the destination (places
// there, activities, food spots) and assigns each to a day, grouping by
// geography and theme. Existing trip items are (re)assigned to days as part
// of the same plan. Results are written to trip_items; nothing is deleted.
//
// Secrets required: ANTHROPIC_API_KEY

import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";

const PLAN_SCHEMA = {
  type: "object",
  properties: {
    itinerary: {
      type: "array",
      description: "Saves that belong on this trip, each assigned to a day. Exclude saves irrelevant to the destination.",
      items: {
        type: "object",
        properties: {
          save_id: { type: "string" },
          day: { type: "integer", description: "1-based day number" },
          note: {
            type: ["string", "null"],
            description: "Short placement note, e.g. 'Morning — near the fish market'",
          },
        },
        required: ["save_id", "day", "note"],
        additionalProperties: false,
      },
    },
    summary: {
      type: "string",
      description: "One or two sentences describing the shape of the plan",
    },
  },
  required: ["itinerary", "summary"],
  additionalProperties: false,
};

interface Plan {
  itinerary: { save_id: string; day: number; note: string | null }[];
  summary: string;
}

Deno.serve(async (req) => {
  try {
    const { trip_id } = await req.json().catch(() => ({}));
    if (!trip_id || typeof trip_id !== "string") {
      return json({ error: "'trip_id' is required" }, 400);
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: req.headers.get("Authorization")! } } },
    );
    const { data: userData, error: userError } = await supabase.auth.getUser();
    if (userError || !userData.user) return json({ error: "Unauthorized" }, 401);

    // RLS scopes this to the caller's own trips.
    const { data: trip } = await supabase.from("trips").select().eq("id", trip_id).single();
    if (!trip) return json({ error: "Trip not found" }, 404);

    const dayCount = computeDayCount(trip.start_date, trip.end_date);

    const [{ data: items }, { data: saves }] = await Promise.all([
      supabase.from("trip_items").select("save_id, day_index").eq("trip_id", trip_id).eq("kind", "save"),
      supabase
        .from("saves")
        .select("id, title, summary, content_type, save_places(place:places(name, city, country))")
        .eq("user_id", userData.user.id)
        .eq("status", "processed")
        .order("created_at", { ascending: false })
        .limit(200),
    ]);

    if (!saves || saves.length === 0) {
      return json({ planned: 0, summary: "No processed saves to plan from yet." });
    }

    const alreadyInTrip = new Set((items ?? []).map((item) => item.save_id));
    const catalog = saves.map((save) => ({
      id: save.id,
      title: save.title,
      summary: save.summary,
      type: save.content_type,
      places: (save.save_places ?? []).map((join: { place: { name: string; city: string; country: string } }) =>
        [join.place.name, join.place.city, join.place.country].filter(Boolean).join(", ")
      ),
      already_in_trip: alreadyInTrip.has(save.id),
    }));

    const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
    const response = await anthropic.messages.create({
      model: "claude-opus-4-8",
      max_tokens: 3000,
      thinking: { type: "adaptive" },
      output_config: { format: { type: "json_schema", schema: PLAN_SCHEMA } },
      messages: [
        {
          role: "user",
          content: [
            `Plan a trip itinerary from someone's saved TikTok/Instagram videos.`,
            `Trip: "${trip.name}" to ${trip.destination}`,
            trip.start_date
              ? `Dates: ${trip.start_date} to ${trip.end_date ?? trip.start_date}`
              : "Dates: not set yet",
            `Days to plan: ${dayCount} (days are numbered 1 to ${dayCount})`,
            "",
            "Rules:",
            `- Include ONLY saves relevant to ${trip.destination}: places located`,
            "  there or nearby, and activities/food clearly doable on this trip.",
            "  Exclude everything else — a save from another city does not belong.",
            "- Saves marked already_in_trip MUST each be assigned a day.",
            "- Group each day geographically and thematically so it makes sense",
            "  to do together (e.g. same neighborhood, market morning + nearby",
            "  lunch). Spread items across days rather than overloading day 1;",
            "  roughly 2-5 items per day is ideal.",
            "- Give each item a short note about when/why it fits that day.",
            "",
            `Their saves (JSON): ${JSON.stringify(catalog)}`,
          ].join("\n"),
        },
      ],
    });

    const textBlocks = response.content.filter((block) => block.type === "text");
    const text = textBlocks[textBlocks.length - 1];
    if (!text || text.type !== "text") {
      throw new Error(`No text in model response (stop_reason: ${response.stop_reason})`);
    }
    const plan = JSON.parse(text.text) as Plan;

    const knownIds = new Set(saves.map((save) => save.id));
    const assignments = plan.itinerary
      .filter((entry) => knownIds.has(entry.save_id))
      .map((entry) => ({
        trip_id,
        save_id: entry.save_id,
        day_index: Math.min(Math.max(entry.day, 1), dayCount),
        note: entry.note,
      }));

    if (assignments.length > 0) {
      const { error: upsertError } = await supabase
        .from("trip_items")
        .upsert(assignments, { onConflict: "trip_id,save_id" });
      if (upsertError) throw upsertError;
    }

    return json({ planned: assignments.length, summary: plan.summary });
  } catch (error) {
    console.error("plan-trip failed:", error);
    return json({ error: String(error) }, 500);
  }
});

function computeDayCount(start: string | null, end: string | null): number {
  if (!start || !end) return 3;
  const days = Math.round(
    (new Date(end).getTime() - new Date(start).getTime()) / 86_400_000,
  ) + 1;
  return Math.min(Math.max(days, 1), 14);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
