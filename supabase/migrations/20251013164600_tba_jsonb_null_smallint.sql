set check_function_bodies = off;

CREATE OR REPLACE FUNCTION tba.districts_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
  $function$
;

CREATE OR REPLACE FUNCTION tba.event_rankings_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
  $function$
;

CREATE OR REPLACE FUNCTION tba.events_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
  $function$
;

CREATE OR REPLACE FUNCTION tba.matches_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
    DECLARE
      is_de boolean;
      comp_level CONSTANT text := NEW.data->>'comp_level';
      winning_alliance CONSTANT text := NEW.data->>'winning_alliance';
    BEGIN
      SELECT
        ((e.data->>'playoff_type')::smallint = 5) INTO is_de
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
          ELSE (NEW.data->>'set')::smallint
        END,
        CASE
          WHEN comp_level = 'sf' AND is_de THEN (NEW.data->'set')::smallint
          ELSE (NEW.data->>'match')::smallint
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
  $function$
;

CREATE OR REPLACE FUNCTION tba.teams_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
  $function$
;


