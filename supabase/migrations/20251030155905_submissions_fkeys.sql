alter table "public"."submissions" drop constraint "submissions_event_key_fkey";

alter table "public"."submissions" alter column "event_key" set not null;

CREATE INDEX submissions_scouted_team_match_key_idx ON public.submissions USING btree (scouted_team, match_key);

alter table "public"."submissions" add constraint "submissions_event_key_fkey" FOREIGN KEY (event_key) REFERENCES frc_events(key) ON DELETE RESTRICT not valid;

alter table "public"."submissions" validate constraint "submissions_event_key_fkey";


