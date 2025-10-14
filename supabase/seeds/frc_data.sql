INSERT INTO frc_event_types
  (id, is_district, is_championship, is_division, is_offseason, name, name_short)
VALUES
  (0, FALSE, FALSE, FALSE, FALSE, 'Regional Event', 'Regional'),
  (1, TRUE, FALSE, FALSE, FALSE, 'District Event', 'District'),
  (2, TRUE, TRUE, FALSE, FALSE, 'District Championship', 'District Championship'),
  (3, FALSE, TRUE, TRUE, FALSE, 'Championship Division', 'Division'),
  (4, FALSE, TRUE, FALSE, FALSE, 'Championship Finals', 'Championship'),
  (5, TRUE, TRUE, TRUE, FALSE, 'District Championship Division', 'District Division'),
  (6, FALSE, FALSE, FALSE, FALSE, 'Festival of Champions', 'Festival'),
  (7, FALSE, FALSE, FALSE, FALSE, 'Remote Event', 'Remote'),
  (99, FALSE, FALSE, FALSE, TRUE, 'Offseason Event', 'Offseason'),
  (100, FALSE, FALSE, FALSE, TRUE, 'Preseason Event', 'Preseason');


INSERT INTO frc_seasons
  (year, name)
VALUES
  (1992, 'Maize Craze'),
  (1993, 'Rug Rage'),
  (1994, 'Tower Power'),
  (1995, 'Ramp N'' Roll'),
  (1996, 'Hexagon Havoc'),
  (1997, 'Toroid Terror'),
  (1998, 'Ladder Logic'),
  (1999, 'Double Trouble'),
  (2000, 'Co-opertition FIRST'),
  (2001, 'Diabolical Dynamics'),
  (2002, 'Zone Zeal'),
  (2003, 'Stack Attack'),
  (2004, 'FIRST Frenzy'),
  (2005, 'Triple Play'),
  (2006, 'Aim High'),
  (2007, 'Rack N'' Roll'),
  (2008, 'FIRST Overdrive'),
  (2009, 'Lunacy'),
  (2010, 'Breakaway'),
  (2011, 'Logo Motion'),
  (2012, 'Rebound Rumble'),
  (2013, 'Ultimate Ascent'),
  (2014, 'Aerial Assist'),
  (2015, 'Recycle Rush'),
  (2016, 'FIRST Stronghold'),
  (2017, 'FIRST Steamworks'),
  (2018, 'FIRST Power Up'),
  (2019, 'Destination: Deep Space'),
  (2020, 'Infinite Recharge'),
  (2021, 'Infinite Recharge'),
  (2022, 'Rapid React'),
  (2023, 'Charged Up'),
  (2024, 'Crescendo'),
  (2025, 'Reefscape'),
  (2026, 'Rebuilt');
