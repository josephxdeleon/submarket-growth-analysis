DROP VIEW IF EXISTS core.v_growth_priority           CASCADE;
DROP VIEW IF EXISTS core.v_region_summary            CASCADE;
DROP VIEW IF EXISTS core.v_med_center_performance    CASCADE;
DROP VIEW IF EXISTS core.v_service_area_performance  CASCADE;
DROP VIEW IF EXISTS core.v_service_area_trend        CASCADE;
DROP VIEW IF EXISTS core.v_med_center_trend          CASCADE;
DROP VIEW IF EXISTS core.v_retention                 CASCADE;
DROP VIEW IF EXISTS core.v_market_base               CASCADE;


-- Base: all periods, geography and calendar attached.
CREATE OR REPLACE VIEW core.v_market_base AS
SELECT
    f.zip_code,
    g.service_area,
    g.med_center,
    f.snapshot_date,
    d.period_label,
    d.period_index,
    d.is_current,
    d.is_open_enrollment,
    f.market_size,
    f.members,
    f.members_gained,
    f.members_lost,
    f.is_imputed
FROM core.fact_market f
JOIN core.dim_geography g USING (zip_code)
JOIN core.dim_date      d USING (snapshot_date);


-- Current Period Views
CREATE OR REPLACE VIEW core.v_service_area_performance AS
WITH sa AS (
    SELECT service_area,
           SUM(market_size)            AS market_size,
           SUM(members)                AS members,
           COUNT(DISTINCT med_center)  AS med_centers
    FROM core.v_market_base
    WHERE is_current
    GROUP BY service_area
),
ctx AS (
    SELECT *,
           SUM(market_size) OVER () AS region_market,
           SUM(members)     OVER () AS region_members
    FROM sa
)
SELECT
    service_area,
    market_size,
    members,
    med_centers,
    ROUND(members::numeric / market_size, 4) AS share,
    ROUND((region_members - members)::numeric
          / NULLIF(region_market - market_size, 0), 4) AS benchmark_share,
    ROUND(members::numeric / market_size
          - (region_members - members)::numeric
            / NULLIF(region_market - market_size, 0), 4) AS gap_pp,
    ROUND(market_size * (
        (region_members - members)::numeric
        / NULLIF(region_market - market_size, 0)
        - members::numeric / market_size
    ))::integer AS opportunity_members
FROM ctx;

-- Med center performance for current period
CREATE OR REPLACE VIEW core.v_med_center_performance AS
WITH mc AS (
    SELECT service_area, med_center,
           SUM(market_size)     AS market_size,
           SUM(members)         AS members,
           bool_or(is_imputed)  AS contains_imputed
    FROM core.v_market_base
    WHERE is_current
    GROUP BY service_area, med_center
),
benched AS (
    SELECT *,
           (SUM(members) OVER () - SUM(members) OVER (PARTITION BY service_area))::numeric
           / NULLIF(SUM(market_size) OVER ()
                    - SUM(market_size) OVER (PARTITION BY service_area), 0)
           AS benchmark_share
    FROM mc
)
SELECT
    service_area,
    med_center,
    market_size,
    members,
    contains_imputed,
    ROUND(members::numeric / market_size, 4)                   AS share,
    ROUND(benchmark_share, 4)                                  AS benchmark_share,
    ROUND(members::numeric / market_size - benchmark_share, 4) AS gap_pp,
    ROUND(market_size * (benchmark_share - members::numeric / market_size))::integer
        AS opportunity_members,

    -- Positive-only variant for prioritization. Surplus performers are
    -- not a growth opportunity; letting their surplus net against a
    -- deficit elsewhere would understate total addressable upside.
    GREATEST(ROUND(market_size * (benchmark_share - members::numeric / market_size))::integer, 0)
        AS upside_members,

    ROUND(100.0 * GREATEST(market_size * (benchmark_share - members::numeric / market_size), 0)
          / NULLIF(SUM(GREATEST(market_size * (benchmark_share - members::numeric / market_size), 0))
                   OVER (), 0), 1) AS pct_of_total_upside
FROM benched;

-- Prioritization ranking
CREATE OR REPLACE VIEW core.v_growth_priority AS
SELECT
    service_area, med_center, market_size, members,
    share, benchmark_share, gap_pp,
    upside_members, pct_of_total_upside,

    RANK() OVER (ORDER BY upside_members DESC, market_size DESC) AS rank_by_upside,
    RANK() OVER (ORDER BY share ASC)                             AS rank_by_weakest_share,

    ROUND(
        100.0 * SUM(upside_members) OVER (
            ORDER BY upside_members DESC, market_size DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) / NULLIF(SUM(upside_members) OVER (), 0),
    1) AS cumulative_pct_of_upside

FROM core.v_med_center_performance
WHERE upside_members > 0;


-- Region summary
CREATE OR REPLACE VIEW core.v_region_summary AS
SELECT
    SUM(market_size)                                     AS market_size,
    SUM(members)                                         AS members,
    ROUND(SUM(members)::numeric / SUM(market_size), 4)   AS share,
    COUNT(DISTINCT service_area)                         AS service_areas,
    COUNT(DISTINCT med_center)                           AS med_centers,
    (SELECT SUM(upside_members) FROM core.v_med_center_performance)
                                                         AS total_upside_members,
    MAX(snapshot_date)                                   AS snapshot_date
FROM core.v_market_base
WHERE is_current;


