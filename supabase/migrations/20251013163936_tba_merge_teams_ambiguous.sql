set check_function_bodies = off;

CREATE OR REPLACE FUNCTION tba.merge_teams(page smallint, teams jsonb)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
  DECLARE
    page_param ALIAS FOR page;
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
      (d.team->>'key', page_param, d.team)
    WHEN MATCHED
      THEN UPDATE SET
        page = page_param,
        data = d.team,
        update_time = now(),
        delete_time = NULL
    WHEN NOT MATCHED BY SOURCE
      AND t.page = page_param
      THEN UPDATE SET
        delete_time = now();
  END;
$function$
;


