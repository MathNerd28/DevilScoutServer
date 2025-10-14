import express, { NextFunction, Request, Response } from "express";

import { isServiceRole } from "../_shared/db.ts";
import { sendSyncResult, syncBatch, syncSingle } from "../_shared/sync.ts";
import { nexusFetch } from "../_shared/nexus.ts";
import { tbaFetch } from "../_shared/tba.ts";
import { supabase } from "../_shared/db_service_role.ts";

const server = express();
server.use((req: Request, res: Response, next: NextFunction) => {
  const authHeader = req.header("apikey") as string | undefined;
  if (!authHeader || !isServiceRole(authHeader)) {
    res.status(401).send("Unauthorized");
  }
  next();
});
server.use(express.json());

server.get("/sync/nexus/event-list", async (_req: Request, res: Response) => {
  const result = await syncSingle(
    () => nexusFetch("/events"),
    (events) =>
      supabase
        .schema("nexus")
        .rpc("merge_events", { events: events }),
  );

  sendSyncResult(result, res);
});

server.get("/sync/nexus/event-data", async (_req: Request, res: Response) => {
  const { data } = await supabase
    .schema("nexus")
    .from("events")
    .select("event_key")
    .is("deleted_at", null);

  const result = await syncBatch(
    data!.map((e) => e.event_key),
    (eventKey) => nexusFetch(`/event/${eventKey}`),
    (eventKey, eventData) =>
      supabase
        .schema("nexus")
        .from("event_data")
        .upsert({ event_key: eventKey, data: eventData }),
  );

  sendSyncResult(result, res);
});

server.get("/sync/nexus/maps", async (_req: Request, res: Response) => {
  const { data } = await supabase
    .schema("nexus")
    .from("events")
    .select("event_key")
    .is("deleted_at", null);

  const result = await syncBatch(
    data!.map((e) => e.event_key),
    (eventKey) => nexusFetch(`/event/${eventKey}/map`),
    (eventKey, pitMap) =>
      supabase
        .schema("nexus")
        .from("pit_maps")
        .upsert({ event_key: eventKey, data: pitMap }),
  );

  sendSyncResult(result, res);
});

server.get("/sync/nexus/pits", async (_req: Request, res: Response) => {
  const { data } = await supabase
    .schema("nexus")
    .from("events")
    .select("event_key")
    .is("deleted_at", null);

  const result = await syncBatch(
    data!.map((e) => e.event_key),
    (eventKey) => nexusFetch(`/event/${eventKey}/pits`),
    (eventKey, pitAddresses) =>
      supabase
        .schema("nexus")
        .from("pit_addresses")
        .upsert({ event_key: eventKey, data: pitAddresses }),
  );

  sendSyncResult(result, res);
});

server.get("/sync/tba/status", async (_req: Request, res: Response) => {
  const result = await syncSingle(
    () => tbaFetch("/status"),
    (status) =>
      supabase.schema("tba").from("api_status").upsert({ data: status }),
  );
  sendSyncResult(result, res);
});

server.get("/sync/tba/events", async (req: Request, res: Response) => {
  const yearStr = req.query["year"];
  if (!yearStr) {
    res.status(400).send("Missing 'year' parameter");
    return;
  }
  const year = Number(yearStr);

  const result = await syncBatch(
    [year],
    (year) => tbaFetch(`/events/${year}`),
    (year, events) => {
      return supabase
        .schema("tba")
        .rpc("merge_events", {
          year: year,
          events: events,
        });
    },
  );

  sendSyncResult(result, res);
});

server.get("/sync/tba/teams", async (_req: Request, res: Response) => {
  const { data } = await supabase
    .schema("tba")
    .from("api_status")
    .select("data->max_team_page")
    .single();
  const pages = Array((data!.max_team_page as number) + 1).keys(); // [0, 1, 2, ..., n]

  const result = await syncBatch(
    pages,
    (pageNum) => tbaFetch(`/teams/${pageNum}`),
    (pageNum, teams) =>
      supabase.schema("tba").rpc("merge_teams", {
        page: pageNum,
        teams: teams,
      }),
  );

  sendSyncResult(result, res);
});

server.get("/sync/tba/districts", async (req: Request, res: Response) => {
  const yearStr = req.query["year"];
  if (!yearStr) {
    res.status(400).send("Missing 'year' parameter");
    return;
  }
  const year = Number(yearStr);

  const result = await syncBatch(
    [year],
    (year) => tbaFetch(`/districts/${year}`),
    (year, districts) =>
      supabase
        .schema("tba")
        .rpc("merge_districts", {
          year: year,
          districts: districts,
        }),
  );

  sendSyncResult(result, res);
});

// TODO: filter matches
server.get("/sync/tba/matches", async (req: Request, res: Response) => {
  const eventsStr = req.query["events"];
  if (!eventsStr) {
    res.status(400).send("Missing 'events' parameter");
    return;
  }
  const eventKeys = eventsStr.split(',');

  const result = await syncBatch(
    eventKeys,
    (eventKey) => tbaFetch(`/event/${eventKey}/matches`),
    (eventKey, matches) =>
      supabase
        .schema("tba")
        .rpc("merge_matches", {
          event_key: eventKey,
          matches: matches,
        }),
  );

  sendSyncResult(result, res);
});

// TODO: filter events
server.get("/sync/tba/event-teams", async (req: Request, res: Response) => {
  const keyPrefix = req.query["keyPrefix"];
  if (!keyPrefix) {
    res.status(400).send("Missing 'keyPrefix' parameter");
    return;
  }

  const { data } = await supabase
    .schema("tba")
    .from("events")
    .select("event_key")
    .like("event_key", `${keyPrefix}%`);

  const result = await syncBatch(
    data!.map((e) => e.event_key),
    (eventKey) => tbaFetch(`/event/${eventKey}/teams/keys`),
    (eventKey, teamKeys) =>
      supabase
        .schema("tba")
        .rpc("merge_event_teams", {
          event_key: eventKey,
          team_keys: teamKeys,
        }),
  );

  sendSyncResult(result, res);
});

// TODO: filter events
server.get("/sync/tba/rankings", async (_req: Request, res: Response) => {
  const { data } = await supabase
    .schema("tba")
    .from("events")
    .select("event_key");

  const result = await syncBatch(
    data!.map((e) => e.event_key),
    (eventKey) => tbaFetch(`/event/${eventKey}/rankings`),
    (eventKey, rankings) =>
      supabase
        .schema("tba")
        .rpc("merge_event_rankings", {
          event_key: eventKey,
          rankings: rankings,
        }),
  );

  sendSyncResult(result, res);
});

server.listen(3000);
