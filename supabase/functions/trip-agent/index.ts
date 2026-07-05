// Conversational trip agent: answers questions about a trip and edits the
// itinerary on request — but ONLY through six strictly-schema'd tools that
// execute server-side under the caller's JWT (RLS scopes every write to the
// caller's own trip). Every tool input is validated again in code and
// invalid calls return corrective errors the model must fix.
//
// Request:  { trip_id, messages: [{ role: "user"|"assistant", content: string }] }
// Response: { reply: string, changed: boolean }
//
// Secrets required: ANTHROPIC_API_KEY

import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2";

const TIME_PATTERN = /^([01]\d|2[0-3]):[0-5]\d$/;

const nullable = (type: string, description: string) => ({
  type: [type, "null"],
  description,
});

const TOOLS: Anthropic.Tool[] = [
  {
    name: "add_stop",
    description:
      "Add a non-save itinerary entry (flight, hotel, transport, or custom stop) to the trip. Use for anything the user asks to add that is not one of their saved videos.",
    strict: true,
    input_schema: {
      type: "object",
      properties: {
        kind: { type: "string", enum: ["flight", "hotel", "transport", "custom"] },
        title: { type: "string", description: "Short display title, e.g. 'UA 837 to Tokyo'" },
        detail: nullable("string", "Confirmation number, terminal, notes. Null if none."),
        day: nullable("integer", "1-based day number, or null for the Ideas bucket"),
        time: nullable("string", "24-hour HH:MM, e.g. '13:00'. Null if unscheduled."),
        address: nullable("string", "Street address if known. Null otherwise."),
        latitude: nullable("number", "Latitude if known. Null otherwise."),
        longitude: nullable("number", "Longitude if known. Null otherwise."),
      },
      required: ["kind", "title", "detail", "day", "time", "address", "latitude", "longitude"],
      additionalProperties: false,
    },
  },
  {
    name: "add_save_to_trip",
    description:
      "Add one of the user's saved videos to this trip. save_id MUST be copied exactly from the <saves> catalog.",
    strict: true,
    input_schema: {
      type: "object",
      properties: {
        save_id: { type: "string", description: "id from the <saves> catalog" },
        day: nullable("integer", "1-based day number, or null for the Ideas bucket"),
      },
      required: ["save_id", "day"],
      additionalProperties: false,
    },
  },
  {
    name: "move_item",
    description: "Move an existing itinerary item to a different day or to the Ideas bucket.",
    strict: true,
    input_schema: {
      type: "object",
      properties: {
        item_id: { type: "string", description: "id from the <itinerary> list" },
        day: nullable("integer", "1-based day number, or null for the Ideas bucket"),
      },
      required: ["item_id", "day"],
      additionalProperties: false,
    },
  },
  {
    name: "set_time",
    description: "Set or clear the scheduled time of an existing itinerary item.",
    strict: true,
    input_schema: {
      type: "object",
      properties: {
        item_id: { type: "string", description: "id from the <itinerary> list" },
        time: nullable("string", "24-hour HH:MM, or null to clear"),
      },
      required: ["item_id", "time"],
      additionalProperties: false,
    },
  },
  {
    name: "set_note",
    description: "Set or clear the short placement note on an existing itinerary item.",
    strict: true,
    input_schema: {
      type: "object",
      properties: {
        item_id: { type: "string", description: "id from the <itinerary> list" },
        note: nullable("string", "One-line note, or null to clear"),
      },
      required: ["item_id", "note"],
      additionalProperties: false,
    },
  },
  {
    name: "remove_item",
    description:
      "Remove an item from the trip. Only call this when the user explicitly asked for a removal.",
    strict: true,
    input_schema: {
      type: "object",
      properties: {
        item_id: { type: "string", description: "id from the <itinerary> list" },
      },
      required: ["item_id"],
      additionalProperties: false,
    },
  },
];

interface ToolOutcome {
  result: string;
  isError: boolean;
  changed: boolean;
}

interface Ctx {
  supabase: SupabaseClient;
  tripId: string;
  dayCount: number;
}

