set check_function_bodies = off;

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
          (NEW.data->'year')::smallint,
          (NEW.data->'event_type')::smallint,
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
          (NEW.data->'team_number')::smallint,
          (NEW.data->'rookie_year')::smallint,
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


