alter table "public"."frc_match_breakdowns" drop constraint "frc_match_breakdowns_pkey";

drop index if exists "public"."frc_match_breakdowns_score_breakdown_idx";

drop index if exists "public"."frc_match_teams_team_num_match_key_idx";

drop index if exists "public"."frc_match_breakdowns_pkey";

alter table "public"."frc_match_breakdowns" drop column "score_breakdown";

alter table "public"."frc_match_breakdowns" add column "data" jsonb not null;

alter table "public"."frc_match_breakdowns" add column "json_path" text not null;

CREATE INDEX frc_match_breakdowns_json_path_idx ON public.frc_match_breakdowns USING gin (json_path gin_trgm_ops);

CREATE INDEX frc_match_teams_team_num_match_key_alliance_idx ON public.frc_match_teams USING btree (team_num, match_key, alliance);

CREATE UNIQUE INDEX frc_match_breakdowns_pkey ON public.frc_match_breakdowns USING btree (match_key, alliance, json_path);

alter table "public"."frc_match_breakdowns" add constraint "frc_match_breakdowns_pkey" PRIMARY KEY using index "frc_match_breakdowns_pkey";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.jsonb_flatten(data jsonb, prefix text DEFAULT NULL::text)
 RETURNS TABLE(path text, value jsonb)
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.jsonb_flatten_array(data jsonb, prefix text DEFAULT NULL::text)
 RETURNS TABLE(path text, value jsonb)
 LANGUAGE plpgsql
AS $function$
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
$function$
;


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
      MERGE INTO frc_score_breakdowns fb
        USING score_breakdown sb ON
          fb.match_key = match_key_data AND
          fb.alliance = sb.alliance AND
          fb.json_path = sb.path
      WHEN NOT MATCHED BY TARGET
        THEN INSERT (
          match_key,
          alliance,
          json_path,
          json_data
        ) VALUES (
          match_key_data,
          sb.alliance,
          sb.path,
          sb.value
        )
      WHEN MATCHED
        THEN UPDATE SET
          json_data = sb.json_data
      WHEN NOT MATCHED BY SOURCE
        AND fb.match_key = match_key_data
        THEN DELETE;

      RETURN NULL;
    END;
  $function$
;