Deno.serve(async (req) => {
  try {
    const { trip_id, messages: clientMessages } = await req.json().catch(() => ({}));
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

    // RLS: only the caller's own trip resolves.
    const { data: trip } = await supabase.from("trips").select().eq("id", trip_id).single();
    if (!trip) return json({ error: "Trip not found" }, 404);
    const dayCount = computeDayCount(trip.start_date, trip.end_date);

    const history = sanitizeMessages(clientMessages);
    if (history.length === 0) return json({ error: "'messages' must end with a user turn" }, 400);

    const system = await buildSystem(supabase, trip, dayCount);
    const ctx: Ctx = { supabase, tripId: trip_id, dayCount };

    const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
    const request = {
      model: "claude-opus-4-8",
      max_tokens: 2000,
      thinking: { type: "adaptive" as const },
      system,
      tools: [
        ...TOOLS,
        { type: "web_search_20260209" as const, name: "web_search" as const, max_uses: 5 },
      ],
    };

    let messages: Anthropic.MessageParam[] = history;
    let changed = false;
    let response = await anthropic.messages.create({ ...request, messages });

    // Agent loop: execute custom tools until the model stops calling them.
    for (let iteration = 0; iteration < 8; iteration++) {
      if (response.stop_reason === "pause_turn") {
        messages = [...messages, { role: "assistant", content: response.content as Anthropic.ContentBlockParam[] }];
        response = await anthropic.messages.create({ ...request, messages });
        continue;
      }
      if (response.stop_reason !== "tool_use") break;

      const toolUses = response.content.filter((block) => block.type === "tool_use");
      messages = [...messages, { role: "assistant", content: response.content as Anthropic.ContentBlockParam[] }];

      const results: Anthropic.ToolResultBlockParam[] = [];
      for (const toolUse of toolUses) {
        const outcome = await executeTool(toolUse.name, toolUse.input, ctx);
        if (outcome.changed) changed = true;
        results.push({
          type: "tool_result",
          tool_use_id: toolUse.id,
          content: outcome.result,
          is_error: outcome.isError,
        });
      }
      messages = [...messages, { role: "user", content: results }];
      response = await anthropic.messages.create({ ...request, messages });
    }

    const reply = response.content
      .filter((block) => block.type === "text")
      .map((block) => (block as { text: string }).text)
      .join("\n")
      .trim();

    return json({
      reply: reply || (changed ? "Done — I've updated your trip." : "Sorry, I couldn't finish that. Try rephrasing?"),
      changed,
    });
  } catch (error) {
    console.error("trip-agent failed:", error);
    return json({ error: String(error) }, 500);
  }
});

function sanitizeMessages(raw: unknown): Anthropic.MessageParam[] {
  if (!Array.isArray(raw)) return [];
  const cleaned = raw
    .filter((entry): entry is { role: string; content: string } =>
      !!entry && typeof entry === "object" &&
      (entry.role === "user" || entry.role === "assistant") &&
      typeof entry.content === "string" && entry.content.length > 0 && entry.content.length <= 4000
    )
    .slice(-24)
    .map((entry) => ({ role: entry.role as "user" | "assistant", content: entry.content }));
  // The API requires the conversation to start with a user turn and this
  // endpoint expects it to end with one.
  while (cleaned.length > 0 && cleaned[0].role !== "user") cleaned.shift();
  if (cleaned.length === 0 || cleaned[cleaned.length - 1].role !== "user") return [];
  return cleaned;
}

async function buildSystem(supabase: SupabaseClient, trip: Record<string, unknown>, dayCount: number): Promise<string> {
  const [{ data: items }, { data: saves }] = await Promise.all([
    supabase
      .from("trip_items")
      .select("id, kind, title, detail, day_index, start_time, note, address, save:saves(id, title, content_type, save_places(place:places(name, city, country)))")
      .eq("trip_id", trip.id)
      .order("day_index", { ascending: true })
      .order("position", { ascending: true }),
    supabase
      .from("saves")
      .select("id, title, summary, content_type, save_places(place:places(name, city, country))")
      .eq("status", "processed")
      .order("created_at", { ascending: false })
      .limit(150),
  ]);

  const itinerary = (items ?? []).map((item) => ({
    id: item.id,
    kind: item.kind,
    title: item.title ?? item.save?.title ?? null,
    day: item.day_index,
    time: item.start_time ? String(item.start_time).slice(0, 5) : null,
    note: item.note,
    address: item.address,
    places: (item.save?.save_places ?? []).map((join: { place: { name: string; city: string } }) =>
      [join.place.name, join.place.city].filter(Boolean).join(", ")
    ),
  }));

  const catalog = (saves ?? []).map((save) => ({
    id: save.id,
    title: save.title,
    type: save.content_type,
    places: (save.save_places ?? []).map((join: { place: { name: string; city: string; country: string } }) =>
      [join.place.name, join.place.city, join.place.country].filter(Boolean).join(", ")
    ),
  }));

  return [
    "You are the trip assistant for one specific trip in a travel-planning",
    "app. You answer questions about the trip, recommend what to do, and",
    "edit the itinerary when asked.",
    "",
    "HARD RULES — follow these exactly:",
    `- Days are integers 1 to ${dayCount}. null means the unscheduled Ideas bucket. Never use any other day value.`,
    "- Times are 24-hour 'HH:MM' strings (e.g. '09:30', '18:00').",
    "- item_id and save_id values MUST be copied character-for-character from",
    "  <itinerary>, <saves>, or a previous tool result. NEVER invent an id.",
    "- Every modification MUST go through a tool call. Never claim you added,",
    "  moved, or removed something unless the tool result confirmed success.",
    "- If a tool returns an error, fix the input and retry, or tell the user",
    "  what went wrong. Do not pretend it worked.",
    "- Only call remove_item when the user explicitly asked to remove that",
    "  item. Never bulk-delete.",
    "- When the user asks to add one of their saved videos, use",
    "  add_save_to_trip with the id from <saves>. Use add_stop only for",
    "  things that are not saves (flights, hotels, new recommendations).",
    "- Use web_search for fresh facts (opening hours, closures, new",
    "  recommendations). If you add a web recommendation to the trip, use",
    "  add_stop and include the address if search revealed it; set latitude",
    "  and longitude to null unless you found exact coordinates.",
    "- You can only see and edit THIS trip. Refuse anything outside trip",
    "  planning for it.",
    "- Keep replies short and concrete. After making changes, summarize what",
    "  changed in one or two sentences.",
    "",
    `<trip>${JSON.stringify({
      name: trip.name,
      destination: trip.destination,
      start_date: trip.start_date,
      end_date: trip.end_date,
      day_count: dayCount,
    })}</trip>`,
    `<itinerary>${JSON.stringify(itinerary)}</itinerary>`,
    `<saves>${JSON.stringify(catalog)}</saves>`,
  ].join("\n");
}

