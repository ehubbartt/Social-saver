// Ingest pipeline for a shared TikTok/Instagram link.
//
// 1. Create a pending `saves` row for the calling user.
// 2. Resolve the link's public metadata (oEmbed for TikTok, OpenGraph otherwise).
// 3. Ask Claude to classify the content, summarize it, extract places, and
//    pick (or invent) the best list for it, given the user's existing lists.
// 4. Geocode extracted places via Nominatim and link them to the save.
// 5. File the save into the chosen list and mark it processed.
//
// Secrets required: ANTHROPIC_API_KEY (supabase secrets set ANTHROPIC_API_KEY=...)

import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";

const EXTRACTION_SCHEMA = {
  type: "object",
  properties: {
    content_type: {
      type: "string",
      enum: ["place", "restaurant", "recipe", "activity", "shopping", "event", "other"],
      description: "Primary category of the shared content",
    },
    title: { type: "string", description: "Short human-friendly title for the save" },
    summary: { type: "string", description: "One to three sentence summary of the content" },
    places: {
      type: "array",
      description: "Every physical place mentioned or featured. Empty if none.",
      items: {
        type: "object",
        properties: {
          name: { type: "string" },
          city: { type: ["string", "null"] },
          country: { type: ["string", "null"] },
          geocode_query: {
            type: "string",
            description: "Best single-line search query to geocode this place, e.g. 'Katz's Delicatessen, New York, USA'",
          },
        },
        required: ["name", "city", "country", "geocode_query"],
        additionalProperties: false,
      },
    },
    list: {
      type: "object",
      description: "Which list this save belongs in.",
      properties: {
        name: {
          type: "string",
          description: "Exact name of an existing list if one fits, otherwise a concise new list name (e.g. 'NYC Eats', 'Weekend Hikes')",
        },
        emoji: { type: "string", description: "Single emoji for the list" },
        is_existing: { type: "boolean" },
      },
      required: ["name", "emoji", "is_existing"],
      additionalProperties: false,
    },
  },
  required: ["content_type", "title", "summary", "places", "list"],
  additionalProperties: false,
};

interface Extraction {
  content_type: string;
  title: string;
  summary: string;
  places: { name: string; city: string | null; country: string | null; geocode_query: string }[];
  list: { name: string; emoji: string; is_existing: boolean };
}

Deno.serve(async (req) => {
  try {
    const { url } = await req.json();
    if (!url || typeof url !== "string" || !/^https?:\/\//.test(url)) {
      return json({ error: "A valid 'url' is required" }, 400);
    }

    // Client scoped to the caller's JWT so all writes go through RLS.
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: req.headers.get("Authorization")! } } },
    );
    const { data: userData, error: userError } = await supabase.auth.getUser();
    if (userError || !userData.user) return json({ error: "Unauthorized" }, 401);
    const userId = userData.user.id;

    const platform = detectPlatform(url);

    // 1. Create the pending save (idempotent per user+url).
    const { data: save, error: insertError } = await supabase
      .from("saves")
      .upsert(
        { user_id: userId, source_url: url, source_platform: platform, status: "pending" },
        { onConflict: "user_id,source_url" },
      )
      .select()
      .single();
    if (insertError) return json({ error: insertError.message }, 500);

    // 2. Resolve public metadata for the link.
    const meta = await fetchLinkMetadata(url, platform);

    // 3. Classify + extract with Claude, aware of the user's existing lists.
    const { data: lists } = await supabase.from("lists").select("id, name, emoji");
    const extraction = await extractWithClaude(url, platform, meta, lists ?? []);

    // 4. Geocode and link places.
    const placeIds: string[] = [];
    for (const place of extraction.places.slice(0, 5)) {
      const geo = await geocode(place.geocode_query);
      const { data: placeRow } = await supabase
        .from("places")
        .upsert(
          {
            name: place.name,
            city: place.city,
            country: place.country,
            address: geo?.display_name ?? null,
            latitude: geo?.lat ?? null,
            longitude: geo?.lon ?? null,
          },
          { onConflict: "name,city,country" },
        )
        .select("id")
        .single();
      if (placeRow) placeIds.push(placeRow.id);
    }
    if (placeIds.length > 0) {
      await supabase
        .from("save_places")
        .upsert(placeIds.map((placeId) => ({ save_id: save.id, place_id: placeId })));
    }

    // 5. File into the chosen list (create it if new) and finalize the save.
    const { data: listRow } = await supabase
      .from("lists")
      .upsert(
        { user_id: userId, name: extraction.list.name, emoji: extraction.list.emoji },
        { onConflict: "user_id,name", ignoreDuplicates: false },
      )
      .select("id")
      .single();
    if (listRow) {
      await supabase.from("list_items").upsert({ list_id: listRow.id, save_id: save.id });
    }

    await supabase
      .from("saves")
      .update({
        title: extraction.title || meta.title || null,
        summary: extraction.summary || null,
        thumbnail_url: meta.thumbnailUrl,
        author_name: meta.authorName,
        content_type: extraction.content_type,
        status: "processed",
      })
      .eq("id", save.id);

    return json({ ok: true, save_id: save.id, places: placeIds.length, list: extraction.list.name });
  } catch (error) {
    console.error("process-save failed:", error);
    return json({ error: String(error) }, 500);
  }
});

