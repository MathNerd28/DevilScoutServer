set check_function_bodies = off;

CREATE OR REPLACE FUNCTION tba.merge_event_teams(event_key text, team_keys jsonb)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
  DECLARE
    event_key_param ALIAS FOR event_key;
  BEGIN
    WITH data AS (
      SELECT jsonb_array_elements_text(team_keys) AS team_key
    )
    MERGE INTO tba.event_teams t
      USING data d ON
        t.event_key = event_key_param AND
        t.team_key = d.team_key
    WHEN NOT MATCHED BY TARGET
      THEN INSERT
      (event_key, team_key) VALUES
      (event_key_param, d.team_key)
    WHEN MATCHED
      THEN UPDATE SET
        update_time = now(),
        delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      AND t.event_key = event_key_param
      THEN UPDATE SET
        delete_time = now();
  END;
$function$
;


