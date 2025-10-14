CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS btree_gin WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;
-- User metadata
-- Synced with auth.users, but public-facing
CREATE TABLE profiles (
  user_id uuid PRIMARY KEY
    REFERENCES auth.users ON DELETE CASCADE,
  created_at timestamptz NOT NULL,
  name text NOT NULL
);

-- Team metadata, e.g. names
CREATE TABLE teams (
  created_at timestamptz NOT NULL
    DEFAULT now(),
  number smallint PRIMARY KEY,
  name text NOT NULL,

  -- fuzzy search by name/number
  search_term text NOT NULL
    GENERATED ALWAYS AS (number::text || name) STORED
);

CREATE INDEX ON teams USING GIN(search_term gin_trgm_ops);

-- User-team relationships
-- Each user may be on just a single team
-- Must explicitly set added_by to NULL to insert first member
-- Unique/FK order provides a useful second index instead of redundancy
CREATE TABLE team_users (
  user_id uuid PRIMARY KEY
    REFERENCES profiles ON DELETE CASCADE,
  added_at timestamptz NOT NULL
    DEFAULT now(),
  team_num smallint NOT NULL
    REFERENCES teams ON DELETE CASCADE,
  added_by uuid
    DEFAULT auth.uid()
    REFERENCES profiles ON DELETE SET NULL,

  UNIQUE (team_num, user_id),
  FOREIGN KEY (team_num, added_by)
    REFERENCES team_users (team_num, user_id)
    ON DELETE SET NULL (added_by)
);

-- Requests by users to join teams
-- Users may have at most one request open
-- Requests require that the user is not on a team
CREATE TABLE team_requests (
  user_id uuid PRIMARY KEY
    REFERENCES profiles ON DELETE CASCADE,
  requested_at timestamptz NOT NULL
    DEFAULT now(),
  team_num smallint NOT NULL
    REFERENCES teams ON DELETE CASCADE
);

CREATE INDEX ON team_requests (team_num, requested_at);

CREATE FUNCTION validate_team_request()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.team_users
    WHERE user_id = NEW.user_id
  ) THEN
    RAISE EXCEPTION 'Team member % cannot request to join a team', NEW.user_id;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER validate
  BEFORE INSERT ON public.team_requests
  FOR EACH ROW EXECUTE PROCEDURE validate_team_request();

CREATE FUNCTION delete_team_request()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  DELETE FROM public.team_requests request
    WHERE request.user_id = NEW.user_id;
  RETURN NEW;
END;
$$;

CREATE TRIGGER delete_request
  AFTER INSERT ON public.team_users
  FOR EACH ROW EXECUTE PROCEDURE delete_team_request();

-- Types of permissions
-- Not writable except manually by service_role
-- See seed for types
CREATE TABLE permission_types (
  id text PRIMARY KEY,
  name text NOT NULL,
  description text NOT NULL
    DEFAULT ''
);

-- User permissions
CREATE TABLE permissions (
  user_id uuid NOT NULL,
  granted_at timestamptz NOT NULL
    DEFAULT now(),
  team_num smallint NOT NULL,
  type text NOT NULL
    REFERENCES permission_types,
  granted_by uuid
    DEFAULT auth.uid(),

  PRIMARY KEY (user_id, type),
  FOREIGN KEY (team_num, user_id)
    REFERENCES team_users (team_num, user_id)
    ON DELETE CASCADE,
  FOREIGN KEY (team_num, granted_by)
    REFERENCES team_users (team_num, user_id)
    ON DELETE SET NULL (granted_by)
);

CREATE FUNCTION require_admin()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF (
    OLD.type = 'team.admin'
  ) AND NOT EXISTS (
    SELECT 1 FROM public.permissions
    WHERE
      team_num = OLD.team_num AND
      type = 'team.admin'
  ) AND EXISTS (
    SELECT 1 FROM public.teams
    WHERE number = OLD.team_num
  ) THEN
    RAISE EXCEPTION 'Team % must have at least one member with team.admin permission', OLD.team_num;
  END IF;

  RETURN NEW;
END;
$$;

GRANT SELECT ON TABLE teams TO supabase_auth_admin;

-- deferrable for deleting a team
CREATE CONSTRAINT TRIGGER on_delete
  AFTER DELETE ON permissions DEFERRABLE
  FOR EACH ROW EXECUTE PROCEDURE require_admin();

-- Users automatically gain privileges when creating a team
CREATE FUNCTION teams_register()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF auth.uid() IS NOT NULL
  THEN
    -- Make the user a member
    INSERT INTO team_users
      (user_id, team_num) VALUES
      (auth.uid(), NEW.number);

    -- Grant them all permissions
    INSERT INTO permissions
      (user_id, team_num, type)
      (
        SELECT
          (SELECT auth.uid()),
          NEW.number,
          id
        FROM permission_types
      );
  END IF;

  IF NOT NEW.verified
  THEN
    -- Notify developers of new unverified team via email
    PERFORM net.http_post(
      url := 'https://api.resend.com/emails',
      body := jsonb_build_object(
        'from', 'Devil Scout Notifier <notify@devilscout.org>',
        'to', 'devilscoutfrc@gmail.com',
        'subject', 'Unverified Team Created',
        'html', format(
          '<p>Dear Developer,</p>'
          '<p>A user just registered team %s, which is marked as unverified in the database. Please review the team''s owner and mark the team as verified.</p>'
          '<p>Best, Devil Scout''s Database</p>', NEW.number
        )
      ),
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || (
          SELECT decrypted_secret
          FROM vault.decrypted_secrets
          WHERE name = 'resend_api_key'
        )
      )
    );
  END IF;

  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION teams_register FROM public, anon;

CREATE TRIGGER teams_register
  AFTER INSERT ON teams
  FOR EACH ROW EXECUTE PROCEDURE teams_register();
-- https://supabase.com/docs/guides/database/postgres/custom-claims-and-role-based-access-control-rbac
CREATE FUNCTION public.jwt_claims_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  claims jsonb;
  user_team_num smallint;
  user_requested_team_num smallint;
  user_permissions text[];
BEGIN
  claims := event->'claims';

  -- team
  SELECT team_num INTO user_team_num FROM public.team_users
    WHERE user_id = (event->>'user_id')::uuid;

  IF user_team_num IS NOT NULL THEN
    claims := jsonb_set(claims, '{team_num}', to_jsonb(user_team_num));
    claims := jsonb_set(claims, '{team_name}', to_jsonb(
      (
        SELECT name FROM public.teams t WHERE t.number = user_team_num
      )::text
    ));
  END IF;

  -- team request
  SELECT team_num INTO user_requested_team_num FROM public.team_requests
    WHERE user_id = (event->>'user_id')::uuid;

  IF user_requested_team_num IS NOT NULL THEN
    claims := jsonb_set(claims, '{requested_team_num}', to_jsonb(user_requested_team_num));
    claims := jsonb_set(claims, '{requested_team_name}', to_jsonb(
      (
        SELECT name FROM public.teams t WHERE t.number = user_requested_team_num
      )::text
    ));
  END IF;

  -- permissions
  SELECT array_agg(type) INTO user_permissions FROM public.permissions
    WHERE user_id = (event->>'user_id')::uuid;

  IF user_permissions IS NOT NULL THEN
    claims := jsonb_set(claims, '{permissions}', to_jsonb(user_permissions));
  END IF;

  -- Inject the claims into the event
  RETURN jsonb_set(event, '{claims}', claims);
END;
$$;

GRANT USAGE ON SCHEMA public TO supabase_auth_admin;

GRANT EXECUTE
  ON FUNCTION public.jwt_claims_hook
  TO supabase_auth_admin;

REVOKE EXECUTE
  ON FUNCTION public.jwt_claims_hook
  FROM authenticated, anon, public;

GRANT SELECT
  ON TABLE public.team_users
  TO supabase_auth_admin;

GRANT SELECT
  ON TABLE public.team_requests
  TO supabase_auth_admin;

GRANT SELECT
  ON TABLE public.permissions
  TO supabase_auth_admin;

CREATE POLICY "Supabase Auth can read team names" ON public.teams
  FOR SELECT TO supabase_auth_admin
  USING (true);

CREATE POLICY "Supabase Auth can read team numbers" ON public.team_users
  FOR SELECT TO supabase_auth_admin
  USING (true);

