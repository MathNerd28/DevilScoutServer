set check_function_bodies = off;

CREATE OR REPLACE FUNCTION tba.districts_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
    BEGIN
      INSERT INTO frc_districts
        (season, key, name) VALUES
        (
          (NEW.data->'year')::smallint,
          NEW.district_key,
          NEW.data->>'display_name'
        )
      ON CONFLICT (key) DO UPDATE SET
        season = EXCLUDED.season,
        name = EXCLUDED.name;
    END;
  $function$
;