async function executeTool(name: string, input: unknown, ctx: Ctx): Promise<ToolOutcome> {
  try {
    switch (name) {
      case "add_stop":
        return await addStop(input as Record<string, unknown>, ctx);
      case "add_save_to_trip":
        return await addSaveToTrip(input as Record<string, unknown>, ctx);
      case "move_item":
        return await moveItem(input as Record<string, unknown>, ctx);
      case "set_time":
        return await setTime(input as Record<string, unknown>, ctx);
      case "set_note":
        return await setNote(input as Record<string, unknown>, ctx);
      case "remove_item":
        return await removeItem(input as Record<string, unknown>, ctx);
      default:
        return { result: `Unknown tool '${name}'.`, isError: true, changed: false };
    }
  } catch (error) {
    return { result: `Tool failed: ${String(error)}`, isError: true, changed: false };
  }
}

function validateDay(day: unknown, dayCount: number): { ok: true; value: number | null } | { ok: false; error: string } {
  if (day === null) return { ok: true, value: null };
  if (typeof day === "number" && Number.isInteger(day) && day >= 1 && day <= dayCount) {
    return { ok: true, value: day };
  }
  return { ok: false, error: `Invalid day '${day}'. Use an integer 1-${dayCount} or null for Ideas.` };
}

function validateTime(time: unknown): { ok: true; value: string | null } | { ok: false; error: string } {
  if (time === null) return { ok: true, value: null };
  if (typeof time === "string" && TIME_PATTERN.test(time)) return { ok: true, value: `${time}:00` };
  return { ok: false, error: `Invalid time '${time}'. Use 24-hour 'HH:MM', e.g. '09:30'.` };
}

/// Confirms the item exists AND belongs to this trip before any mutation.
async function findItem(ctx: Ctx, itemId: unknown): Promise<{ id: string; title: string } | null> {
  if (typeof itemId !== "string") return null;
  const { data } = await ctx.supabase
    .from("trip_items")
    .select("id, title, save:saves(title)")
    .eq("id", itemId)
    .eq("trip_id", ctx.tripId)
    .maybeSingle();
  if (!data) return null;
  return { id: data.id, title: data.title ?? data.save?.title ?? "item" };
}

async function addStop(input: Record<string, unknown>, ctx: Ctx): Promise<ToolOutcome> {
  const day = validateDay(input.day, ctx.dayCount);
  if (!day.ok) return { result: day.error, isError: true, changed: false };
  const time = validateTime(input.time);
  if (!time.ok) return { result: time.error, isError: true, changed: false };
  const title = typeof input.title === "string" ? input.title.trim() : "";
  if (!title) return { result: "'title' must be a non-empty string.", isError: true, changed: false };

  const { data, error } = await ctx.supabase
    .from("trip_items")
    .insert({
      trip_id: ctx.tripId,
      kind: input.kind,
      title,
      detail: input.detail ?? null,
      day_index: day.value,
      start_time: time.value,
      address: input.address ?? null,
      latitude: typeof input.latitude === "number" ? input.latitude : null,
      longitude: typeof input.longitude === "number" ? input.longitude : null,
    })
    .select("id")
    .single();
  if (error) return { result: `Insert failed: ${error.message}`, isError: true, changed: false };
  return {
    result: `Added '${title}' (item_id: ${data.id}) to ${day.value === null ? "Ideas" : `Day ${day.value}`}.`,
    isError: false,
    changed: true,
  };
}

