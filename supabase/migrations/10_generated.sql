------------------------------
-- THIS IS A GENERATED FILE --
--  DO NOT MODIFY BY HAND   --
------------------------------

CREATE SCHEMA "sync";

CREATE TYPE "frc_match_level" AS ENUM (
  'practice',
  'qualification',
  'playoff',
  'final'
);

CREATE TYPE "frc_match_status" AS ENUM (
  'scheduled',
  'queuing',
  'on_deck',
  'on_field',
  'finished'
);

CREATE TYPE "frc_alliance_color" AS ENUM (
  'red',
  'blue'
);

CREATE TYPE "scouting_category" AS ENUM (
  'match',
  'pit',
  'drive_team'
);

CREATE TYPE "scouting_data_type" AS ENUM (
  'boolean',
  'number',
  'string',
  'array'
);

CREATE TABLE "users" (
  "id" uuid NOT NULL,
  "created_at" timestamptz NOT NULL,
  "name" text NOT NULL,
  PRIMARY KEY ("id")
);

CREATE TABLE "teams" (
  "number" smallint NOT NULL,
  "verified" boolean NOT NULL DEFAULT false,
  "created_at" timestamptz NOT NULL DEFAULT (now()),
  "name" text NOT NULL,
  "current_event" citext,
  PRIMARY KEY ("number")
);

CREATE TABLE "team_users" (
  "user_id" uuid NOT NULL,
  "team_num" smallint NOT NULL,
  "added_at" timestamptz NOT NULL DEFAULT (now()),
  "added_by" uuid DEFAULT (auth.uid()),
  PRIMARY KEY ("user_id")
);

CREATE TABLE "team_requests" (
  "user_id" uuid NOT NULL DEFAULT (auth.uid()),
  "requested_at" timestamptz NOT NULL DEFAULT (now()),
  "team_num" smallint NOT NULL,
  PRIMARY KEY ("user_id")
);

CREATE TABLE "permission_types" (
  "id" citext NOT NULL,
  "name" text NOT NULL,
  "description" text NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);

CREATE TABLE "permissions" (
  "user_id" uuid NOT NULL,
  "team_num" smallint NOT NULL,
  "granted_at" timestamptz NOT NULL DEFAULT (now()),
  "granted_by" uuid DEFAULT (auth.uid()),
  "type" citext NOT NULL,
  PRIMARY KEY ("user_id", "type")
);

CREATE TABLE "frc_seasons" (
  "year" smallint NOT NULL,
  "name" text NOT NULL,
  PRIMARY KEY ("year")
);

CREATE TABLE "frc_districts" (
  "season" smallint NOT NULL,
  "key" citext NOT NULL,
  "code" citext NOT NULL,
  "name" text NOT NULL,
  PRIMARY KEY ("key")
);

CREATE TABLE "frc_teams" (
  "number" smallint NOT NULL,
  "rookie_season" smallint,
  "name" text NOT NULL,
  "country" text,
  "province" text,
  "city" text,
  "postal_code" text,
  "website" text,
  PRIMARY KEY ("number")
);

CREATE TABLE "frc_event_types" (
  "id" smallint NOT NULL,
  "is_district" boolean NOT NULL,
  "is_championship" boolean NOT NULL,
  "is_division" boolean NOT NULL,
  "is_offseason" boolean NOT NULL,
  "name" text NOT NULL,
  "name_short" text NOT NULL,
  PRIMARY KEY ("id")
);

CREATE TABLE "frc_events" (
  "season" smallint NOT NULL,
  "type" smallint NOT NULL,
  "start_date" date NOT NULL,
  "end_date" date NOT NULL,
  "coordinates" point,
  "week" smallint,
  "key" citext NOT NULL,
  "code" citext NOT NULL,
  "name" text NOT NULL,
  "name_short" text,
  "district_key" citext,
  "timezone" text,
  "country" text,
  "province" text,
  "city" text,
  "address" text,
  "location" text,
  "website" text,
  "postal_code" citext,
  PRIMARY KEY ("key")
);

CREATE TABLE "frc_event_teams" (
  "team_num" smallint NOT NULL,
  "event_key" citext NOT NULL,
  "pit_address" text,
  PRIMARY KEY ("event_key", "team_num")
);

