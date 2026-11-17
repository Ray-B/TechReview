-- Data quality check 2: every target station must have a row in the final
-- weather table for every calendar day in the configured date window.
--
-- Protects against: a station's feed going stale, stopping or developing gaps,
-- which the pipeline would otherwise pass over silently.
--
-- Returns one row per missing station-day. Zero rows = pass.
-- A few gaps are normal in NOAA data, so:
--   1 to 30 missing station-days   -> WARN  (logged, pipeline continues)
--   more than 30 missing           -> ERROR (pipeline stops before narratives)
-- 30 is roughly one month of silence from a single station.

{{ config(
    severity = 'error',
    warn_if  = '>0',
    error_if = '>30'
) }}

with calendar as (

    select cast(d as date) as obs_date
    from generate_series(
        date '{{ var("start_date") }}',
        date '{{ var("end_date") }}',
        interval 1 day
    ) as g(d)

),

expected as (

    select s.station_id, s.city_name, c.obs_date
    from {{ ref('dim_stations') }} s
    cross join calendar c

),

actual as (

    select station_id, obs_date
    from {{ ref('fct_daily_weather') }}

)

select
    e.city_name,
    e.station_id,
    e.obs_date as missing_date
from expected e
left join actual a
    on  a.station_id = e.station_id
    and a.obs_date   = e.obs_date
where a.station_id is null
order by e.city_name, e.obs_date