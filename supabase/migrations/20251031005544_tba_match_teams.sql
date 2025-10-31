set check_function_bodies = off;

CREATE OR REPLACE FUNCTION tba.matches_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
    DECLARE
      is_de boolean;
      match_key_data text;
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
        COALESCE(
          TO_TIMESTAMP((NEW.data->>'actual_time')::bigint),
          TO_TIMESTAMP((NEW.data->>'time')::bigint)
        ),
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
        winner = EXCLUDED.winner
      RETURNING key INTO match_key_data;

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

      RETURN NULL;
    END;
  $function$
;


