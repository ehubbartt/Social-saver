// Ingest pipeline for a shared TikTok/Instagram link.
//
// 1. Create a pending `saves` row for the calling user.
// 2. Resolve the link's public metadata (oEmbed for TikTok, OpenGraph otherwise).
// 3. Download the video's cover frame so the model can SEE the content —
//    TikTok covers usually carry the place name as a text overlay.
// 4. Ask Claude (vision + caption) to classify the content, summarize it,
//    extract places and recipes, and pick the best list for it.
// 5. Geocode extracted places via Nominatim and link them to the save.
// 6. File the save into the chosen list and mark it processed (or failed).
//
// Secrets required: ANTHROPIC_API_KEY (supabase secrets set ANTHROPIC_API_KEY=...)

import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2";
import { encodeBase64 } from "jsr:@std/encoding/base64";

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
          website: {
            type: ["string", "null"],
            description: "Official website URL found via web search. Null if not found.",
          },
          phone: {
            type: ["string", "null"],
            description: "Phone number found via web search. Null if not found.",
          },
        },
        required: ["name", "city", "country", "geocode_query", "website", "phone"],
        additionalProperties: false,
      },
    },
    links: {
      type: "array",
      description: "Links for everything else mentioned or recommended: apps, products, booking pages, official sites, tour operators. Only links actually found via web search or present in the caption. Empty if none.",
      items: {
        type: "object",
        properties: {
          title: { type: "string", description: "What the link is, e.g. 'Flighty on the App Store'" },
          url: { type: "string" },
          kind: { type: "string", enum: ["app", "product", "booking", "social", "website", "other"] },
          note: { type: ["string", "null"], description: "One-line note, e.g. why it was recommended" },
        },
        required: ["title", "url", "kind", "note"],
        additionalProperties: false,
      },
    },
    recipe: {
      type: ["object", "null"],
      description: "Only for cooking content: the recipe as far as it can be reconstructed from the caption and cover frame. Null otherwise.",
      properties: {
        ingredients: { type: "array", items: { type: "string" } },
        steps: { type: "array", items: { type: "string" } },
      },
      required: ["ingredients", "steps"],
      additionalProperties: false,
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
  required: ["content_type", "title", "summary", "places", "links", "recipe", "list"],
  additionalProperties: false,
};

interface ExtractedPlace {
  name: string;
  city: string | null;
  country: string | null;
  geocode_query: string;
  website: string | null;
  phone: string | null;
}

interface ExtractedLink {
  title: string;
  url: string;
  kind: "app" | "product" | "booking" | "social" | "website" | "other";
  note: string | null;
}

interface Extraction {
  content_type: string;
  title: string;
  summary: string;
  places: ExtractedPlace[];
  links: ExtractedLink[];
  recipe: { ingredients: string[]; steps: string[] } | null;
  list: { name: string; emoji: string; is_existing: boolean };
}

Deno.serve(async (req) => {
  const { url } = await req.json().catch(() => ({}));
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

  try {
    const result = await processSave(supabase, userId, save.id, url, platform);
    return json({ ok: true, save_id: save.id, ...result });
  } catch (error) {
    console.error("process-save failed:", error);
    await supabase.from("saves").update({ status: "failed" }).eq("id", save.id);
    return json({ error: String(error), save_id: save.id }, 500);
  }
});

async function processSave(
  supabase: SupabaseClient,
  userId: string,
  saveId: string,
  url: string,
  platform: string,
): Promise<{ places: number; list: string }> {
  // 2. Resolve public metadata for the link.
  const meta = await fetchLinkMetadata(url, platform);

  // 3. Grab the cover frame so the model can read on-screen text overlays.
  const coverImage = meta.thumbnailUrl ? await fetchImage(meta.thumbnailUrl) : null;

  // 4. Classify + extract with Claude, aware of the user's existing lists.
  const { data: lists } = await supabase.from("lists").select("id, name, emoji");
  const extraction = await extractWithClaude(url, platform, meta, coverImage, lists ?? []);

  // 5. Geocode and link places.
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
          website: validUrl(place.website),
          phone: place.phone,
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
      .upsert(placeIds.map((placeId) => ({ save_id: saveId, place_id: placeId })));
  }

  // Replace this save's links with the freshly extracted set (idempotent
  // for re-shares of the same URL).
  await supabase.from("save_links").delete().eq("save_id", saveId);
  const links = extraction.links
    .filter((link) => validUrl(link.url))
    .slice(0, 8)
    .map((link) => ({
      save_id: saveId,
      title: link.title,
      url: link.url,
      kind: link.kind,
      note: link.note,
    }));
  if (links.length > 0) {
    await supabase.from("save_links").insert(links);
  }

  // 6. File into the chosen list (create it if new) and finalize the save.
  const { data: listRow } = await supabase
    .from("lists")
    .upsert(
      { user_id: userId, name: extraction.list.name, emoji: extraction.list.emoji },
      { onConflict: "user_id,name", ignoreDuplicates: false },
    )
    .select("id")
    .single();
  if (listRow) {
    await supabase.from("list_items").upsert({ list_id: listRow.id, save_id: saveId });
  }

  const hasRecipe = extraction.recipe &&
    (extraction.recipe.ingredients.length > 0 || extraction.recipe.steps.length > 0);

  await supabase
    .from("saves")
    .update({
      title: extraction.title || meta.title || null,
      summary: extraction.summary || null,
      thumbnail_url: meta.thumbnailUrl,
      author_name: meta.authorName,
      content_type: extraction.content_type,
      recipe: hasRecipe ? extraction.recipe : null,
      status: "processed",
    })
    .eq("id", saveId);

  return { places: placeIds.length, list: extraction.list.name };
}

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