CREATE POLICY "Supabase Auth can read team requests" ON public.team_requests
  FOR SELECT TO supabase_auth_admin
  USING (true);

CREATE POLICY "Supabase Auth can read permissions" ON public.permissions
  FOR SELECT TO supabase_auth_admin
  USING (true);

CREATE FUNCTION create_user_profile()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO public.profiles
    (user_id, name, created_at) VALUES
    (
      NEW.id,
      NEW.raw_user_meta_data->>'full_name',
      NEW.created_at
    );
  RETURN NEW;
END;
$$;

CREATE FUNCTION update_user_profile()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE public.profiles
    SET
      name = NEW.raw_user_meta_data->>'full_name'
    WHERE
      user_id = NEW.id;
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION create_user_profile FROM public, anon, authenticated;
REVOKE EXECUTE ON FUNCTION update_user_profile FROM public, anon, authenticated;

CREATE TRIGGER create_profile
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE PROCEDURE create_user_profile();

CREATE TRIGGER update_profile
AFTER UPDATE ON auth.users
FOR EACH ROW EXECUTE PROCEDURE update_user_profile();
-- Synchronized data read by the application
-- Not user writable
-- Contains only the fields we're interested in

-- Different types of matches
CREATE TYPE frc_match_level AS ENUM (
  'practice',
  'qualification',
  'playoff',
  'eighthfinal',
  'quarterfinal',
  'semifinal',
  'final'
);

CREATE TYPE frc_match_status AS ENUM (
  'scheduled', -- the default state
  'queuing',   -- the match has been queued (combines queuing and on_deck)
  'on_field', -- the match is running (on_field)
  'score_posted' -- the score has been posted on TBA
  -- replays: go back to scheduled/queuing
);

CREATE TYPE frc_alliance_color AS ENUM (
  'red',
  'blue'
);

CREATE TYPE frc_video_type AS ENUM (
  'youtube',
  'tba'
);

-- List of seasons
-- Dynamic, manually populated
-- Must add new seasons; we don't have a source for new season names yet
CREATE TABLE frc_seasons (
  year smallint PRIMARY KEY,
  name text NOT NULL
);

-- List of event types
-- Static, manually populated in seed
-- Source: https://github.com/the-blue-alliance/the-blue-alliance/blob/master/consts/event_type.py
-- TODO: handle this differently?
CREATE TABLE frc_event_types (
  id smallint PRIMARY KEY,
  is_district boolean NOT NULL,
  is_championship boolean NOT NULL,
  is_division boolean NOT NULL,
  is_offseason boolean NOT NULL,
  name text NOT NULL,
  name_short text NOT NULL
);

-- List of award types
-- Static, manually populated in seed
-- Source: https://github.com/the-blue-alliance/the-blue-alliance/blob/master/consts/award_type.py
-- TODO: handle this differently?
CREATE TABLE frc_award_types (
  id smallint PRIMARY KEY,
  name text NOT NULL,
  description text NOT NULL
    DEFAULT ''
);

-- List of districts
-- Synchronized from TBA
CREATE TABLE frc_districts (
  season smallint NOT NULL
    REFERENCES frc_seasons ON DELETE RESTRICT,
  key citext PRIMARY KEY,
  name text NOT NULL
);

-- List of teams
-- Synchronized from TBA
CREATE TABLE frc_teams (
  number smallint PRIMARY KEY,
  rookie_season smallint
    REFERENCES frc_seasons ON DELETE RESTRICT,
  name text NOT NULL,
  country text,
  province text,
  city text,
  website text,

  -- Enable fuzzy text search by name/number
  search_term text NOT NULL
    GENERATED ALWAYS AS (number::text || name) STORED
);

CREATE INDEX ON frc_teams
  USING GIN(search_term gin_trgm_ops);

-- List of all events
-- Synchronized from TBA
CREATE TABLE frc_events (
  season smallint NOT NULL
    REFERENCES frc_seasons ON DELETE RESTRICT,
  type smallint NOT NULL
    REFERENCES frc_event_types ON DELETE RESTRICT,
  start_date date NOT NULL,
  end_date date NOT NULL,
  has_nexus boolean NOT NULL
    DEFAULT false,

  key citext PRIMARY KEY,
  name text NOT NULL,

  name_short text,
  district_key citext
    REFERENCES frc_districts ON DELETE SET NULL,
  country text,
  province text,
  city text,
  location text,
  website text,

  -- speed up fuzzy search over several columns
  search_term text NOT NULL
    GENERATED ALWAYS AS (
      key ||
      name ||
      COALESCE(country, '') ||
      COALESCE(province, '') ||
      COALESCE(city, '')
    ) STORED
);

CREATE INDEX ON frc_events (season, type);
CREATE INDEX ON frc_events (start_date, end_date);
CREATE INDEX ON frc_events (district_key);
CREATE INDEX ON frc_events USING GIN (search_term gin_trgm_ops);

-- List teams attending events
-- Rows synced from TBA
-- Pit address from Nexus
-- team_num does NOT reference frc_teams to handle offseason demos + duplicates
CREATE TABLE frc_event_teams (
  team_num smallint NOT NULL,
  event_key citext NOT NULL
    REFERENCES frc_events ON DELETE CASCADE,
  remap_team_num smallint,
  pit_address text,

  PRIMARY KEY (event_key, team_num),
  UNIQUE (team_num, event_key)
);

-- Individual team rankings
-- Synced from TBA
-- subteam for duplicates (e.g. 1678 @ 2022mttd)
CREATE TABLE frc_rankings (
  team_num smallint NOT NULL,
  rank smallint NOT NULL,
  wins smallint NOT NULL,
  losses smallint NOT NULL,
  ties smallint NOT NULL,
  event_key citext NOT NULL
    REFERENCES frc_events ON DELETE CASCADE,
  subteam char(1),

  PRIMARY KEY (event_key, team_num, subteam),
  FOREIGN KEY (event_key, team_num)
    REFERENCES frc_event_teams ON DELETE CASCADE
);

CREATE INDEX ON frc_rankings (team_num, event_key);

-- List of event awards
-- Synced from TBA
-- Team/awardee can be null if awarded to the other type
CREATE TABLE frc_awards (
  type smallint NOT NULL
    REFERENCES frc_award_types ON DELETE RESTRICT,
  event_key citext NOT NULL
    REFERENCES frc_events ON DELETE CASCADE,
  award_name text NOT NULL,
  team_num smallint,
  awardee_name text,
  subteam char(1),

  -- TODO: no primary key is possible! (type, event_key, name) is not unique!

  FOREIGN KEY (event_key, team_num)
    REFERENCES frc_event_teams ON DELETE CASCADE,
  CONSTRAINT frc_awards_team_or_individual
    CHECK (team_num IS NOT NULL OR awardee_name IS NOT NULL)
);

CREATE INDEX ON frc_awards (event_key, type);
CREATE INDEX ON frc_awards (team_num, event_key)
  WHERE team_num IS NOT NULL;

-- List of alliances at events
-- Synced from TBA
CREATE TABLE frc_alliances (
  team_num smallint NOT NULL,
  alliance smallint NOT NULL,
  pick_index smallint NOT NULL,
  event_key citext NOT NULL,
  subteam char(1),

  PRIMARY KEY (event_key, alliance, pick_index),
  FOREIGN KEY (event_key, team_num)
    REFERENCES frc_event_teams ON DELETE CASCADE,
  UNIQUE (team_num, event_key, subteam)
);

-- List of public event announcements
-- Synced from Nexus
CREATE TABLE frc_announcements (
  posted_time timestamptz NOT NULL,
  is_resolved boolean NOT NULL
    DEFAULT false,
  id text PRIMARY KEY,
  event_key citext NOT NULL
    REFERENCES frc_events ON DELETE CASCADE,
  message text NOT NULL
);

-- match keys are formatted as follows:
-- - event key (same as TBA/Nexus) followed by an underscore _
-- - match type:
--   - practice: pm
--   - qualification: qm
--   - eight-final: ef
--   - quarterfinal: qf
--   - semifinal: sf
--   - playoff: po
--   - final: fn
-- - set number (this is deprecated, but remains for historical compatibility)
-- - "_m" followed by the match number within the set

