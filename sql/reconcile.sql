-- This is meant to verify the cleaned data with expected values

-- 1. Service area
-- Variance should be 0
-- Expect:
-- Desert Valley: 400,000 / 225,000 16 zips
-- Manhattan City 250,000 / 105,000 
-- Mountain Town 300,000 / 90,000
-- Sandy Beach 100,000 / 45,000 1 imputed
SELECT
    t.service_area,
    SUM(f.market_size)                        AS actual_market,
    t.target_market,
    SUM(f.market_size) - t.target_market      AS market_variance,
    SUM(f.members)                            AS actual_members,
    t.target_members,
    SUM(f.members) - t.target_members         AS members_variance,
    COUNT(*)                                  AS zip_count,
    COUNT(*) FILTER (WHERE f.is_imputed)      AS imputed_zips
FROM core.fact_market f
JOIN core.dim_geography g USING (zip_code)
JOIN core.ref_service_area_target t USING (service_area)
GROUP BY t.service_area, t.target_market, t.target_members
ORDER BY t.service_area;

-- 2. Region-level
-- Expect: 1,050,000 / 465,000 / 0.4429 and both targets matching
SELECT
    SUM(f.market_size)                                       AS region_market,
    SUM(f.members)                                           AS region_members,
    ROUND(SUM(f.members)::numeric / SUM(f.market_size), 4)    AS region_share,
    (SELECT SUM(target_market)  FROM core.ref_service_area_target) AS target_market,
    (SELECT SUM(target_members) FROM core.ref_service_area_target) AS target_members
FROM core.fact_market f;

-- 3. Structural assertions
-- Expect empty set
WITH assertions AS (

    SELECT 'row_count_is_58' AS assertion,
           COUNT(*)::text    AS actual,
           '58'              AS expected
    FROM core.fact_market
    HAVING COUNT(*) <> 58

    UNION ALL
    SELECT 'service_areas_is_4', COUNT(DISTINCT service_area)::text, '4'
    FROM core.dim_geography
    HAVING COUNT(DISTINCT service_area) <> 4

    UNION ALL
    SELECT 'med_centers_is_12', COUNT(DISTINCT med_center)::text, '12'
    FROM core.dim_geography
    HAVING COUNT(DISTINCT med_center) <> 12

    UNION ALL
    SELECT 'imputed_rows_is_1', COUNT(*)::text, '1'
    FROM core.fact_market WHERE is_imputed
    HAVING COUNT(*) <> 1

    UNION ALL
    SELECT 'grain_one_row_per_zip', COUNT(*)::text, '0'
    FROM (SELECT zip_code FROM core.fact_market
          GROUP BY 1 HAVING COUNT(*) > 1) dup
    HAVING COUNT(*) > 0

    UNION ALL
    SELECT 'no_orphan_facts', COUNT(*)::text, '0'
    FROM core.fact_market f
    LEFT JOIN core.dim_geography g USING (zip_code)
    WHERE g.zip_code IS NULL
    HAVING COUNT(*) > 0

    UNION ALL
    SELECT 'no_unmapped_service_area', COUNT(*)::text, '0'
    FROM core.dim_geography g
    LEFT JOIN core.ref_service_area_target t USING (service_area)
    WHERE t.service_area IS NULL
    HAVING COUNT(*) > 0

    UNION ALL
    SELECT 'single_snapshot_date', COUNT(DISTINCT snapshot_date)::text, '1'
    FROM core.fact_market
    HAVING COUNT(DISTINCT snapshot_date) <> 1
)
SELECT * FROM assertions;


-- 4. members <= market_size does not hold at zip level, and that's okay
-- see how often it doesn't
SELECT
    COUNT(*)                                                AS zips_violating,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM core.fact_market), 1)
                                                            AS pct_of_rows
FROM core.fact_market
WHERE members > market_size;

-- confirm the constraint holds at the aggregate level though
SELECT 'service_area' AS grain, COUNT(*) AS violations
FROM (SELECT g.service_area FROM core.fact_market f
      JOIN core.dim_geography g USING (zip_code)
      GROUP BY 1 HAVING SUM(f.members) > SUM(f.market_size)) x
UNION ALL
SELECT 'med_center', COUNT(*)
FROM (SELECT g.med_center FROM core.fact_market f
      JOIN core.dim_geography g USING (zip_code)
      GROUP BY 1 HAVING SUM(f.members) > SUM(f.market_size)) y;