-- Trend views
CREATE OR REPLACE VIEW core.v_service_area_trend AS
WITH sa AS (
    SELECT service_area, snapshot_date, period_label, period_index,
           is_open_enrollment,
           SUM(market_size) AS market_size,
           SUM(members)     AS members
    FROM core.v_market_base
    GROUP BY 1,2,3,4,5
),
ctx AS (
    SELECT *,
           SUM(market_size) OVER (PARTITION BY snapshot_date) AS region_market,
           SUM(members)     OVER (PARTITION BY snapshot_date) AS region_members
    FROM sa
),
calc AS (
    SELECT *,
           members::numeric / market_size AS share,
           (region_members - members)::numeric
             / NULLIF(region_market - market_size, 0) AS benchmark_share
    FROM ctx
)
SELECT
    service_area, snapshot_date, period_label, period_index,
    is_open_enrollment, market_size, members,
    ROUND(share, 4)                        AS share,
    ROUND(benchmark_share, 4)              AS benchmark_share,
    ROUND(share - benchmark_share, 4)      AS gap_pp,

    -- Movement vs prior quarter and vs same quarter last year
    -- YoY is best bc quarter-over-quarter is distorted by the Jan open-enrollment spike
    ROUND(share - LAG(share, 1) OVER w, 4) AS share_change_qoq,
    ROUND(share - LAG(share, 4) OVER w, 4) AS share_change_yoy,

    -- Gap trajectory. Widening means the unit is losing ground to its
    -- peers, independent of whether its own share rose or fell.
    ROUND((share - benchmark_share)
          - LAG(share - benchmark_share, 4) OVER w, 4) AS gap_change_yoy
FROM calc
WINDOW w AS (PARTITION BY service_area ORDER BY period_index);

-- Med center share by period
CREATE OR REPLACE VIEW core.v_med_center_trend AS
WITH mc AS (
    SELECT service_area, med_center, snapshot_date, period_label, period_index,
           SUM(market_size) AS market_size,
           SUM(members)     AS members
    FROM core.v_market_base
    GROUP BY 1,2,3,4,5
),
calc AS (
    SELECT *,
           members::numeric / market_size AS share,
           LAG(members, 4)     OVER w AS members_yoy,
           LAG(market_size, 4) OVER w AS market_yoy,
           LAG(members::numeric / market_size, 4) OVER w AS share_yoy
    FROM mc
    WINDOW w AS (PARTITION BY med_center ORDER BY period_index)
)
SELECT
    service_area, med_center, snapshot_date, period_label, period_index,
    market_size, members,
    ROUND(share, 4)                   AS share,
    ROUND(share - share_yoy, 4)       AS share_change_yoy,
    members - members_yoy             AS member_change_yoy,
    market_size - market_yoy          AS market_change_yoy,

    ROUND(100.0 * (members - members_yoy) / NULLIF(members_yoy, 0), 1)
        AS member_growth_pct_yoy,
    ROUND(100.0 * (market_size - market_yoy) / NULLIF(market_yoy, 0), 1)
        AS market_growth_pct_yoy,

    -- Attribution
    CASE
        WHEN share_yoy IS NULL THEN NULL
        WHEN share >= share_yoy THEN 'gaining share'
        WHEN 100.0 * (members - members_yoy) / NULLIF(members_yoy, 0) < -1.0
            THEN 'losing members'
        ELSE 'outgrown by market'
    END AS share_movement_driver
FROM calc;


-- Retention Views
CREATE OR REPLACE VIEW core.v_retention AS
WITH mc AS (
    SELECT service_area, med_center, snapshot_date, period_label, period_index,
           SUM(members)         AS members,
           SUM(members_gained)  AS gained,
           SUM(members_lost)    AS lost
    FROM core.v_market_base
    GROUP BY 1,2,3,4,5
),
calc AS (
    SELECT *,
           LAG(members) OVER (PARTITION BY med_center ORDER BY period_index)
             AS prior_members
    FROM mc
)
SELECT
    service_area, med_center, snapshot_date, period_label, period_index,
    prior_members, gained, lost,
    members,
    gained - lost AS net_change,

    -- Quarterly retention
    ROUND(100.0 * (prior_members - lost) / NULLIF(prior_members, 0), 2)
        AS retention_rate_pct,

    -- Gross
    ROUND(100.0 * gained / NULLIF(prior_members, 0), 2)
        AS gross_add_rate_pct,

    -- Which lever is binding
    CASE
        WHEN prior_members IS NULL      THEN NULL
        WHEN gained - lost >= 0         THEN 'growing'
        WHEN lost > gained * 1.2        THEN 'retention problem'
        ELSE                                 'acquisition shortfall'
    END AS primary_constraint
FROM calc;


SELECT service_area, share, benchmark_share, gap_pp, opportunity_members
FROM core.v_service_area_performance ORDER BY opportunity_members DESC;

SELECT service_area, med_center, market_size, share, upside_members,
       cumulative_pct_of_upside, rank_by_upside
FROM core.v_growth_priority ORDER BY rank_by_upside;

SELECT period_label, share, benchmark_share, gap_pp, share_change_yoy
FROM core.v_service_area_trend
WHERE service_area = 'Mountain Town'
ORDER BY period_index;

SELECT med_center, period_label, share, member_growth_pct_yoy,
       market_growth_pct_yoy, share_movement_driver
FROM core.v_med_center_trend
WHERE service_area = 'Mountain Town' AND share_movement_driver IS NOT NULL
ORDER BY med_center, period_index;