async function addSaveToTrip(input: Record<string, unknown>, ctx: Ctx): Promise<ToolOutcome> {
  const day = validateDay(input.day, ctx.dayCount);
  if (!day.ok) return { result: day.error, isError: true, changed: false };

  // RLS on saves means another user's id simply won't resolve.
  const { data: save } = await ctx.supabase
    .from("saves")
    .select("id, title")
    .eq("id", input.save_id as string)
    .maybeSingle();
  if (!save) {
    return { result: `save_id '${input.save_id}' not found in the user's saves. Copy an id exactly from <saves>.`, isError: true, changed: false };
  }

  const { data, error } = await ctx.supabase
    .from("trip_items")
    .upsert(
      { trip_id: ctx.tripId, save_id: save.id, day_index: day.value },
      { onConflict: "trip_id,save_id" },
    )
    .select("id")
    .single();
  if (error) return { result: `Failed: ${error.message}`, isError: true, changed: false };
  return {
    result: `Added save '${save.title ?? save.id}' (item_id: ${data.id}) to ${day.value === null ? "Ideas" : `Day ${day.value}`}.`,
    isError: false,
    changed: true,
  };
}

async function moveItem(input: Record<string, unknown>, ctx: Ctx): Promise<ToolOutcome> {
  const day = validateDay(input.day, ctx.dayCount);
  if (!day.ok) return { result: day.error, isError: true, changed: false };
  const item = await findItem(ctx, input.item_id);
  if (!item) return { result: `item_id '${input.item_id}' is not in this trip. Copy an id exactly from <itinerary>.`, isError: true, changed: false };

  const { error } = await ctx.supabase
    .from("trip_items")
    .update({ day_index: day.value })
    .eq("id", item.id)
    .eq("trip_id", ctx.tripId);
  if (error) return { result: `Failed: ${error.message}`, isError: true, changed: false };
  return {
    result: `Moved '${item.title}' to ${day.value === null ? "Ideas" : `Day ${day.value}`}.`,
    isError: false,
    changed: true,
  };
}

async function setTime(input: Record<string, unknown>, ctx: Ctx): Promise<ToolOutcome> {
  const time = validateTime(input.time);
  if (!time.ok) return { result: time.error, isError: true, changed: false };
  const item = await findItem(ctx, input.item_id);
  if (!item) return { result: `item_id '${input.item_id}' is not in this trip.`, isError: true, changed: false };

  const { error } = await ctx.supabase
    .from("trip_items")
    .update({ start_time: time.value })
    .eq("id", item.id)
    .eq("trip_id", ctx.tripId);
  if (error) return { result: `Failed: ${error.message}`, isError: true, changed: false };
  return {
    result: time.value === null ? `Cleared the time on '${item.title}'.` : `Set '${item.title}' to ${String(input.time)}.`,
    isError: false,
    changed: true,
  };
}

async function setNote(input: Record<string, unknown>, ctx: Ctx): Promise<ToolOutcome> {
  const item = await findItem(ctx, input.item_id);
  if (!item) return { result: `item_id '${input.item_id}' is not in this trip.`, isError: true, changed: false };
  const note = input.note === null ? null : String(input.note).slice(0, 300);

  const { error } = await ctx.supabase
    .from("trip_items")
    .update({ note })
    .eq("id", item.id)
    .eq("trip_id", ctx.tripId);
  if (error) return { result: `Failed: ${error.message}`, isError: true, changed: false };
  return { result: `Updated the note on '${item.title}'.`, isError: false, changed: true };
}

async function removeItem(input: Record<string, unknown>, ctx: Ctx): Promise<ToolOutcome> {
  const item = await findItem(ctx, input.item_id);
  if (!item) return { result: `item_id '${input.item_id}' is not in this trip.`, isError: true, changed: false };

  const { error } = await ctx.supabase
    .from("trip_items")
    .delete()
    .eq("id", item.id)
    .eq("trip_id", ctx.tripId);
  if (error) return { result: `Failed: ${error.message}`, isError: true, changed: false };
  return { result: `Removed '${item.title}' from the trip.`, isError: false, changed: true };
}

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