function detectPlatform(url: string): string {
  if (/tiktok\.com/.test(url)) return "tiktok";
  if (/instagram\.com/.test(url)) return "instagram";
  if (/youtube\.com|youtu\.be/.test(url)) return "youtube";
  return "web";
}

interface LinkMetadata {
  title: string | null;
  description: string | null;
  authorName: string | null;
  thumbnailUrl: string | null;
}

async function fetchLinkMetadata(url: string, platform: string): Promise<LinkMetadata> {
  // TikTok has an open oEmbed endpoint with caption + thumbnail.
  if (platform === "tiktok") {
    try {
      const res = await fetch(`https://www.tiktok.com/oembed?url=${encodeURIComponent(url)}`);
      if (res.ok) {
        const data = await res.json();
        return {
          title: data.title ?? null,
          description: data.title ?? null,
          authorName: data.author_name ?? null,
          thumbnailUrl: data.thumbnail_url ?? null,
        };
      }
    } catch (_) { /* fall through to og scrape */ }
  }

  // Instagram's oEmbed needs an FB app token, so scrape OpenGraph tags instead.
  try {
    const res = await fetch(url, {
      headers: { "User-Agent": "Mozilla/5.0 (compatible; SocialSaverBot/1.0)" },
      redirect: "follow",
    });
    const html = (await res.text()).slice(0, 200_000);
    return {
      title: ogTag(html, "og:title"),
      description: ogTag(html, "og:description"),
      authorName: null,
      thumbnailUrl: ogTag(html, "og:image"),
    };
  } catch (_) {
    return { title: null, description: null, authorName: null, thumbnailUrl: null };
  }
}

function ogTag(html: string, property: string): string | null {
  const patterns = [
    new RegExp(`<meta[^>]+property=["']${property}["'][^>]+content=["']([^"']+)["']`, "i"),
    new RegExp(`<meta[^>]+content=["']([^"']+)["'][^>]+property=["']${property}["']`, "i"),
  ];
  for (const pattern of patterns) {
    const match = html.match(pattern);
    if (match) return decodeHtml(match[1]);
  }
  return null;
}

function decodeHtml(text: string): string {
  return text
    .replaceAll("&amp;", "&")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'");
}

async function extractWithClaude(
  url: string,
  platform: string,
  meta: LinkMetadata,
  lists: { name: string; emoji: string | null }[],
): Promise<Extraction> {
  const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });

  const listNames = lists.length > 0
    ? lists.map((l) => `- ${l.name}`).join("\n")
    : "(the user has no lists yet)";

  const response = await anthropic.messages.create({
    model: "claude-opus-4-8",
    max_tokens: 2048,
    thinking: { type: "adaptive" },
    output_config: { format: { type: "json_schema", schema: EXTRACTION_SCHEMA } },
    messages: [
      {
        role: "user",
        content: [
          `A user shared this ${platform} link to their save-for-later app:`,
          `URL: ${url}`,
          `Title/caption: ${meta.title ?? "(unavailable)"}`,
          `Description: ${meta.description ?? "(unavailable)"}`,
          `Author: ${meta.authorName ?? "(unknown)"}`,
          "",
          "Classify the content, write a short title and summary, and extract",
          "every specific physical place mentioned (restaurants, bars, viewpoints,",
          "shops, landmarks). Only extract places you are confident about from the",
          "caption — do not invent places. Captions often contain hashtags and",
          "location hints; use them.",
          "",
          "The user's existing lists:",
          listNames,
          "",
          "Pick the existing list that best fits this save, or propose a concise",
          "new one if nothing fits.",
        ].join("\n"),
      },
    ],
  });

  const text = response.content.find((block) => block.type === "text");
  if (!text || text.type !== "text") {
    throw new Error(`No text in model response (stop_reason: ${response.stop_reason})`);
  }
  return JSON.parse(text.text) as Extraction;
}

interface GeocodeResult {
  lat: number;
  lon: number;
  display_name: string;
}

async function geocode(query: string): Promise<GeocodeResult | null> {
  try {
    const res = await fetch(
      `https://nominatim.openstreetmap.org/search?format=json&limit=1&q=${encodeURIComponent(query)}`,
      { headers: { "User-Agent": "SocialSaver/1.0 (self-hosted save-for-later app)" } },
    );
    if (!res.ok) return null;
    const results = await res.json();
    if (!Array.isArray(results) || results.length === 0) return null;
    return {
      lat: parseFloat(results[0].lat),
      lon: parseFloat(results[0].lon),
      display_name: results[0].display_name,
    };
  } catch (_) {
    return null;
  }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
