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
-- Only one row; ID is always 1
CREATE TABLE tba.api_status (
  create_time timestamptz NOT NULL
    DEFAULT now(),
  update_time timestamptz NOT NULL
    DEFAULT now(),
  id smallint PRIMARY KEY
    DEFAULT 1,
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

CREATE FUNCTION jsonb_flatten(data jsonb, prefix text DEFAULT NULL)
RETURNS TABLE(path text, value jsonb)
LANGUAGE plpgsql AS $$
  BEGIN
    FOR path, value IN (
      SELECT
        COALESCE(prefix, '') || '/' || e.key AS path,
        e.val AS value
      FROM jsonb_each(data) AS e(key, val)
    )
    LOOP
      CASE jsonb_typeof(value)
        -- recurse into nested objects
        WHEN 'object' THEN RETURN QUERY
          SELECT * FROM jsonb_flatten(value, path);

        -- recurse into nested array elements, indexing from 1
        WHEN 'array' THEN RETURN QUERY
          SELECT * FROM jsonb_flatten_array(value, path);

        -- otherwise, primitive leaf node
        ELSE RETURN NEXT;
      END CASE;
    END LOOP;
  END;
$$;

CREATE FUNCTION jsonb_flatten_array(data jsonb, prefix text DEFAULT NULL)
RETURNS TABLE(path text, value jsonb)
LANGUAGE plpgsql AS $$
  BEGIN
    FOR path, value IN (
      SELECT
        COALESCE(prefix, '') || '/' || e.index AS path,
        e.val AS value
      FROM jsonb_array_elements(data) WITH ORDINALITY AS e(val, index)
    )
    LOOP
      -- copy the same case block as above
      CASE jsonb_typeof(value)
        WHEN 'object' THEN RETURN QUERY
          SELECT * FROM jsonb_flatten(value, path);

        WHEN 'array' THEN RETURN QUERY
          SELECT * FROM jsonb_flatten_array(value, path);

        ELSE RETURN NEXT;
      END CASE;
    END LOOP;
  END;
$$;

CREATE FUNCTION tba.matches_trigger() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$
    DECLARE
      is_de boolean;
      match_key_data text;
      comp_level CONSTANT text := NEW.data->>'comp_level';
    BEGIN
      SELECT
        -- https://github.com/the-blue-alliance/the-blue-alliance/blob/py3/pwa/app/lib/api/PlayoffType.ts
        ((e.data->>'playoff_type')::smallint = 10) INTO is_de
        FROM tba.events e
        WHERE e.event_key = NEW.data->>'event_key';

      WITH processed_match AS (
        SELECT
          (
            CASE
              WHEN NEW.data#>>'{alliances,red,score}' IS NOT NULL THEN 'score_posted'::frc_match_status
              ELSE 'scheduled'::frc_match_status
            END
          ) AS tba_status,
          (
            CASE comp_level
              WHEN 'sf' THEN
                CASE is_de
                  WHEN TRUE THEN 'playoff'::frc_match_level
                  ELSE 'semifinal'::frc_match_level
                END
              WHEN 'qf' THEN 'quarterfinal'::frc_match_level
              WHEN 'ef' THEN 'octofinal'::frc_match_level
              WHEN 'f' THEN 'final'::frc_match_level
              WHEN 'qm' THEN 'qualification'::frc_match_level
            END
          ) AS level,
          (
            CASE
              WHEN comp_level = 'sf' AND is_de THEN 1
              ELSE (NEW.data->>'set_number')::smallint
            END
          ) AS set,
          (
            CASE
              WHEN comp_level = 'sf' AND is_de THEN (NEW.data->'set_number')::smallint
              ELSE (NEW.data->>'match_number')::smallint
            END
          ) AS number,
          NEW.data->>'event_key' AS event_key,
          TO_TIMESTAMP((NEW.data->>'time')::bigint) AS scheduled_time,
          TO_TIMESTAMP((NEW.data->>'predicted_time')::bigint) AS predicted_time,
          TO_TIMESTAMP((NEW.data->>'actual_time')::bigint) AS actual_time,
          (NEW.data#>>'{alliances,red,score}')::smallint AS red_score,
          (NEW.data#>>'{alliances,blue,score}')::smallint AS blue_score,
          (
            CASE NEW.data->>'winning_alliance'
              WHEN 'blue' THEN 'blue'::frc_alliance_color
              WHEN 'red' THEN 'red'::frc_alliance_color
              ELSE NULL -- can be empty string
            END
          ) AS winner
      )
      MERGE INTO frc_matches fm
        USING processed_match pm ON
          fm.event_key = pm.event_key AND
          fm.level = pm.level AND
          fm.set = pm.set AND
          fm.number = pm.number
      WHEN NOT MATCHED BY TARGET
        THEN INSERT (
          tba_status,
          level,
          set,
          number,
          event_key,
          tba_scheduled_time,
          tba_estimated_time,
          tba_actual_time,
          red_score,
          blue_score,
          winner
        ) VALUES (
          pm.tba_status,
          pm.level,
          pm.set,
          pm.number,
          pm.event_key,
          pm.scheduled_time,
          pm.predicted_time,
          pm.actual_time,
          pm.red_score,
          pm.blue_score,
          pm.winner
        )
      WHEN MATCHED THEN UPDATE SET
        tba_status = pm.tba_status,
        tba_scheduled_time = pm.scheduled_time,
        tba_estimated_time = pm.estimated_time,
        tba_actual_time = pm.actual_time,
        red_score = pm.red_score,
        blue_score = pm.blue_score,
        winner = pm.winner
      WHEN NOT MATCHED BY SOURCE
        THEN DO NOTHING -- only processing one match
      RETURNING pm.key INTO match_key_data;

      WITH match_teams AS (
        SELECT
          'red'::frc_alliance_color AS alliance,
          SUBSTRING(u.team_key FROM '\d+')::smallint AS team_num,
          u.station,
          (NEW.data#>'{alliances,red,dq_team_keys}') ? u.team_key AS is_disqualified,
          (NEW.data#>'{alliances,red,surrogate_team_keys}') ? u.team_key AS is_surrogate
        FROM
          jsonb_array_elements_text(NEW.data#>'{alliances,red,team_keys}') WITH ORDINALITY AS u(team_key, station)
        WHERE u.team_key IS NOT NULL
        UNION
        SELECT
          'blue'::frc_alliance_color AS alliance,
          SUBSTRING(u.team_key FROM '\d+')::smallint AS team_num,
          u.station,
          (NEW.data#>'{alliances,blue,dq_team_keys}') ? u.team_key AS is_disqualified,
          (NEW.data#>'{alliances,blue,surrogate_team_keys}') ? u.team_key AS is_surrogate
        FROM
          jsonb_array_elements_text(NEW.data#>'{alliances,blue,team_keys}') WITH ORDINALITY AS u(team_key, station)
        WHERE u.team_key IS NOT NULL
      )
      MERGE INTO frc_match_teams ft
        USING match_teams mt ON
          ft.match_key = match_key_data AND
          ft.alliance = mt.alliance AND
          ft.station = mt.station
      WHEN NOT MATCHED BY TARGET
        THEN INSERT (
          match_key,
          team_num,
          station,
          alliance,
          is_surrogate,
          is_disqualified
        ) VALUES (
          match_key_data,
          mt.team_num,
          mt.station,
          mt.alliance,
          mt.is_surrogate,
          mt.is_disqualified
        )
      WHEN MATCHED
        THEN UPDATE SET
          team_num = mt.team_num,
          is_surrogate = mt.is_surrogate,
          is_disqualified = mt.is_disqualified
      WHEN NOT MATCHED BY SOURCE
        AND ft.match_key = match_key_data
        THEN DO NOTHING;

      WITH score_breakdown AS (
        SELECT
          'red'::frc_alliance_color AS alliance,
          b.path,
          b.value
        FROM jsonb_flatten(NEW.data#>'{score_breakdown,red}') AS b(path, value)
        UNION
        SELECT
          'blue'::frc_alliance_color AS alliance,
          b.path,
          b.value
        FROM jsonb_flatten(NEW.data#>'{score_breakdown,blue}') AS b(path, value)
      )
      MERGE INTO frc_match_breakdowns fb
        USING score_breakdown sb ON
          fb.match_key = match_key_data AND
          fb.alliance = sb.alliance AND
          fb.path = sb.path
      WHEN NOT MATCHED BY TARGET
        THEN INSERT (
          match_key,
          alliance,
          path,
          data
        ) VALUES (
          match_key_data,
          sb.alliance,
          sb.path,
          sb.value
        )
      WHEN MATCHED
        THEN UPDATE SET
          data = sb.value
      WHEN NOT MATCHED BY SOURCE
        AND fb.match_key = match_key_data
        THEN DELETE;

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
