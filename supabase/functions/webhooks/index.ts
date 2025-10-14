// deno-lint-ignore-file no-explicit-any
import express, { Request, Response } from "express";
import { Buffer } from "buffer";

import { tbaFetch, tbaIsHmacValid } from "../_shared/tba.ts";
import { createSupabaseClient } from "../_shared/db.ts";
import { isNexusToken } from "../_shared/nexus.ts";
import { syncSingle } from "../_shared/sync.ts";

const supabase = createSupabaseClient(true);

const server = express();
server.use(express.json({
  verify: (req: Request, _res: Response, buf: Buffer) => {
    (req as any).rawBody = buf;
  },
}));

server.post("/webhooks/nexus", async (req: Request, res: Response) => {
  const authHeader = req.get("Nexus-Token") || "";

  if (!isNexusToken(authHeader)) {
    res.status(401).send("Unauthorized Nexus-Token");
    return;
  }

  const payload = req.body;
  const eventKey = payload?.eventKey;
  if (!eventKey) {
    res.status(400).send("Payload missing event key");
    return;
  }

  const { error } = await supabase
    .schema("nexus")
    .from("event_data")
    .upsert({
      event_key: eventKey,
      data: payload,
      data_as_of_time: new Date(payload.dataAsOfTime).toISOString(),
    });
  if (error) {
    res.status(500);
  } else {
    res.status(200);
  }
});

function unauthorizedError(msg: string): never {
  const error = new Error(msg);
  (error as any).status = 401;
  throw error;
}

// deno-lint-ignore require-await
async function handleUnimplemented(_data: any, res: Response) {
  // Ensure the webhook isn't pruned when a valid type is sent but not implemented
  res.status(200).send();
}

async function handleVerification(data: any, res: Response) {
  const verificationKey = data.verification_key as string;
  await supabase
    .schema("tba")
    .from("verification")
    .insert({ key: verificationKey });
  res.status(200).send();
}

async function handleScheduleUpdated(data: any, res: Response) {
  const eventKey = data.event_key as string;
  res.status(200).send();

  await syncSingle(
    () => tbaFetch(`/event/${eventKey}/matches`),
    (matches) =>
      supabase
        .schema("tba")
        .rpc("merge_matches", {
          event_key: eventKey,
          matches: matches,
        }),
  );
}

async function handleMatchUpdated(data: any, res: Response) {
  const matchKey = data.match.key as string;
  res.status(200).send();

  await supabase
    .schema("tba")
    .from("matches")
    .upsert({ match_key: matchKey, data: data.match });
}

const tbaWebhookHandlers = new Map([
  ["verification", handleVerification],
  ["schedule_updated", handleScheduleUpdated],
  ["match_score", handleMatchUpdated],
  ["match_video", handleMatchUpdated],
  ["alliance_selection", handleUnimplemented], // TODO: pull alliances
  ["awards_posted", handleUnimplemented], // TODO: update awards
  ["broadcast", handleUnimplemented], // TODO: maybe store announcements?

  ["upcoming_match", handleUnimplemented], // no new information for us; ignore
  ["starting_comp_level", handleUnimplemented], // no new information for us; ignore
  ["ping", handleUnimplemented], // unimplemented handler handles this perfectly
]);

server.post("/webhooks/tba", async (req: Request, res: Response) => {
  const signature = req.headers["x-tba-hmac"] as string | undefined;
  if (!signature) {
    unauthorizedError("No X-TBA-HMAC present");
  }

  const rawBody = req.rawBody!.toString("utf-8");
  const valid = tbaIsHmacValid(rawBody, signature);
  if (!valid) {
    unauthorizedError("Invalid HMAC signature");
  }

  const type = req.body.message_type as string;
  let handler = tbaWebhookHandlers.get(type);
  if (!handler) {
    handler = handleUnimplemented;
    // log unknown message type
  }

  const data = req.body.message_data;
  await handler(data, res);
});
