-- MANUAL INTERVENTION
alter table "public"."frc_matches" alter column "label" set EXPRESSION AS (
CASE
    WHEN (level = 'practice'::frc_match_level) THEN ('Practice '::text || (number)::text)
    WHEN (level = 'qualification'::frc_match_level) THEN ('Qualification '::text || (number)::text)
    WHEN (level = 'playoff'::frc_match_level) THEN ('Playoff '::text || (number)::text)
    WHEN (level = 'final'::frc_match_level) THEN ('Final '::text || (number)::text)
    WHEN (level = 'eighthfinal'::frc_match_level) THEN ((('Eighth-Final '::text || (set)::text) || '-'::text) || (number)::text)
    WHEN (level = 'quarterfinal'::frc_match_level) THEN ((('Quarterfinal '::text || (set)::text) || '-'::text) || (number)::text)
    WHEN (level = 'semifinal'::frc_match_level) THEN ((('Semifinal '::text || (set)::text) || '-'::text) || (number)::text)
    ELSE '???'::text
END ||
CASE
    WHEN (replay = 0) THEN ''::text
    WHEN (replay = 1) THEN ' Replay'::text
    ELSE (' Replay '::text || (replay)::text)
END);