-- To map TBA to match keys:
-- - if event's playoff_type = 5 and match is semifinal:
--   - this is the new double-elimination bracket
--   - type is playoff
--   - set is 1
--   - match is set
-- - otherwise:
--   - leave everything as-is

-- To map Nexus to match keys:
-- - event key: as-is
-- - match type: playoff = semifinal
-- - set number: always 1 (all events from 2022 or later)

-- List of matches
-- Synced from both TBA and Nexus
-- Nexus can increment replay
-- If event uses Nexus, then Nexus controls the times completely
CREATE TABLE frc_matches (
  status frc_match_status NOT NULL
    DEFAULT 'scheduled',
  level frc_match_level NOT NULL,
  set smallint NOT NULL,
  number smallint NOT NULL,

  key citext PRIMARY KEY
    GENERATED ALWAYS AS (
      event_key ||
      '-' ||
      (
        CASE
          WHEN level = 'practice' THEN 'p'
          WHEN level = 'qualification' THEN 'q'
          WHEN level = 'playoff' THEN 'pf'
          WHEN level = 'eighthfinal' THEN 'ef'
          WHEN level = 'quarterfinal' THEN 'qf'
          WHEN level = 'semifinal' THEN 'sf'
          WHEN level = 'final' THEN 'f'
        END
      ) ||
      set::text ||
      '-m' ||
      number::text
    ) STORED,
  event_key citext NOT NULL
    REFERENCES frc_events ON DELETE CASCADE,
  label text NOT NULL
    GENERATED ALWAYS AS (
      (
        CASE
          WHEN level = 'practice' THEN 'Practice ' || number::text
          WHEN level = 'qualification' THEN 'Qualification ' || number::text
          WHEN level = 'playoff' THEN 'Playoff ' || number::text
          WHEN level = 'final' THEN 'Final ' || number::text
          WHEN level = 'eighthfinal' THEN 'Eighth-Final ' || set::text || '-' || number::text
          WHEN level = 'quarterfinal' THEN 'Quarterfinal ' || set::text || '-' || number::text
          WHEN level = 'semifinal' THEN 'Semifinal ' || set::text || '-' || number::text
          ELSE '???'
        END
      ) || (
        CASE
          WHEN replay IS NULL THEN ''
          WHEN replay = 1 THEN ' Replay'
          ELSE ' Replay ' || replay::text
        END
      )
    ) STORED,
  replay smallint NOT NULL
    DEFAULT 0,

  scheduled_time timestamptz,
  queue_time timestamptz,
  start_time timestamptz,

  red_score smallint,
  blue_score smallint,
  winner frc_alliance_color,

  UNIQUE (event_key, level, set, number)
);

-- Teams in a match
-- Synced from both TBA and Nexus
CREATE TABLE frc_match_teams (
  team_num smallint NOT NULL
    REFERENCES frc_teams ON DELETE NO ACTION,
  station smallint NOT NULL,
  alliance frc_alliance_color NOT NULL,
  is_surrogate boolean NOT NULL
    DEFAULT false,
  is_disqualified boolean NOT NULL
    DEFAULT false,
  match_key citext NOT NULL
    REFERENCES frc_matches ON DELETE CASCADE,
  subteam char(1),

  PRIMARY KEY (match_key, alliance, station)
);

CREATE INDEX ON frc_match_teams (team_num, match_key);

-- Match breakdowns
-- Synced from TBA
-- TODO: how to parse into this format?
CREATE TABLE frc_match_breakdowns (
  match_key citext NOT NULL
    REFERENCES frc_matches ON DELETE CASCADE,
  alliance frc_alliance_color NOT NULL,
  score_breakdown jsonb NOT NULL,

  PRIMARY KEY (match_key, alliance)
);

CREATE INDEX ON frc_match_breakdowns
  USING GIN(score_breakdown jsonb_ops);

-- Match videos
-- Synced from TBA
CREATE TABLE frc_match_videos (
  match_key citext NOT NULL
    REFERENCES frc_matches ON DELETE CASCADE,
  video_type frc_video_type NOT NULL,
  video_key text NOT NULL,

  PRIMARY KEY (match_key, video_type, video_key)
);
-- These tables store raw data directly from Nexus, hardly touched
-- Nexus API v1: https:--frc.nexus/api/v1/docs

CREATE SCHEMA nexus;

-- List of events currently active on Nexus
CREATE TABLE nexus.events (
  event_key text PRIMARY KEY,
  data jsonb NOT NULL,
  create_time timestamptz NOT NULL
    DEFAULT now(),
  update_time timestamptz NOT NULL
    DEFAULT now(),
  delete_time timestamptz
);

CREATE FUNCTION nexus.events_trigger() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$
    BEGIN
      UPDATE frc_events
        SET has_nexus = TRUE
        WHERE key = NEW.event_key;

      -- TODO: use other data from this API?

      RETURN NULL;
    END;
  $$;

CREATE TRIGGER events_insert AFTER INSERT ON nexus.events
  FOR EACH ROW EXECUTE FUNCTION nexus.events_trigger();
-- no update trigger yet

-- Event snapshots from Nexus
CREATE TABLE nexus.event_data (
  event_key text PRIMARY KEY,
  data jsonb NOT NULL,
  data_as_of_time timestamptz NOT NULL,
  create_time timestamptz NOT NULL
    DEFAULT now(),
  update_time timestamptz NOT NULL
    DEFAULT now()
);

