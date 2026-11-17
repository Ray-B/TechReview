# Weather Data Platform

Local pipeline that ingests NOAA GHCN-Daily observations for airport
stations in Canada's 5 largest metro areas, transforms them with dbt on
DuckDB, and generates AI daily weather narratives with Gemini.

## Important Developers Note: SEE "Updated Tests" for new tests and reasoning.

## Setup

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

cp .env.example .env                       # add your GEMINI_API_KEY
cp dbt_project/profiles.yml.example dbt_project/profiles.yml

./scripts/run_pipeline.sh
```

This runs, in order: download raw files -> parse fixed-width metadata ->
load everything into `raw.*` tables in DuckDB -> `dbt seed` + `dbt build`
(staging -> intermediate -> marts, with tests) -> bulk narrative
generation against `marts.fct_daily_weather`.

Inspect results with `duckdb weather.duckdb` and e.g.
`select * from main_marts.weather_narratives limit 20;`

**Note on schema names:** dbt-duckdb's default schema-naming behavior
prefixes custom schemas with the profile's target schema, so
`+schema: marts` in `dbt_project.yml` produces the schema `main_marts`
(similarly `main_staging`, `main_intermediate`). That's why the narrative
script and the query above reference `main_marts.*`.

## Architecture

```
NOAA files (fixed-width + gzipped CSV)
        |
   ingestion/*.py  -->  raw.* tables in DuckDB
        |
   dbt: staging     (1:1 with sources, typed/renamed)
        |
   dbt: intermediate (station resolution, inventory-driven element filter, pivot)
        |
   dbt: marts        (fct_daily_weather, dim_stations, dq_observation_coverage)
        |
   narrative_pipeline/generate_narratives.py --> Gemini --> main_marts.weather_narratives
```

- **tests**: `assert_one_station_per_target_city.sql` guards the config-driven
  station resolution (see below); the rest are schema tests declared next to
  each model.
- **staging**: `stg_stations`, `stg_inventory`, `stg_observations` — casting,
  renaming, unit conversion (GHCN values are in tenths), missing-value
  sentinel (`-9999`) handling, date-window scoping via `vars`.
- **intermediate**: `int_target_stations` resolves the city seed against
  station metadata; `int_observations_pivoted` filters observations to
  (station, element) pairs that `ghcnd-inventory.txt` actually confirms,
  then pivots long-format rows into one row per station-date.
- **marts**: `fct_daily_weather` (narrative input), `dim_stations`,
  `dq_observation_coverage` (monthly completeness/flag-rate rollup).

## Design decisions: config-driven station/element handling

This was the requirement I optimized hardest for.

**Station selection** lives entirely in `dbt_project/seeds/target_cities.csv`
— city name, country code, and a semicolon-separated list of required
keywords to match against `stations.name`. `int_target_stations.sql` joins
the seed to `stg_stations`, requiring every keyword to appear somewhere in
the (punctuation-stripped) name; no SQL file anywhere contains a literal
station ID. Adding a 6th city means adding one CSV row.

I checked this against NOAA's actual `readme.txt` and real station-naming
conventions rather than assuming, and it caught two real bugs before they
shipped:
- A single-phrase match (e.g. `"OTTAWA INTL"`) fails against real station
  names, which have infix qualifiers the task's simplified city table
  doesn't show — Toronto's actual station is
  `TORONTO LESTER B PEARSON INTL A` and Ottawa's is
  `OTTAWA MACDONALD-CARTIER INTL A`. Fixed by matching "contains all
  keywords anywhere" instead of one contiguous phrase.
- Environment Canada-sourced names are inconsistent about `INTL` vs
  `INT'L` vs `INT-L`. Fixed by stripping non-alphanumeric characters from
  both the station name and the seed's keywords before comparing.
- Added `tests/assert_one_station_per_target_city.sql`, a singular dbt
  test that fails the build if any configured city resolves to zero or
  more than one station — the safety net for this whole approach, since a
  bad keyword should break loudly rather than silently drop a city or
  double-count one. Verified it catches both failure modes by testing
  against synthetic data with decoy stations (`CALGARY SPRINGBANK`,
  `OTTAWA GATINEAU`, etc.) that must NOT match.
- Keyword matching alone was still not enough to uniquely resolve a city.
  Real GHCN data has multiple stations per major city: historical records,
  renamed airports, secondary airports (Montreal also has Mirabel), and
  duplicate entries for the same airport under a different network code
  (Calgary has three "INTL"-ish records). A "most recently reporting
  station wins" tiebreaker seemed like the obvious fix but actually breaks
  on Calgary — one of its duplicate/historical records has *more recent*
  data than the intended station. The working fix: require the matched
  station to actually have downloaded observation data
  (`ingestion/download_data.py`'s hardcoded list is the only place that
  determines this) — see `int_target_stations.sql` for the full
  reasoning.

The one exception is `ingestion/download_data.py`, which has a hardcoded
list of station IDs to know *which observation files to fetch from NOAA*.
This is a download-scoping optimization, not a modeling decision — GHCN
doesn't offer a "give me observations for stations matching this name
pattern" endpoint, so something has to decide what to download before
metadata is even in the database. If you added a 6th city today you'd
add its ID here too, but every transformation downstream is agnostic to
that list.

**Element selection** is driven by `ghcnd-inventory.txt`, intersected
with a `supported_elements` var in `dbt_project.yml` (an allowlist of
elements we know how to narrate, so we don't pivot into dozens of
obscure sensor codes). The pivot itself is generated by a Jinja loop over
that var — adding an element means adding one string to the var list,
not touching pivot logic.

## Repo layout

```
ingestion/              download + fixed-width parsing + DuckDB loading
dbt_project/            staging / intermediate / marts models + seeds + tests
narrative_pipeline/     Gemini-based narrative generation
scripts/run_pipeline.sh end-to-end runner
data/raw/               downloaded files (gitignored, populated by ingestion/)
```


## Updated Tests

1. assert_mart_values_match_noaa_units.sql

**What it does**
This test is designed to protect against incorrect units ultimately reaching merchants. It checks every temperature, precipitation, snowfall and snow-depth value in fct_daily_weather against NOAA's raw value multiplied by the scale NOAA documents for that measurement (tenths for temperature and precipitation, whole millimetres for snow). It should catch conversion bugs in our code and format changes on NOAA's side. Wind is left out because none of the five stations reports it, but future iterations of this project should consider expanding to include this.

**What happens when it fails"**

I've set the severity for this test to be an actual blocking error. The dbt build will fail and the pipeline will stop before the narrative step. We should also see each data for each failure: the mismatched value with the raw value, the expected value and the stored value.

**Who should be told**: A developer on the data engineering team should be notified, and someone from the product team as well since this might mean narratives not being deliver to customers ultimately. This could pump data over to something like prometheus or datadog and show up in a dashboard.

**Example Results on Failure** 
FAIL, 1,103 rows. All are snowfall (414) and snow depth (689); temperature and precipitation pass. Example: Montreal, 16 February 2025, raw snowfall 368 mm, stored as 36.8. The cause is stg_observations.sql, which divides every measurement by 10. I have left that code unchanged, as the brief asks; changing that one line to skip the division for SNOW and SNWD makes the test pass.

2. assert_every_station_has_every_day

**What it does** 

This works to try an detect when a station's data is going stale and tried to prevent situations where there are data gaps that go undetected. It builds a calendar of every day in the configured window (start_date to end_date in dbt_project.yml) and lists each target station's missing days in fct_daily_weather.

**What happens when it fails** 

I've set this to a WARN, simply because I wouldn't be shocked if sometimes we have gaps in our data vendor (NOAA in this case, but could be environment canada too). Instead, it has two levels. With 1 to 30 missing station-days it warns: the build continues and the missing days are listed. With more than 30, about a month of silence from one station, it will FAIL.

**Who should be told**

A developer on the data engineering team should be notified at a minimum, but if other team who are invested want to know, this could pump data over to something like prometheus or datadog and show up in a dashboard too.

**Example Results on Failure**
WARN, 9 missing station-days (Montreal 4, Vancouver 4, Ottawa 1). To see the error level, run with a window that extends past the data, which simulates feeds that have gone silent: dbt test --select assert_every_station_has_every_day --vars '{end_date: "2026-12-31"}' gives FAIL 1,834.