CREATE TABLE "frc_event_rankings" (
  "team_num" smallint NOT NULL,
  "rank" smallint NOT NULL,
  "event_key" citext NOT NULL,
  "wins" smallint NOT NULL,
  "losses" smallint NOT NULL,
  "ties" smallint NOT NULL,
  PRIMARY KEY ("event_key", "rank", "team_num")
);

CREATE TABLE "frc_award_types" (
  "id" smallint NOT NULL,
  "name" text NOT NULL,
  "description" text,
  PRIMARY KEY ("id")
);

CREATE TABLE "frc_event_awards" (
  "type" smallint NOT NULL,
  "team_num" smallint,
  "event_key" citext NOT NULL,
  "name" text NOT NULL,
  "awardee" text
);

CREATE TABLE "frc_event_alliances" (
  "team_num" smallint NOT NULL,
  "alliance" smallint NOT NULL,
  "pick_index" smallint NOT NULL,
  "event_key" citext NOT NULL,
  PRIMARY KEY ("event_key", "alliance", "pick_index")
);

CREATE TABLE "frc_event_announcements" (
  "posted_time" timestamptz NOT NULL,
  "is_resolved" boolean NOT NULL DEFAULT false,
  "event_key" citext NOT NULL,
  "id" text NOT NULL,
  "message" text NOT NULL,
  PRIMARY KEY ("id")
);

CREATE TABLE "frc_matches" (
  "number" smallint NOT NULL,
  "is_replay" boolean NOT NULL DEFAULT false,
  "level" frc_match_level NOT NULL,
  "status" frc_match_status NOT NULL,
  "event_key" citext NOT NULL,
  "key" citext NOT NULL,
  "label" text NOT NULL,
  "scheduled_time" timestamptz,
  "queue_time" timestamptz,
  "start_time" timestamptz,
  PRIMARY KEY ("key")
);

CREATE TABLE "frc_match_teams" (
  "team_num" smallint NOT NULL,
  "station" smallint NOT NULL,
  "alliance" frc_alliance_color NOT NULL,
  "is_surrogate" boolean NOT NULL,
  "is_disqualified" boolean NOT NULL,
  "match_key" citext NOT NULL,
  PRIMARY KEY ("match_key", "alliance", "station")
);

CREATE TABLE "frc_match_results" (
  "red_score" smallint NOT NULL,
  "blue_score" smallint NOT NULL,
  "winner" frc_alliance_color,
  "match_key" citext NOT NULL,
  "score_breakdown" jsonb,
  PRIMARY KEY ("match_key")
);

CREATE TABLE "frc_match_videos" (
  "match_key" citext NOT NULL,
  "video_key" text NOT NULL,
  PRIMARY KEY ("match_key", "video_key")
);

CREATE TABLE "devices" (
  "created_at" timestamptz NOT NULL DEFAULT (now()),
  "id" text NOT NULL,
  "model" text NOT NULL,
  "name" text NOT NULL,
  "fcm_token" text,
  PRIMARY KEY ("id")
);

CREATE TABLE "user_devices" (
  "user_id" uuid NOT NULL,
  "last_login" timestamptz NOT NULL DEFAULT (now()),
  "device_id" text NOT NULL,
  PRIMARY KEY ("user_id", "device_id")
);

CREATE TABLE "device_users" (
  "user_id" uuid NOT NULL,
  "device_id" text NOT NULL,
  PRIMARY KEY ("device_id")
);

CREATE TABLE "notification_types" (
  "id" citext NOT NULL,
  "name" text NOT NULL,
  "description" text NOT NULL,
  PRIMARY KEY ("id")
);

CREATE TABLE "user_subscriptions" (
  "user_id" uuid NOT NULL,
  "subscribed_at" timestamptz NOT NULL DEFAULT (now()),
  "type" citext NOT NULL,
  PRIMARY KEY ("user_id", "type")
);

CREATE TABLE "notifications" (
  "id" uuid NOT NULL DEFAULT (gen_random_uuid()),
  "sent_at" timestamptz NOT NULL DEFAULT (now()),
  "type" citext NOT NULL,
  "topic" citext NOT NULL,
  "title" text NOT NULL,
  "body" text,
  "click_url" text,
  PRIMARY KEY ("id")
);