CREATE FUNCTION nexus.event_data_trigger() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$
    BEGIN
      WITH nexus_announcements AS (
        SELECT
          j->>'id' AS id,
          j->>'announcement' AS message,
          TO_TIMESTAMP((j->'postedTime')::bigint / 1000) AS posted_time
        FROM jsonb_array_elements(NEW.data->'announcements') AS a(j)
        UNION
        SELECT
          j->>'id' AS id,
          ('Team ' || j->>'requestedByTeam' || ' is requesting ' || j->>'parts') AS message,
          TO_TIMESTAMP((j->'postedTime')::bigint / 1000) AS posted_time
        FROM jsonb_array_elements(NEW.data->'partsRequests') AS a(j)
      )
      MERGE INTO frc_announcements fa
        USING nexus_announcements na ON
          fa.id = na.id
      WHEN NOT MATCHED BY TARGET
        THEN INSERT
        (posted_time, id, event_key, message) VALUES
        (na.posted_time, na.id, NEW.event_key, na.message)
      WHEN MATCHED
        THEN UPDATE SET
          fa.posted_time = na.posted_time,
          fa.message = na.message,
          fa.event_key = na.event_key
      WHEN NOT MATCHED BY SOURCE
        AND fa.event_key = NEW.event_key
        THEN UPDATE SET
          fa.resolved = TRUE;

      WITH nexus_matches AS (
        SELECT
          j->>'label' AS label,
          j->>'status' AS status,
          TO_TIMESTAMP((j#>'{times,scheduledStartTime}')::bigint / 1000) AS scheduled_time,
          TO_TIMESTAMP((j#>'{times,actualQueueTime}')::bigint / 1000) AS actual_queue_time,
          TO_TIMESTAMP((j#>'{times,estimatedQueueTime}')::bigint / 1000) AS estimated_queue_time
        FROM jsonb_array_elements(NEW.data->'matches') AS a(j)
      ), processed_matches AS (
        SELECT
          SUBSTRING(label FROM '\d+')::smallint AS number,
          (
            CASE
              WHEN label ~ 'Practice' THEN 'p'::frc_match_level
              WHEN label ~ 'Qualification' THEN 'q'::frc_match_level
              WHEN label ~ 'Playoff' THEN 'pf'::frc_match_level
              WHEN label ~ 'Final' THEN 'f'::frc_match_level
            END
          ) AS level,
          (
            CASE
              WHEN label ~ 'Replay' THEN COALESCE(
                SUBSTRING(label FROM '\d+$')::int,
                1
              )
              ELSE 0
            END
          ) AS replay,
          (
            CASE
              WHEN nm.status = 'Queuing soon' THEN 'scheduled'
              WHEN nm.status = 'Now queuing' THEN 'queuing'
              WHEN nm.status = 'On deck' THEN 'queuing'
              WHEN nm.status = 'On field' THEN 'on_field'
            END
          ) AS status,
          nm.scheduled_time,
          COALESCE(nm.actual_queue_time, nm.estimated_queue_time) AS queue_time
      ), filtered_matches AS (
        SELECT *
        FROM processed_matches pm
        WHERE pm.replay = (
          SELECT MAX(pm2.replay)
          FROM processed_matches pm2
          WHERE
            pm2.level = pm.level AND
            pm2.number = pm.number
        )
      )
      MERGE INTO frc_matches fm
        USING filtered_matches pm ON
          fm.event_key = NEW.event_key AND
          fm.level = pm.level AND
          fm.set = 1 AND
          fm.number = pm.number
      WHEN NOT MATCHED BY TARGET
        THEN INSERT
        (
          status,
          level,
          set,
          number,
          event_key,
          replay,
          scheduled_time,
          queue_time
        ) VALUES (
          pm.status,
          pm.level,
          1,
          pm.number,
          NEW.event_key,
          pm.replay,
          pm.scheduled_time,
          pm.queue_time
        )
      WHEN MATCHED
        THEN UPDATE SET
          status = (
            CASE
              WHEN fm.replay != pm.replay THEN pm.status
              WHEN fm.status = 'score_posted' THEN fm.status
              ELSE pm.status
            END
          ),
          replay = pm.replay,
          scheduled_time = pm.scheduled_time,
          queue_time = pm.queue_time
      WHEN NOT MATCHED BY SOURCE
        AND fm.event_key = NEW.event_key
        THEN DO NOTHING; -- TODO: do something maybe?

      RETURN NULL;
    END;
  $$;

CREATE TRIGGER event_data_insert AFTER INSERT ON nexus.event_data
  FOR EACH ROW EXECUTE FUNCTION nexus.event_data_trigger();
CREATE TRIGGER event_data_update AFTER UPDATE OF data ON nexus.event_data
  FOR EACH ROW EXECUTE FUNCTION nexus.event_data_trigger();

CREATE TABLE nexus.pit_maps (
  event_key text PRIMARY KEY,
  data jsonb NOT NULL,
  create_time timestamptz NOT NULL
    DEFAULT now(),
  update_time timestamptz NOT NULL
    DEFAULT now()
);

-- TODO: pit maps in usable format

CREATE TABLE nexus.pit_addresses (
  event_key text PRIMARY KEY,
  data jsonb NOT NULL,
  create_time timestamptz NOT NULL
    DEFAULT now(),
  update_time timestamptz NOT NULL
    DEFAULT now()
);

CREATE FUNCTION nexus.pit_addresses_trigger() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$
    BEGIN
      WITH nexus_pits AS (
        SELECT
          k::smallint AS team_num,
          v::text AS pit_address
        FROM jsonb_each(NEW.data) AS a(k, v)
      )
      MERGE INTO frc_event_teams fet
        USING nexus_pits np ON
          fet.event_key = NEW.event_key AND
          fet.team_num = np.team_num
      WHEN MATCHED
        THEN UPDATE SET
          pit_address = np.pit_address
      WHEN NOT MATCHED BY SOURCE
        AND fet.event_key = NEW.event_key
        THEN UPDATE SET
          pit_address = NULL;

      RETURN NULL;
    END;
  $$;

CREATE TRIGGER pit_addresses_insert AFTER INSERT ON nexus.pit_addresses
  FOR EACH ROW EXECUTE FUNCTION nexus.pit_addresses_trigger();
CREATE TRIGGER pit_addresses_update AFTER UPDATE OF data ON nexus.pit_addresses
  FOR EACH ROW EXECUTE FUNCTION nexus.pit_addresses_trigger();

-- These tables store raw data direct from TBA, hardly touched
-- Data is simply split into smaller blocks (e.g. individual teams instead of pages of 500)
-- TBA API v3: https:--www.thebluealliance.com/apidocs/v3

CREATE SCHEMA tba;

CREATE FUNCTION tba.update_time() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.delete_time IS NULL THEN
        NEW.update_time := now();
      END IF;

      RETURN NEW;
    END;
  $$;

-- verification for webhooks
CREATE TABLE tba.verification (
  create_time timestamptz NOT NULL
    DEFAULT now(),
  key text NOT NULL
);

-- etags to reduce traffic & processing
CREATE TABLE tba.etags (
  create_time timestamptz NOT NULL
    DEFAULT now(),
  update_time timestamptz NOT NULL
    DEFAULT now(),
  delete_time timestamptz,
  path text PRIMARY KEY,
  etag text NOT NULL
);

CREATE TRIGGER etags_update_time BEFORE UPDATE ON tba.etags
  FOR EACH ROW EXECUTE FUNCTION tba.update_time();

-- /status
-- Stores the TBA "API_Status" object
-- Only one row
CREATE TABLE tba.api_status (
  create_time timestamptz NOT NULL
    DEFAULT now(),
  update_time timestamptz NOT NULL
    DEFAULT now(),
  delete_time timestamptz,
  data jsonb NOT NULL
);

CREATE TRIGGER api_status_update_time BEFORE UPDATE ON tba.api_status
  FOR EACH ROW EXECUTE FUNCTION tba.update_time();

-- /events/{year}
-- Stores TBA "Event" objects
CREATE TABLE tba.events (
  create_time timestamptz NOT NULL
    DEFAULT now(),
  update_time timestamptz NOT NULL
    DEFAULT now(),
  delete_time timestamptz,
  event_key text PRIMARY KEY,
  data jsonb NOT NULL
);

CREATE TRIGGER events_update_time BEFORE UPDATE ON tba.events
  FOR EACH ROW EXECUTE FUNCTION tba.update_time();

CREATE FUNCTION tba.events_trigger() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$
    BEGIN
      INSERT INTO frc_events
        (
          season,
          type,
          start_date,
          end_date,
          key,
          name,
          name_short,
          district_key,
          country,
          province,
          city,
          location,
          website
        ) VALUES (
          (NEW.data->'year')::smallint,
          (NEW.data->'event_type')::smallint,
          (NEW.data->'start_date')::date,
          (NEW.data->'end_date')::date,
          NEW.event_key,
          NEW.data->>'name',
          NEW.data->>'name_short',
          NEW.data->>'district_key',
          NEW.data->>'country',
          NEW.data->>'state_prov',
          NEW.data->>'city',
          NEW.data->>'location_name',
          NEW.data->>'website'
        )
        ON CONFLICT (key) DO UPDATE SET
          season = EXCLUDED.season,
          type = EXCLUDED.type,
          start_date = EXCLUDED.start_date,
          end_date = EXCLUDED.end_date,
          name = EXCLUDED.name,
          name_short = EXCLUDED.name_short,
          district_key = EXCLUDED.district_key,
          country = EXCLUDED.country,
          province = EXCLUDED.province,
          city = EXCLUDED.city,
          location = EXCLUDED.location,
          website = EXCLUDED.website;

      --TODO: store remap teams

      RETURN NULL;
    END;
  $$;

CREATE TRIGGER events_insert AFTER INSERT ON tba.events
  FOR EACH ROW EXECUTE FUNCTION tba.events_trigger();
CREATE TRIGGER events_update AFTER UPDATE OF data ON tba.events
  FOR EACH ROW EXECUTE FUNCTION tba.events_trigger();

-- /teams/{page}
-- Stores TBA "Team" objects
CREATE TABLE tba.teams (
  create_time timestamptz NOT NULL
    DEFAULT now(),
  update_time timestamptz NOT NULL
    DEFAULT now(),
  delete_time timestamptz,
  page smallint NOT NULL,
  team_key text PRIMARY KEY,
  data jsonb NOT NULL
);

CREATE INDEX ON tba.teams (page, team_key);

CREATE TRIGGER teams_update_time BEFORE UPDATE ON tba.teams
  FOR EACH ROW EXECUTE FUNCTION tba.update_time();

CREATE FUNCTION tba.teams_trigger() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$
    BEGIN
      INSERT INTO frc_teams
        (
          number,
          rookie_season,
          name,
          country,
          province,
          city,
          website
        ) VALUES (
          (NEW.data->'team_number')::smallint,
          (NEW.data->'rookie_year')::smallint,
          NEW.data->>'nickname',
          NEW.data->>'country',
          NEW.data->>'state_prov',
          NEW.data->>'city',
          NEW.data->>'website'
        )
        ON CONFLICT (number) DO UPDATE SET
          rookie_season = EXCLUDED.rookie_season,
          name = EXCLUDED.name,
          country = EXCLUDED.country,
          province = EXCLUDED.province,
          city = EXCLUDED.city,
          website = EXCLUDED.website;

      RETURN NULL;
    END;
  $$;

CREATE TRIGGER teams_insert AFTER INSERT ON tba.teams
  FOR EACH ROW EXECUTE FUNCTION tba.teams_trigger();
CREATE TRIGGER teams_update AFTER UPDATE OF data ON tba.teams
  FOR EACH ROW EXECUTE FUNCTION tba.teams_trigger();

-- /event/{event_key}/teams/keys
-- Stores TBA team keys
CREATE TABLE tba.event_teams (
  event_key text NOT NULL,
  team_key text NOT NULL,
  create_time timestamptz NOT NULL
    DEFAULT now(),
  update_time timestamptz NOT NULL
    DEFAULT now(),
  delete_time timestamptz,

  PRIMARY KEY (event_key, team_key)
);

CREATE TRIGGER event_teams_update_time BEFORE UPDATE ON tba.event_teams
  FOR EACH ROW EXECUTE FUNCTION tba.update_time();

CREATE FUNCTION tba.event_teams_trigger() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$
    BEGIN
      INSERT INTO frc_event_teams
      (
        team_num,
        event_key
      ) VALUES (
        SUBSTRING(NEW.team_key FROM '\d+')::smallint,
        NEW.event_key
      )
      ON CONFLICT (event_key, team_num) DO NOTHING;

      RETURN NULL;
    END;
  $$;

CREATE TRIGGER event_teams_insert AFTER INSERT ON frc_event_teams
  FOR EACH ROW EXECUTE FUNCTION tba.event_teams_trigger();
-- no trigger for update; nothing to change

-- /event/{event_key}/matches
-- Stores TBA "Match" objects
CREATE TABLE tba.matches (
  match_key text PRIMARY KEY,
  data jsonb NOT NULL,
  create_time timestamptz NOT NULL
    DEFAULT now(),
  update_time timestamptz NOT NULL
    DEFAULT now(),
  delete_time timestamptz
);

CREATE TRIGGER matches_update_time BEFORE UPDATE ON tba.matches
  FOR EACH ROW EXECUTE FUNCTION tba.update_time();

CREATE FUNCTION tba.matches_trigger() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$
    DECLARE
      is_de boolean;
      comp_level CONSTANT text := NEW.data->>'comp_level';
      winning_alliance CONSTANT text := NEW.data->>'winning_alliance';
    BEGIN
      SELECT
        ((e.data->'playoff_type')::smallint = 5) INTO is_de
        FROM tba.events e
        WHERE e.event_key = NEW.data->>'event_key';

      INSERT INTO frc_matches
      (
        level,
        set,
        number,
        event_key,
        scheduled_time,
        start_time,
        red_score,
        blue_score,
        winner
      ) VALUES (
        CASE
          WHEN comp_level = 'sf' AND is_de THEN 'pf'::frc_match_level
          WHEN comp_level = 'sf' THEN 'sf'::frc_match_level
          WHEN comp_level = 'qf' THEN 'qf'::frc_match_level
          WHEN comp_level = 'ef' THEN 'ef'::frc_match_level
          WHEN comp_level = 'f' THEN 'f'::frc_match_level
          WHEN comp_level = 'qm' THEN 'q'::frc_match_level
        END,
        CASE
          WHEN comp_level = 'sf' AND is_de THEN 1
          ELSE (NEW.data->'set')::smallint
        END,
        CASE
          WHEN comp_level = 'sf' AND is_de THEN (NEW.data->'set')::smallint
          ELSE (NEW.data->'match')::smallint
        END,
        NEW.data->>'event_key',
        TO_TIMESTAMP((NEW.data->'time')::bigint),
        TO_TIMESTAMP((NEW.data->'actual_time')::bigint),
        (NEW.data#>'{alliances,red,score}')::smallint,
        (NEW.data#>'{alliances,blue,score}')::smallint,
        CASE
          WHEN winning_alliance = 'red' THEN 'red'::frc_alliance_color
          WHEN winning_alliance = 'blue' THEN 'blue'::frc_alliance_color
          ELSE NULL
        END
      )
      ON CONFLICT (key) DO UPDATE SET
        start_time = EXCLUDED.start_time,
        red_score = EXCLUDED.red_score,
        blue_score = EXCLUDED.blue_score,
        winner = EXCLUDED.winner;

      RETURN NULL;
    END;
  $$;

CREATE TRIGGER matches_insert AFTER INSERT ON tba.matches
  FOR EACH ROW EXECUTE FUNCTION tba.matches_trigger();
CREATE TRIGGER matches_update AFTER UPDATE OF data ON tba.matches
  FOR EACH ROW EXECUTE FUNCTION tba.matches_trigger();

-- /districts/{year}
-- Stores TBA "District" objects
CREATE TABLE tba.districts (
  district_key text PRIMARY KEY,
  data jsonb NOT NULL,
  create_time timestamptz NOT NULL
    DEFAULT now(),
  update_time timestamptz NOT NULL
    DEFAULT now(),
  delete_time timestamptz
);

CREATE TRIGGER districts_update_time BEFORE UPDATE ON tba.districts
  FOR EACH ROW EXECUTE FUNCTION tba.update_time();

CREATE FUNCTION tba.districts_trigger() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$
    BEGIN
      INSERT INTO frc_districts
        (season, key, name) VALUES
        (
          (NEW.data->'year')::smallint,
          NEW.district_key,
          NEW.data->>'name'
        )
      ON CONFLICT (key) DO UPDATE SET
        season = EXCLUDED.season,
        name = EXCLUDED.name;
    END;
  $$;

CREATE TRIGGER districts_insert AFTER INSERT ON tba.districts
  FOR EACH ROW EXECUTE FUNCTION tba.districts_trigger();
CREATE TRIGGER districts_update AFTER UPDATE OF data ON tba.districts
  FOR EACH ROW EXECUTE FUNCTION tba.districts_trigger();

-- /event/{event_key}/rankings
-- Stores TBA "Event_Ranking"->"rankings" objects
CREATE TABLE tba.event_rankings (
  event_key text NOT NULL,
  team_key text NOT NULL,
  data jsonb NOT NULL,
  create_time timestamptz NOT NULL
    DEFAULT now(),
  update_time timestamptz NOT NULL
    DEFAULT now(),
  delete_time timestamptz,

  PRIMARY KEY (event_key, team_key)
);

CREATE TRIGGER event_rankings_update_time BEFORE UPDATE ON tba.event_rankings
  FOR EACH ROW EXECUTE FUNCTION tba.update_time();

CREATE FUNCTION tba.event_rankings_trigger() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$
    BEGIN
      INSERT INTO frc_rankings
        (
          team_num,
          rank,
          wins,
          losses,
          ties,
          event_key,
          subteam
        ) VALUES (
          SUBSTRING(NEW.team_key FROM '\d+')::smallint,
          (NEW->'rank')::smallint,
          (NEW#>'{record,wins}')::smallint,
          (NEW#>'{record,losses}')::smallint,
          (NEW#>'{record,ties}')::smallint,
          NEW.event_key,
          NULLIF(SUBSTRING(NEW.team_key FROM '[A-Z]$'), '')
        )
        ON CONFLICT (event_key, team_num, subteam) DO UPDATE SET
          rank = EXCLUDED.rank,
          wins = EXCLUDED.wins,
          losses = EXCLUDED.losses,
          ties = EXCLUDED.ties;

      RETURN NULL;
    END;
  $$;

CREATE TRIGGER event_rankings_insert AFTER INSERT ON tba.event_rankings
  FOR EACH ROW EXECUTE FUNCTION tba.event_rankings_trigger();
CREATE TRIGGER event_rankings_update AFTER UPDATE OF data ON tba.event_rankings
  FOR EACH ROW EXECUTE FUNCTION tba.event_rankings_trigger();
-- Scouting data submitted by our users

CREATE TYPE scouting_category AS ENUM (
  'match',
  'pit'
);

-- Matches assigned to users for scouting
CREATE TABLE assigned_matches (
  user_id uuid NOT NULL
    REFERENCES profiles ON DELETE CASCADE,
  alliance frc_alliance_color NOT NULL,
  station smallint NOT NULL,
  match_key citext NOT NULL,

  PRIMARY KEY (user_id, match_key),
  FOREIGN KEY (match_key, alliance, station)
    REFERENCES frc_match_teams ON DELETE CASCADE
);

CREATE INDEX ON assigned_matches (match_key, alliance, station);

-- Pits assigned to users for scouting
CREATE TABLE assigned_pits (
  user_id uuid NOT NULL
    REFERENCES profiles ON DELETE CASCADE,
  team_num smallint NOT NULL,
  event_key citext NOT NULL,

  PRIMARY KEY (user_id, event_key, team_num),
  FOREIGN KEY (event_key, team_num)
    REFERENCES frc_event_teams ON DELETE CASCADE
);

CREATE INDEX ON assigned_pits (event_key, team_num);

-- Scouting questions tree
CREATE TABLE questions (
  id uuid PRIMARY KEY
    DEFAULT gen_random_uuid(),
  category scouting_category NOT NULL,
  season smallint NOT NULL,
  index smallint NOT NULL
    DEFAULT 0,
  parent_id uuid
    REFERENCES questions ON DELETE CASCADE,
  label text,

  UNIQUE NULLS DISTINCT (parent_id, index)
);

CREATE INDEX ON questions (season, category);

-- Scouting questions leaf tables
-- These are the actual questions and parameters
-- One per destination data type
-- Types are:
-- - integer (also includes boolean as 0/1)
-- - options

CREATE TABLE questions_integer (
  question_id uuid PRIMARY KEY
    REFERENCES questions ON DELETE CASCADE,
  minimum integer NOT NULL
    DEFAULT 0,              -- implicit minimum
  maximum integer NOT NULL  -- must specify maximum
);

CREATE TABLE questions_options (
  question_id uuid PRIMARY KEY
    REFERENCES questions ON DELETE CASCADE,
  minimum_selections smallint NOT NULL
    DEFAULT 1
    CONSTRAINT minimum_selections_positive CHECK (minimum_selections >= 0),
  maximum_selections smallint
    DEFAULT 1
    CONSTRAINT maximum_selections_positive CHECK (maximum_selections >= 0)
);

CREATE TABLE questions_options_choices (
  question_id uuid NOT NULL
    REFERENCES questions_options ON DELETE CASCADE,
  option_id smallint NOT NULL,
  label text NOT NULL,

  PRIMARY KEY (question_id, option_id)
);

-- Scouting submission metadata
CREATE TABLE submissions (
  id uuid PRIMARY KEY
    DEFAULT gen_random_uuid(),
  category scouting_category NOT NULL,
  season smallint NOT NULL,
  scouted_team smallint NOT NULL,
  created_at timestamptz NOT NULL
    DEFAULT now(),
  scouting_user uuid
    REFERENCES profiles ON DELETE SET NULL
    DEFAULT auth.uid(),
  scouting_team smallint
    REFERENCES teams ON DELETE SET NULL,
  event_key citext
    REFERENCES frc_events ON DELETE SET NULL,
  match_key citext
    REFERENCES frc_matches ON DELETE SET NULL,
  match_replay smallint,

  CHECK ((match_key IS NULL) = (category = 'pit')),
  FOREIGN KEY (event_key, scouted_team)
    REFERENCES frc_event_teams ON DELETE SET NULL (event_key),
  FOREIGN KEY (scouting_team, scouting_user)
    REFERENCES team_users (team_num, user_id) ON DELETE SET NULL (scouting_user)
);

-- Scouting submission data tables

-- Integer data
-- Boolean: 0 = false, 1 = true
CREATE TABLE submissions_data_integer (
  question_id uuid NOT NULL
    REFERENCES questions_integer ON DELETE RESTRICT,
  submission_id uuid NOT NULL
    REFERENCES submissions ON DELETE CASCADE,
  value smallint NOT NULL,

  PRIMARY KEY (question_id, submission_id) INCLUDE (value)
);

CREATE INDEX ON submissions_data_integer (submission_id, question_id);

CREATE FUNCTION submissions_data_integer_validate() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$
    DECLARE
      submission submissions%ROWTYPE;
      question questions%ROWTYPE;
      parameters questions_integer%ROWTYPE;
    BEGIN
      -- fetch metadata
      SELECT * INTO submission
        FROM submissions s
        WHERE s.id = NEW.submission_id;

      SELECT * INTO question
        FROM questions q
        WHERE q.id = NEW.question_id;

      SELECT * INTO parameters
        FROM questions_integer qi
        WHERE q.id = NEW.question_id;

      -- ensure season & category match
      IF submission.season != question.season OR submission.category != question.category THEN
        RAISE EXCEPTION 'Submission % cannot contain question %', submission.id, question.id;
      END IF;

      -- validate data
      IF NEW.value < parameters.minimum OR NEW.value > parameters.maximum THEN
        RAISE EXCEPTION 'Value % out of range (%, %) for question % on submission %',
          NEW.value, parameters.minimum, parameters.maximum, question.id, submission.id;
      END IF;

      RETURN NULL; -- after trigger; value doesn't matter
    END;
  $$;

CREATE TRIGGER submissions_data_integer_valid AFTER INSERT ON submissions_data_integer
  FOR EACH ROW EXECUTE FUNCTION submissions_data_integer_validate();

-- Options data
CREATE TABLE submissions_data_options (
  question_id uuid NOT NULL,
  submission_id uuid NOT NULL
    REFERENCES submissions ON DELETE CASCADE,
  option_id integer NOT NULL,

  PRIMARY KEY (question_id, option_id, submission_id),
  FOREIGN KEY (question_id, option_id)
    REFERENCES questions_options_choices ON DELETE RESTRICT
);

CREATE INDEX ON submissions_data_options (submission_id, question_id, option_id);

CREATE FUNCTION submissions_data_options_validate() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$
    DECLARE
      i RECORD;
    BEGIN
      -- check option count
      FOR i IN (
        WITH checks AS (
          SELECT DISTINCT
            n.submission_id,
            n.question_id
          FROM newtable n
        ), counts AS (
          SELECT
            c.submission_id,
            c.question_id,
            COUNT(*) AS count
          FROM checks c
            JOIN submissions_data_options sdo ON
              sdo.submission_id = c.submission_id AND
              sdo.question_id = c.question_id
          GROUP BY
            c.submission_id,
            c.question_id
        )
        SELECT
          c.submission_id,
          c.question_id,
          c.count,
          qo.minimum_count,
          qo.maximum_count
        FROM counts c
          JOIN questions_options qo ON qo.question_id = c.question_id
        WHERE
          c.count < qo.minimum_count OR
          c.count > qo.maximum_count
      ) LOOP
        RAISE EXCEPTION 'Response count % out of range (%, %) for question % on submission %',
          i.count, i.minimum_count, i.maximum_count, i.question_id, i.submission_id;
      END LOOP;

      RETURN NULL; -- after trigger; value doesn't matter
    END;
  $$;

-- need transition table, so must be an after trigger
CREATE TRIGGER submissions_data_options_valid AFTER INSERT ON submissions_data_options
  REFERENCING NEW TABLE AS newtable
  FOR EACH STATEMENT EXECUTE FUNCTION submissions_data_integer_validate();

-- Match integer/boolean data
-- - match key
-- - team num
-- - question id
-- - median of entries (= mode for booleans)
CREATE VIEW data_match_integer AS
  SELECT
    s.match_key,
    s.scouted_team AS team_num,
    sd.question_id,
    PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY sd.value) AS match_median,
    COUNT(*) AS submission_count
  FROM
    submissions s
    JOIN submissions_data_integer sd ON
      sd.submission_id = s.id
  WHERE
    s.category = 'match'
  GROUP BY
    s.match_key,
    s.scouted_team,
    sd.question_id;

CREATE VIEW data_match_options AS
  WITH counts AS (
    SELECT
      s.match_key,
      s.scouted_team,
      COUNT(*) AS submission_count
    FROM submissions s
    WHERE
      s.category = 'match'
    GROUP BY
      s.match_key,
      s.scouted_team
  )
  SELECT
    s.match_key,
    s.scouted_team AS team_num,
    sd.question_id,
    sd.option_id,
    c.submission_count,
    COUNT(*) AS option_count
  FROM
    submissions s
    JOIN submissions_data_options sd ON
      sd.submission_id = s.id
    JOIN counts c ON
      c.match_key = s.match_key AND
      c.scouted_team = s.scouted_team
  WHERE
    s.category = 'match'
  GROUP BY
    s.match_key,
    s.scouted_team,
    sd.question_id,
    sd.option_id,
    c.submission_count;
CREATE FUNCTION auth_delete_user()
RETURNS VOID
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
  DELETE FROM auth.users
    WHERE id = (SELECT auth.uid());
END;
$$;

CREATE FUNCTION frc_teams_search(query text)
RETURNS SETOF smallint
LANGUAGE sql
STABLE
AS $$
  SELECT frc_teams.number
    FROM frc_teams
      LEFT JOIN teams ON frc_teams.number = teams.number
    ORDER BY greatest(
      similarity(frc_teams.number::text, query),
      similarity(frc_teams.name, query),
      similarity(teams.name, query)
    ) DESC, frc_teams.number ASC;
$$;

CREATE FUNCTION frc_events_search(year smallint, query text)
RETURNS SETOF citext
LANGUAGE sql
STABLE
AS $$
  SELECT e.key
    FROM frc_events e
    WHERE e.season = year
    ORDER BY greatest(
      similarity(e.key::text, query),
      similarity(e.name::text, query)
    ) DESC, e.key ASC;
$$;

-- sync all current events
CREATE PROCEDURE nexus.merge_events(events jsonb)
  LANGUAGE plpgsql AS $$
  BEGIN
    WITH data AS (
      SELECT tmp.key AS event_key, tmp.value AS event
      FROM jsonb_each(events) AS tmp (key, value)
    )
    MERGE INTO nexus.events n
      USING data d ON
        d.event_key = n.event_key
    WHEN NOT MATCHED BY TARGET
      THEN INSERT
      (event_key, data) VALUES
      (d.event_key, d.event)
    WHEN MATCHED
      THEN UPDATE SET
        t.data = d.event,
        t.update_time = now(),
        t.delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      THEN UPDATE SET
        t.delete_time = now();
  END;
$$;

-- sync all the events in a given year
CREATE PROCEDURE tba.merge_events(year smallint, events jsonb)
  LANGUAGE plpgsql AS $$
  BEGIN
    WITH data AS (
      SELECT jsonb_array_elements(events) AS event
    )
    MERGE INTO tba.events t
      USING data d ON
        d.event->>'key' = t.event_key
    WHEN NOT MATCHED BY TARGET
      THEN INSERT
      (event_key, data) VALUES
      (d.event->>'key', d.event)
    WHEN MATCHED
      THEN UPDATE SET
        t.data = d.event,
        t.update_time = now(),
        t.delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      AND t.event_key LIKE (year::text || '%')
      THEN UPDATE SET
        t.delete_time = now();
  END;
$$;

-- sync all the teams on a given page
CREATE PROCEDURE tba.merge_teams(page smallint, teams jsonb)
  LANGUAGE plpgsql AS $$
  BEGIN
    WITH data AS (
      SELECT jsonb_array_elements(teams) AS team
    )
    MERGE INTO tba.teams t
      USING data d ON
        d.team->>'key' = t.team_key
    WHEN NOT MATCHED BY TARGET
      THEN INSERT
      (team_key, page, data) VALUES
      (d.team->>'key', page, d.team)
    WHEN MATCHED
      THEN UPDATE SET
        t.page = page,
        t.data = d.team,
        t.update_time = now(),
        t.delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      AND t.page = page
      THEN UPDATE SET
        t.delete_time = now();
  END;
$$;

-- sync all the teams in a given event
CREATE PROCEDURE tba.merge_event_teams(event_key text, team_keys jsonb)
  LANGUAGE plpgsql AS $$
  BEGIN
    WITH data AS (
      SELECT jsonb_array_elements_text(team_keys) AS team_key
    )
    MERGE INTO tba.event_teams t
      USING data d ON
        t.event_key = event_key AND
        t.team_key = d.team_key
    WHEN NOT MATCHED BY TARGET
      THEN INSERT
      (event_key, team_key) VALUES
      (event_key, d.team_key)
    WHEN MATCHED
      THEN UPDATE SET
        update_time = now(),
        delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      AND t.event_key = event_key
      THEN UPDATE SET
        delete_time = now();
  END;
$$;

-- sync all the matches in a given event
CREATE PROCEDURE tba.merge_matches(event_key text, matches jsonb)
  LANGUAGE plpgsql AS $$
  BEGIN
    WITH data AS (
      SELECT jsonb_array_elements(matches) AS match
    )
    MERGE INTO tba.matches t
      USING data d ON
        t.match_key = d.match->>'key'
    WHEN NOT MATCHED BY TARGET
      THEN INSERT
      (match_key, data) VALUES
      (d.match->>'key', d.match)
    WHEN MATCHED
      THEN UPDATE SET
        data = d.match,
        update_time = now(),
        delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      AND t.match_key LIKE (event_key || '_%')
      THEN UPDATE SET
        delete_time = now();
  END;
$$;

-- sync all the districts in a given year
CREATE PROCEDURE tba.merge_districts(year smallint, districts jsonb)
  LANGUAGE plpgsql AS $$
  BEGIN
    WITH data AS (
      SELECT jsonb_array_elements(districts) AS district
    )
    MERGE INTO tba.districts t
      USING data d ON
        t.district_key = d.district->>'key'
    WHEN NOT MATCHED BY TARGET
      THEN INSERT
      (district_key, data) VALUES
      (d.district->>'key', d.district)
    WHEN MATCHED
    THEN UPDATE SET
        data = d.district,
        update_time = now(),
        delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      AND t.district_key LIKE (year::text || '%')
      THEN UPDATE SET
        delete_time = now();
  END;
$$;

-- sync all rankings for a given event
CREATE PROCEDURE tba.merge_event_rankings(event_key text, rankings jsonb)
  LANGUAGE plpgsql AS $$
  BEGIN
    WITH data AS (
      SELECT jsonb_array_elements(rankings) AS rank
    )
    MERGE INTO tba.event_rankings t
      USING data d ON
        t.event_key = event_key AND
        t.team_key = d.rank->>'team_key'
    WHEN NOT MATCHED BY TARGET
      THEN INSERT
      (event_key, team_key, data) VALUES
      (event_key, d.rank->>'team_key', d.rank)
    WHEN MATCHED
      THEN UPDATE SET
        data = d.rank,
        update_time = now(),
        delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      AND t.event_key = event_key
      THEN UPDATE SET
        delete_time = now();
  END;
$$;
-- basic utilities for the rest of the security definitions

CREATE FUNCTION has_permission(p_type text) RETURNS boolean STRICT
  STABLE SECURITY DEFINER LANGUAGE sql
  RETURN EXISTS (
    SELECT 1 FROM permissions p
    WHERE
      p.user_id = (SELECT auth.uid()) AND
      p.type LIKE p_type
  );

CREATE FUNCTION get_team_num() RETURNS smallint
  STABLE SECURITY DEFINER LANGUAGE sql
  RETURN (
    SELECT team_num
      FROM team_users
      WHERE user_id = (SELECT auth.uid())
  );

CREATE FUNCTION is_user_on_same_team(id_user uuid) RETURNS boolean STRICT
  STABLE SECURITY DEFINER LANGUAGE sql
  RETURN (SELECT get_team_num()) = (
    SELECT team_num
      FROM team_users
      WHERE team_users.user_id = id_user
  );

-- Restrict everything by default
-- Only grant specific permissions

-- functions in public are meant to be executed by users
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public
  FROM public, anon;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA nexus
  FROM public, anon, authenticated;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA tba
  FROM public, anon, authenticated;

REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public
  FROM public, anon, authenticated;

REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA nexus
  FROM public, anon, authenticated;

REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA tba
  FROM public, anon, authenticated;

DO $$
  DECLARE
    row RECORD;
  BEGIN
    FOR row IN (
      SELECT tablename
        FROM pg_tables AS t
        WHERE t.schemaname = 'public'
    )
    LOOP
      EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY;', row.tablename);
    END LOOP;
  END;
$$;

-- profiles -------------------------------
GRANT SELECT ON TABLE profiles TO authenticated;

CREATE POLICY "Anyone can SELECT themself or their team's members"
  ON profiles FOR SELECT TO authenticated
  USING (
    profiles.user_id = (SELECT auth.uid())
    OR
    is_user_on_same_team(profiles.user_id)
  );

CREATE POLICY "'team.%' can SELECT users requesting their team"
  ON profiles FOR SELECT TO authenticated
  USING (
    (SELECT has_permission('team.%'))
    AND
    profiles.user_id IN (
      SELECT user_id
        FROM team_requests
        WHERE team_num = (SELECT get_team_num())
    )
  );

GRANT ALL ON TABLE profiles TO supabase_auth_admin;

CREATE POLICY "Supabase Auth can read/write profiles"
ON profiles FOR ALL TO supabase_auth_admin
USING (true);

-- teams -------------------------------
GRANT SELECT, INSERT(number, name), UPDATE(name) ON TABLE teams TO authenticated;

CREATE POLICY "Anyone can SELECT any team"
  ON teams FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "Users not on a team can INSERT a new team"
  ON teams FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT get_team_num() IS NULL)
  );

CREATE POLICY "'team.admin' can UPDATE their team name"
  ON teams FOR UPDATE TO authenticated
  USING (
    (SELECT has_permission('team.admin'))
    AND
    number = (SELECT get_team_num())
  );

CREATE POLICY "'team.admin' can DELETE their team"
  ON teams FOR DELETE TO authenticated
  USING (
    (SELECT has_permission('team.admin'))
    AND
    number = (SELECT get_team_num())
  );

-- team_users --------------------------
GRANT SELECT, DELETE, INSERT (user_id, team_num) ON TABLE team_users TO authenticated;

CREATE POLICY "Team members can SELECT each other"
ON team_users FOR SELECT TO authenticated
USING (
  team_num = (SELECT get_team_num())
);

CREATE POLICY "Anyone can DELETE themself from their team"
ON team_users FOR DELETE TO authenticated
USING (
  user_id = (SELECT auth.uid())
);

CREATE POLICY "'team.*' can DELETE users from their team"
ON team_users FOR DELETE TO authenticated
USING (
  (SELECT has_permission('team.manage') OR has_permission('team.admin'))
  AND
  team_num = (SELECT get_team_num())
);

CREATE POLICY "'team.*' can INSERT users by request"
ON team_users FOR INSERT TO authenticated
WITH CHECK (
  (SELECT has_permission('team.manage') OR has_permission('team.admin'))
  AND
  (SELECT get_team_num()) = (
    SELECT team_requests.team_num
      FROM team_requests
      WHERE team_requests.user_id = team_users.user_id
  )
);

-- team_requests -----------------------
GRANT SELECT, DELETE, INSERT(team_num) ON TABLE team_requests TO authenticated;

CREATE POLICY "Anyone can SELECT, INSERT, or DELETE their request"
ON team_requests TO authenticated
USING (
  user_id = (SELECT auth.uid())
)
WITH CHECK(
  -- Not on a team already
  (SELECT get_team_num() IS NULL)
);

CREATE POLICY "'team.*' can SELECT requests"
ON team_requests FOR SELECT TO authenticated
USING (
  (SELECT has_permission('team.manage') OR has_permission('team.admin'))
  AND
  team_num = (SELECT get_team_num())
);

CREATE POLICY "'team.*' can DELETE requests"
ON team_requests FOR DELETE TO authenticated
USING (
  (SELECT has_permission('team.manage') OR has_permission('team.admin'))
  AND
  team_num = (SELECT get_team_num())
);

-- permission_types
GRANT SELECT ON TABLE permission_types TO authenticated;

CREATE POLICY "Anyone can SELECT permission types"
ON permission_types TO authenticated
USING (true);

-- permissions -------------------------
GRANT SELECT, DELETE, INSERT(user_id, type) ON TABLE permissions TO authenticated;

CREATE POLICY "Anyone can SELECT their own permissions"
ON permissions FOR SELECT TO authenticated
USING (
  user_id = (SELECT auth.uid())
);

CREATE POLICY "'team.*' can SELECT, INSERT, or DELETE permissions"
ON permissions TO authenticated
USING (
  (SELECT has_permission('team.manage') OR has_permission('team.admin'))
  AND
  team_num = (SELECT get_team_num())
);

-- Allow anyone to select anything from frc_*
DO $$
DECLARE
  row RECORD;
BEGIN
  FOR row IN (
    SELECT tablename
    FROM pg_tables AS t
    WHERE t.schemaname = 'public'
    AND t.tablename LIKE 'frc_%'
  )
  LOOP
    EXECUTE format(
      '
      GRANT SELECT ON TABLE %1$I TO authenticated;

      CREATE POLICY "Anyone can SELECT anything"
        ON %1$I FOR SELECT TO authenticated
        USING (true);
      ',
      row.tablename
    );
  END LOOP;
END;
$$;

-- assigned_matches
GRANT SELECT, INSERT, DELETE ON TABLE assigned_matches TO authenticated;

CREATE POLICY "Users can SELECT their assigned matches"
ON assigned_matches FOR SELECT TO authenticated
USING (
  user_id = (SELECT auth.uid())
);

CREATE POLICY "'team.%' can SELECT, INSERT or DELETE assigned matches"
ON assigned_matches FOR ALL TO authenticated
USING (
  (SELECT has_permission('team.%'))
  AND
  is_user_on_same_team(user_id)
)
WITH CHECK (
  (SELECT has_permission('team.%'))
  AND
  is_user_on_same_team(user_id)
);

-- assigned_pits
GRANT SELECT, INSERT, DELETE ON TABLE assigned_pits TO authenticated;

CREATE POLICY "Users can SELECT their assigned pits"
ON assigned_pits FOR SELECT TO authenticated
USING (
  user_id = (SELECT auth.uid())
);

CREATE POLICY "'team.%' can SELECT, INSERT or DELETE assigned pits"
ON assigned_pits FOR ALL TO authenticated
USING (
  (SELECT has_permission('team.%'))
  AND
  is_user_on_same_team(user_id)
)
WITH CHECK (
  (SELECT has_permission('team.%'))
  AND
  is_user_on_same_team(user_id)
);

-- questions
GRANT SELECT ON TABLE questions TO authenticated;

CREATE POLICY "Anyone can SELECT anything"
ON questions FOR SELECT TO authenticated
USING (true);

-- questions_integer
GRANT SELECT ON TABLE questions_integer TO authenticated;

CREATE POLICY "Anyone can SELECT anything"
ON questions_integer FOR SELECT TO authenticated
USING (true);

-- questions_options
GRANT SELECT ON TABLE questions_options TO authenticated;

CREATE POLICY "Anyone can SELECT anything"
ON questions_options FOR SELECT TO authenticated
USING (true);

-- questions_options_choices
GRANT SELECT ON TABLE questions_options_choices TO authenticated;

CREATE POLICY "Anyone can SELECT anything"
ON questions_options_choices FOR SELECT TO authenticated
USING (true);

-- submissions
GRANT SELECT, INSERT (category, event_key, match_key, season, scouted_team) ON TABLE submissions TO authenticated;

CREATE POLICY "Anyone can SELECT anything"
ON submissions FOR SELECT TO authenticated
USING (true);

CREATE POLICY "'scout.{category}' can INSERT {category} entries"
ON submissions FOR INSERT TO authenticated
WITH CHECK (
  has_permission(('scout.' || category))
);

-- submissions_data_integer
GRANT SELECT, INSERT ON TABLE submissions_data_integer TO authenticated;

CREATE POLICY "Anyone can SELECT anything"
ON submissions_data_integer FOR SELECT TO authenticated
USING (true);

CREATE POLICY "Anyone can INSERT data for their submission"
ON submissions_data_integer FOR INSERT TO authenticated
WITH CHECK (
  (
    SELECT
      (scouting_user = (SELECT auth.uid())) AND has_permission(('scout.' || category))
      FROM submissions
      WHERE submissions.id = submission_id
  )
);

-- submissions_data_options
GRANT SELECT, INSERT ON TABLE submissions_data_options TO authenticated;

CREATE POLICY "Anyone can SELECT anything"
ON submissions_data_options FOR SELECT TO authenticated
USING (true);

CREATE POLICY "Anyone can INSERT data for their submission"
ON submissions_data_options FOR INSERT TO authenticated
WITH CHECK (
  (
    SELECT
      (scouting_user = (SELECT auth.uid())) AND has_permission(('scout.' || category))
      FROM submissions
      WHERE submissions.id = submission_id
  )
);
