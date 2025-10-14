import crypto from "crypto";
import { Buffer } from "buffer";
import { supabase } from "./db_service_role.ts";

const TBA_API_URL = "https://thebluealliance.com/api/v3";
const TBA_API_KEY = Deno.env.get("TBA_API_KEY")!;
const TBA_SECRET = Deno.env.get("TBA_SECRET")!;

export async function tbaFetch(path: string) {
  const { data: etagRow, error: etagReadError } = await supabase
    .schema("tba")
    .from("etags")
    .select("etag")
    .eq("path", path)
    .maybeSingle();

  if (etagReadError) {
    console.log(etagReadError);
    throw new Error(
      `Failed to fetch ETag from database for path: ${path}`,
      etagReadError,
    );
  }

  const headers = new Headers({
    "X-TBA-Auth-Key": TBA_API_KEY,
  });
  // if (etagRow) {
  //   headers.set("If-None-Match", etagRow.etag as string);
  // }

  const response = await fetch(`${TBA_API_URL}${path}`, { headers: headers });

  if (response.status == 304) {
    return;
  }

  if (response.status != 200) {
    throw new Error(
      `TBA API call returned status ${response.status} for path: ${path}`,
    );
  }

  const etag = response.headers.get("ETag");
  if (!etag) {
    throw new Error(`TBA API call didn't return an ETag for path: ${path}`);
  }

  const { error: etagWriteError } = await supabase
    .schema("tba")
    .from("etags")
    .upsert({ path: path, etag: etag });
  if (etagWriteError) {
    throw new Error(`Failed to upsert ETag for path: ${path}`, etagWriteError);
  }

  return response.json();
}

export function tbaIsHmacValid(rawBody: string, signature: string) {
  const expected = crypto
    .createHmac("sha256", TBA_SECRET)
    .update(rawBody)
    .digest("hex");

  return crypto.timingSafeEqual(
    Buffer.from(signature, "utf8"),
    Buffer.from(expected, "utf8"),
  );
}
