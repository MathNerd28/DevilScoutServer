-- These tables store raw data direct from TBA, hardly touched
-- Data is simply split into smaller blocks (e.g. individual teams instead of pages of 500)
-- TBA API v3: https:--www.thebluealliance.com/apidocs/v3

CREATE SCHEMA tba;

GRANT USAGE ON SCHEMA tba TO service_role;
GRANT ALL ON ALL TABLES IN SCHEMA tba TO service_role;
GRANT ALL ON ALL ROUTINES IN SCHEMA tba TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA tba TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA tba GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA tba GRANT ALL ON ROUTINES TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA tba GRANT ALL ON SEQUENCES TO service_role;

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
          (NEW.data->>'year')::smallint,
          (NEW.data->>'event_type')::smallint,
          (NEW.data->>'start_date')::date,
          (NEW.data->>'end_date')::date,
          NEW.event_key,
          NEW.data->>'name',
          NULLIF(NEW.data->>'name_short', ''),
          NEW.data#>>'{district,key}',
          NULLIF(NEW.data->>'country', ''),
          NULLIF(NEW.data->>'state_prov', ''),
          NULLIF(NEW.data->>'city', ''),
          NULLIF(NEW.data->>'location_name',''),
          NULLIF(NEW.data->>'website', '')
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
          (NEW.data->>'team_number')::smallint,
          (NEW.data->>'rookie_year')::smallint,
          NEW.data->>'nickname',
          NULLIF(NEW.data->>'country', ''),
          NULLIF(NEW.data->>'state_prov', ''),
          NULLIF(NEW.data->>'city', ''),
          NULLIF(NEW.data->>'website', '')
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

CREATE TRIGGER event_teams_insert AFTER INSERT ON tba.event_teams
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
        -- https://github.com/the-blue-alliance/the-blue-alliance/blob/py3/pwa/app/lib/api/PlayoffType.ts
        ((e.data->>'playoff_type')::smallint = 10) INTO is_de
        FROM tba.events e
        WHERE e.event_key = NEW.data->>'event_key';

      INSERT INTO frc_matches
      (
        status,
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
          WHEN NEW.data#>>'{alliances,red,score}' IS NOT NULL THEN 'score_posted'::frc_match_status
          ELSE 'scheduled'::frc_match_status
        END,
        CASE
          WHEN comp_level = 'sf' AND is_de THEN 'playoff'::frc_match_level
          WHEN comp_level = 'sf' THEN 'semifinal'::frc_match_level
          WHEN comp_level = 'qf' THEN 'quarterfinal'::frc_match_level
          WHEN comp_level = 'ef' THEN 'eighthfinal'::frc_match_level
          WHEN comp_level = 'f' THEN 'final'::frc_match_level
          WHEN comp_level = 'qm' THEN 'qualification'::frc_match_level
        END,
        CASE
          WHEN comp_level = 'sf' AND is_de THEN 1
          ELSE (NEW.data->>'set_number')::smallint
        END,
        CASE
          WHEN comp_level = 'sf' AND is_de THEN (NEW.data->'set_number')::smallint
          ELSE (NEW.data->>'match_number')::smallint
        END,
        NEW.data->>'event_key',
        TO_TIMESTAMP((NEW.data->'time')::bigint),
        TO_TIMESTAMP((NEW.data->'actual_time')::bigint),
        (NEW.data#>>'{alliances,red,score}')::smallint,
        (NEW.data#>>'{alliances,blue,score}')::smallint,
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
          (NEW.data->>'year')::smallint,
          NEW.district_key,
          NEW.data->>'display_name'
        )
      ON CONFLICT (key) DO UPDATE SET
        season = EXCLUDED.season,
        name = EXCLUDED.name;

      RETURN NULL;
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
          (NEW->>'rank')::smallint,
          (NEW#>>'{record,wins}')::smallint,
          (NEW#>>'{record,losses}')::smallint,
          (NEW#>>'{record,ties}')::smallint,
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