CREATE TABLE "assigned_matches" (
  "user_id" uuid NOT NULL,
  "alliance" frc_alliance_color NOT NULL,
  "station" smallint NOT NULL,
  "match_key" citext NOT NULL,
  PRIMARY KEY ("user_id", "match_key")
);

CREATE TABLE "assigned_pits" (
  "user_id" uuid NOT NULL,
  "team_num" smallint NOT NULL,
  "event_key" citext NOT NULL,
  PRIMARY KEY ("user_id", "event_key", "team_num")
);

CREATE TABLE "questions" (
  "id" uuid NOT NULL DEFAULT (gen_random_uuid()),
  "season" smallint NOT NULL,
  "index" smallint NOT NULL DEFAULT 0,
  "category" scouting_category NOT NULL,
  "parent_id" uuid,
  "data_type" scouting_data_type,
  "label" text,
  "config" jsonb,
  PRIMARY KEY ("id")
);

CREATE TABLE "submissions" (
  "id" uuid NOT NULL DEFAULT (gen_random_uuid()),
  "category" scouting_category NOT NULL,
  "season" smallint NOT NULL,
  "scouted_team" smallint NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT (now()),
  "scouting_user" uuid DEFAULT (auth.uid()),
  "scouting_team" smallint,
  "event_key" citext,
  "match_key" citext,
  PRIMARY KEY ("id")
);

CREATE TABLE "submission_data" (
  "submission_id" uuid NOT NULL,
  "question_id" uuid NOT NULL,
  "data_num" numeric,
  "data_bool" boolean,
  "data_str" text,
  "data_arr" text[],
  PRIMARY KEY ("submission_id", "question_id")
);

CREATE TABLE "scouting_comments" (
  "id" uuid NOT NULL DEFAULT (gen_random_uuid()),
  "user_id" uuid,
  "team_num" smallint NOT NULL,
  "event_key" citext NOT NULL,
  "content" text NOT NULL,
  PRIMARY KEY ("id")
);

CREATE TABLE "scouting_photos" (
  "id" uuid NOT NULL DEFAULT (gen_random_uuid()),
  "user_id" uuid,
  "team_num" smallint NOT NULL,
  "event_key" citext NOT NULL,
  PRIMARY KEY ("id")
);

CREATE TABLE "sync"."tba_pull_etags" (
  "data_pulled_at" timestamptz NOT NULL,
  "endpoint" text NOT NULL,
  "etag" text NOT NULL,
  PRIMARY KEY ("endpoint")
);

CREATE TABLE "sync"."nexus_push_times" (
  "data_as_of" timestamptz NOT NULL,
  "event_key" citext NOT NULL,
  PRIMARY KEY ("event_key")
);

CREATE UNIQUE INDEX ON "team_users" ("team_num", "user_id");

CREATE INDEX ON "team_users" ("team_num", "added_at");

CREATE INDEX ON "team_users" ("added_by");

CREATE INDEX ON "team_requests" ("team_num", "requested_at");

CREATE INDEX ON "permissions" ("team_num", "type");

CREATE INDEX ON "permissions" ("team_num", "user_id");

CREATE INDEX ON "permissions" ("team_num", "granted_by");

CREATE UNIQUE INDEX ON "frc_districts" ("season", "code");

CREATE UNIQUE INDEX ON "frc_events" ("season", "code");

CREATE INDEX ON "frc_events" ("type", "season");

CREATE INDEX ON "frc_events" ("start_date", "end_date");

CREATE INDEX ON "frc_events" ("district_key");

CREATE UNIQUE INDEX ON "frc_event_teams" ("team_num", "event_key");

CREATE INDEX ON "frc_event_rankings" ("team_num", "event_key");

CREATE INDEX ON "frc_event_awards" ("team_num", "event_key");

CREATE INDEX ON "frc_event_awards" ("event_key");

CREATE UNIQUE INDEX ON "frc_event_alliances" ("team_num", "event_key");

CREATE INDEX ON "frc_event_announcements" ("event_key", "is_resolved");

CREATE UNIQUE INDEX ON "frc_matches" ("event_key", "level", "number", "is_replay");

CREATE INDEX ON "frc_match_teams" ("team_num", "match_key");

