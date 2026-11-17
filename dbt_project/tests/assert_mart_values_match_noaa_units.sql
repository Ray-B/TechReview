-- Data quality check 1: every value in the final weather table must equal
-- NOAA's raw value multiplied by the scale NOAA documents for that element.
--
-- Protects against: unit and scaling errors reaching merchants, e.g. snowfall
-- reported at one tenth of its real amount.
-- Scales are from NOAA's readme.txt (section III):
--   TMAX, TMIN = tenths of degrees C  -> multiply by 0.1
--   PRCP       = tenths of mm         -> multiply by 0.1
--   SNOW, SNWD = whole mm             -> multiply by 1
--
-- Returns one row per mismatched value. Zero rows = pass.

{{ config(severity = 'error') }}

with expected_scale as (

    select * from (values
        ('TMAX', 0.1),
        ('TMIN', 0.1),
        ('PRCP', 0.1),
        ('SNOW', 1.0),
        ('SNWD', 1.0)
    ) as t(element, scale)

),

raw_values as (

    select
        station_id,
        strptime(date_raw, '%Y%m%d')::date as obs_date,
        element,
        try_cast(value as double) as raw_value
    from {{ source('raw', 'observations') }}

),

final_values as (

    select station_id, city_name, obs_date, 'TMAX' as element, tmax_c        as final_value from {{ ref('fct_daily_weather') }}
    union all
    select station_id, city_name, obs_date, 'TMIN',            tmin_c                       from {{ ref('fct_daily_weather') }}
    union all
    select station_id, city_name, obs_date, 'PRCP',            precip_mm                    from {{ ref('fct_daily_weather') }}
    union all
    select station_id, city_name, obs_date, 'SNOW',            snow_mm                      from {{ ref('fct_daily_weather') }}
    union all
    select station_id, city_name, obs_date, 'SNWD',            snow_depth_mm                from {{ ref('fct_daily_weather') }}

)

select
    f.city_name,
    f.obs_date,
    f.element,
    r.raw_value,
    s.scale                     as expected_scale,
    r.raw_value * s.scale       as expected_value,
    f.final_value
from final_values f
join raw_values r
    on  r.station_id = f.station_id
    and r.obs_date   = f.obs_date
    and r.element    = f.element
join expected_scale s
    on s.element = f.element
where f.final_value is not null
  and r.raw_value is not null
  and abs(f.final_value - r.raw_value * s.scale) > 0.001