type ImageMediaType = "image/jpeg" | "image/png" | "image/webp" | "image/gif";

interface CoverImage {
  mediaType: ImageMediaType;
  base64: string;
}

/// Downloads the cover frame and base64-encodes it for the vision request.
/// Downloading here (instead of passing the URL through) keeps signed,
/// short-lived CDN URLs working and lets us skip oversized or non-image files.
async function fetchImage(url: string): Promise<CoverImage | null> {
  try {
    const res = await fetch(url, {
      headers: { "User-Agent": "Mozilla/5.0 (compatible; SocialSaverBot/1.0)" },
      redirect: "follow",
    });
    if (!res.ok) return null;
    const contentType = res.headers.get("content-type")?.split(";")[0].trim();
    const allowed: ImageMediaType[] = ["image/jpeg", "image/png", "image/webp", "image/gif"];
    if (!contentType || !allowed.includes(contentType as ImageMediaType)) return null;
    const bytes = new Uint8Array(await res.arrayBuffer());
    if (bytes.byteLength === 0 || bytes.byteLength > 4_500_000) return null;
    return { mediaType: contentType as ImageMediaType, base64: encodeBase64(bytes) };
  } catch (_) {
    return null;
  }
}

async function extractWithClaude(
  url: string,
  platform: string,
  meta: LinkMetadata,
  coverImage: CoverImage | null,
  lists: { name: string; emoji: string | null }[],
): Promise<Extraction> {
  const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });

  const listNames = lists.length > 0
    ? lists.map((l) => `- ${l.name}`).join("\n")
    : "(the user has no lists yet)";

  const prompt = [
    `A user shared this ${platform} link to their save-for-later app:`,
    `URL: ${url}`,
    `Title/caption: ${meta.title ?? "(unavailable)"}`,
    `Description: ${meta.description ?? "(unavailable)"}`,
    `Author: ${meta.authorName ?? "(unknown)"}`,
    coverImage
      ? "The video's cover frame is attached. Read any on-screen text overlays" +
        " carefully — creators usually burn the place name, dish, or key info" +
        " into the cover — and use what you can see in the scene itself."
      : "No cover frame was available; work from the caption and URL alone.",
    "",
    "Classify the content, write a short title and summary, and extract every",
    "specific physical place mentioned or shown (restaurants, bars, viewpoints,",
    "shops, landmarks). Only extract places you are confident about from the",
    "caption or the image — do not invent places. Captions often contain",
    "hashtags and location hints; use them.",
    "",
    "If this is cooking content, reconstruct the recipe (ingredients and steps)",
    "as far as the caption and cover frame allow; otherwise set recipe to null.",
    "",
    "Use web search to find real links and contact info for what's mentioned:",
    "- each place's official website and phone number",
    "- App Store pages for any app recommended",
    "- official product pages for products or gear",
    "- booking/reservation pages for tours, hotels, or hard-to-book restaurants",
    "Only include a URL you found in search results or in the caption itself.",
    "Never construct or guess a URL — if you can't find it, use null (for place",
    "contact info) or leave it out of links.",
    "",
    "The user's existing lists:",
    listNames,
    "",
    "Pick the existing list that best fits this save, or propose a concise new",
    "one if nothing fits.",
  ].join("\n");

  const content: Anthropic.ContentBlockParam[] = [];
  if (coverImage) {
    content.push({
      type: "image",
      source: { type: "base64", media_type: coverImage.mediaType, data: coverImage.base64 },
    });
  }
  content.push({ type: "text", text: prompt });

  const request = {
    model: "claude-opus-4-8",
    max_tokens: 4096,
    thinking: { type: "adaptive" as const },
    output_config: { format: { type: "json_schema" as const, schema: EXTRACTION_SCHEMA } },
    tools: [{ type: "web_search_20260209" as const, name: "web_search" as const, max_uses: 6 }],
  };

  let messages: Anthropic.MessageParam[] = [{ role: "user", content }];
  let response = await anthropic.messages.create({ ...request, messages });

  // Server-side web search can pause the turn at its iteration limit;
  // re-send with the assistant turn appended and it resumes automatically.
  let continuations = 0;
  while (response.stop_reason === "pause_turn" && continuations < 3) {
    messages = [
      ...messages,
      { role: "assistant", content: response.content as Anthropic.ContentBlockParam[] },
    ];
    response = await anthropic.messages.create({ ...request, messages });
    continuations++;
  }

  // With server tools the content interleaves search blocks and text; the
  // schema-constrained JSON is the final text block.
  const textBlocks = response.content.filter((block) => block.type === "text");
  const text = textBlocks[textBlocks.length - 1];
  if (!text || text.type !== "text") {
    throw new Error(`No text in model response (stop_reason: ${response.stop_reason})`);
  }
  return JSON.parse(text.text) as Extraction;
}

function validUrl(url: string | null): string | null {
  if (!url) return null;
  try {
    const parsed = new URL(url);
    return parsed.protocol === "http:" || parsed.protocol === "https:" ? url : null;
  } catch (_) {
    return null;
  }
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