CREATE UNIQUE INDEX ON "frc_match_videos" ("video_key");

CREATE UNIQUE INDEX ON "devices" ("fcm_token");

CREATE INDEX ON "user_subscriptions" ("type");

CREATE INDEX ON "notifications" ("sent_at");

CREATE INDEX ON "notifications" ("type");

CREATE INDEX ON "assigned_matches" ("match_key");

CREATE INDEX ON "assigned_pits" ("event_key", "team_num");

CREATE INDEX ON "questions" ("season", "category");

CREATE UNIQUE INDEX ON "questions" ("parent_id", "index");

CREATE INDEX ON "scouting_comments" ("event_key", "team_num");

CREATE INDEX ON "scouting_comments" ("team_num", "event_key");

CREATE INDEX ON "scouting_comments" ("user_id", "event_key", "team_num");

CREATE INDEX ON "scouting_photos" ("team_num", "event_key");

CREATE INDEX ON "scouting_photos" ("event_key", "team_num");

CREATE INDEX ON "scouting_photos" ("user_id", "event_key", "team_num");

ALTER TABLE "teams" ADD FOREIGN KEY ("number") REFERENCES "frc_teams" ("number") ON DELETE RESTRICT;

ALTER TABLE "teams" ADD FOREIGN KEY ("current_event") REFERENCES "frc_events" ("key") ON DELETE SET NULL;

ALTER TABLE "team_users" ADD FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE;

ALTER TABLE "team_users" ADD FOREIGN KEY ("team_num") REFERENCES "teams" ("number") ON DELETE CASCADE;

ALTER TABLE "team_users" ADD FOREIGN KEY ("added_by") REFERENCES "users" ("id") ON DELETE SET NULL;

ALTER TABLE "team_requests" ADD FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE;

ALTER TABLE "team_requests" ADD FOREIGN KEY ("team_num") REFERENCES "teams" ("number") ON DELETE CASCADE;

ALTER TABLE "permissions" ADD FOREIGN KEY ("team_num", "user_id") REFERENCES "team_users" ("team_num", "user_id") ON DELETE CASCADE;

ALTER TABLE "permissions" ADD FOREIGN KEY ("team_num", "granted_by") REFERENCES "team_users" ("team_num", "user_id") ON DELETE CASCADE;

ALTER TABLE "permissions" ADD FOREIGN KEY ("type") REFERENCES "permission_types" ("id") ON DELETE RESTRICT;

ALTER TABLE "frc_districts" ADD FOREIGN KEY ("season") REFERENCES "frc_seasons" ("year") ON DELETE CASCADE;

ALTER TABLE "frc_teams" ADD FOREIGN KEY ("rookie_season") REFERENCES "frc_seasons" ("year") ON DELETE RESTRICT;

ALTER TABLE "frc_events" ADD FOREIGN KEY ("season") REFERENCES "frc_seasons" ("year") ON DELETE CASCADE;

ALTER TABLE "frc_events" ADD FOREIGN KEY ("type") REFERENCES "frc_event_types" ("id") ON DELETE RESTRICT;

ALTER TABLE "frc_events" ADD FOREIGN KEY ("district_key") REFERENCES "frc_districts" ("key") ON DELETE SET NULL;

ALTER TABLE "frc_event_teams" ADD FOREIGN KEY ("event_key") REFERENCES "frc_events" ("key") ON DELETE CASCADE;

ALTER TABLE "frc_event_teams" ADD FOREIGN KEY ("team_num") REFERENCES "frc_teams" ("number") ON DELETE CASCADE;

ALTER TABLE "frc_event_rankings" ADD FOREIGN KEY ("team_num", "event_key") REFERENCES "frc_event_teams" ("team_num", "event_key") ON DELETE CASCADE;

ALTER TABLE "frc_event_awards" ADD FOREIGN KEY ("type") REFERENCES "frc_award_types" ("id") ON DELETE RESTRICT;

ALTER TABLE "frc_event_awards" ADD FOREIGN KEY ("event_key") REFERENCES "frc_events" ("key") ON DELETE CASCADE;

ALTER TABLE "frc_event_awards" ADD FOREIGN KEY ("team_num", "event_key") REFERENCES "frc_event_teams" ("team_num", "event_key") ON DELETE CASCADE;

