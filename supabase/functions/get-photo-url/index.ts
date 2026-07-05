// Mints a short-lived signed URL for a photo, but only after confirming the
// caller is allowed to see it. Visibility is enforced by querying the photos
// table under the caller's JWT (RLS applies); the signed URL is then created
// with the service role so the storage bucket can stay fully private.
//
// Request:  { photo_ids: [uuid, ...] }  (batch to sign a gallery at once)
// Response: { urls: { "<photo_id>": "<signed url>" } }

import { createClient } from "npm:@supabase/supabase-js@2";

const EXPIRY_SECONDS = 3600;

Deno.serve(async (req) => {
  try {
    const { photo_ids } = await req.json().catch(() => ({}));
    if (!Array.isArray(photo_ids) || photo_ids.length === 0 || photo_ids.length > 100) {
      return json({ error: "'photo_ids' must be a non-empty array (max 100)" }, 400);
    }

    // Caller-scoped client: RLS decides which of these photos they may see.
    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: req.headers.get("Authorization")! } } },
    );
    const { data: userData, error: userError } = await userClient.auth.getUser();
    if (userError || !userData.user) return json({ error: "Unauthorized" }, 401);

    const { data: visible } = await userClient
      .from("photos")
      .select("id, storage_path")
      .in("id", photo_ids);
    if (!visible || visible.length === 0) return json({ urls: {} });

    // Service-role client signs URLs for a private bucket. Only paths that
    // passed the visibility query above are ever signed.
    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const urls: Record<string, string> = {};
    for (const photo of visible) {
      const { data: signed } = await admin.storage
        .from("trip-photos")
        .createSignedUrl(photo.storage_path, EXPIRY_SECONDS);
      if (signed?.signedUrl) urls[photo.id] = signed.signedUrl;
    }

    return json({ urls });
  } catch (error) {
    console.error("get-photo-url failed:", error);
    return json({ error: String(error) }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