ALTER TABLE "frc_event_alliances" ADD FOREIGN KEY ("team_num", "event_key") REFERENCES "frc_event_teams" ("team_num", "event_key") ON DELETE CASCADE;

ALTER TABLE "frc_event_announcements" ADD FOREIGN KEY ("event_key") REFERENCES "frc_events" ("key") ON DELETE CASCADE;

ALTER TABLE "frc_matches" ADD FOREIGN KEY ("event_key") REFERENCES "frc_events" ("key") ON DELETE CASCADE;

ALTER TABLE "frc_match_teams" ADD FOREIGN KEY ("match_key") REFERENCES "frc_matches" ("key") ON DELETE CASCADE;

ALTER TABLE "frc_match_teams" ADD FOREIGN KEY ("team_num") REFERENCES "frc_teams" ("number") ON DELETE CASCADE;

ALTER TABLE "frc_match_results" ADD FOREIGN KEY ("match_key") REFERENCES "frc_matches" ("key") ON DELETE CASCADE;

ALTER TABLE "frc_match_videos" ADD FOREIGN KEY ("match_key") REFERENCES "frc_matches" ("key") ON DELETE CASCADE;

ALTER TABLE "user_devices" ADD FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE;

ALTER TABLE "user_devices" ADD FOREIGN KEY ("device_id") REFERENCES "devices" ("id") ON DELETE CASCADE;

ALTER TABLE "user_subscriptions" ADD FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE;

ALTER TABLE "user_subscriptions" ADD FOREIGN KEY ("type") REFERENCES "notification_types" ("id") ON DELETE RESTRICT;

ALTER TABLE "notifications" ADD FOREIGN KEY ("type") REFERENCES "notification_types" ("id") ON DELETE RESTRICT;

ALTER TABLE "assigned_matches" ADD FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE;

ALTER TABLE "assigned_matches" ADD FOREIGN KEY ("match_key") REFERENCES "frc_matches" ("key") ON DELETE CASCADE;

ALTER TABLE "assigned_pits" ADD FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE;

ALTER TABLE "assigned_pits" ADD FOREIGN KEY ("event_key", "team_num") REFERENCES "frc_event_teams" ("event_key", "team_num") ON DELETE CASCADE;

ALTER TABLE "questions" ADD FOREIGN KEY ("parent_id") REFERENCES "questions" ("id") ON DELETE CASCADE;

ALTER TABLE "questions" ADD FOREIGN KEY ("season") REFERENCES "frc_seasons" ("year") ON DELETE RESTRICT;

ALTER TABLE "submissions" ADD FOREIGN KEY ("event_key", "scouted_team") REFERENCES "frc_event_teams" ("event_key", "team_num") ON DELETE RESTRICT;

ALTER TABLE "submissions" ADD FOREIGN KEY ("match_key") REFERENCES "frc_matches" ("key") ON DELETE RESTRICT;

ALTER TABLE "submissions" ADD FOREIGN KEY ("scouting_team") REFERENCES "teams" ("number") ON DELETE SET NULL;

ALTER TABLE "submissions" ADD FOREIGN KEY ("scouting_team", "scouting_user") REFERENCES "team_users" ("team_num", "user_id");

ALTER TABLE "submission_data" ADD FOREIGN KEY ("submission_id") REFERENCES "submissions" ("id") ON DELETE CASCADE;

ALTER TABLE "submission_data" ADD FOREIGN KEY ("question_id") REFERENCES "questions" ("id") ON DELETE RESTRICT;

ALTER TABLE "scouting_comments" ADD FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE SET NULL;

ALTER TABLE "scouting_comments" ADD FOREIGN KEY ("team_num", "event_key") REFERENCES "frc_event_teams" ("team_num", "event_key") ON DELETE RESTRICT;

ALTER TABLE "scouting_photos" ADD FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE SET NULL;

ALTER TABLE "scouting_photos" ADD FOREIGN KEY ("team_num", "event_key") REFERENCES "frc_event_teams" ("team_num", "event_key") ON DELETE RESTRICT;

ALTER TABLE "sync"."nexus_push_times" ADD FOREIGN KEY ("event_key") REFERENCES "frc_events" ("key") ON DELETE CASCADE;
