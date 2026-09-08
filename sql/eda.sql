SELECT * FROM staging.market_zip_raw LIMIT 20;

-- 1. Row count vs distinct key
-- 68 rows, 62 distinct zip_code values
-- but need to normalize zip_code first
SELECT COUNT(*)                  AS total_rows,
       COUNT(DISTINCT zip_code)  AS distinct_zip_raw
FROM staging.market_zip_raw;

-- normalizing zip_code
-- we get 61 distinct zip_code values
SELECT COUNT(*) AS total_rows,
       COUNT(DISTINCT regexp_replace(replace(btrim(zip_code), 'CA-', ''), '\.0$', ''))
         AS distinct_zip_clean
FROM staging.market_zip_raw;

-- 2. zip_code format variants
-- we see four patterns: state prefix, float, whitespace, TOTAL
SELECT zip_code, COUNT(*)
FROM staging.market_zip_raw
WHERE zip_code !~ '^[0-9]{5}$'
GROUP BY 1 ORDER BY 1;

-- 3. Categorical cardinality
-- we see 18 distinct values, but expect 4
-- causes: casing, whitespace, abbreviation, blank, out of scope (costal ridge)
SELECT service_area, COUNT(*)
FROM staging.market_zip_raw
GROUP BY 1 ORDER BY 1;

-- 17 distinct, expect 12
-- misspelling, whitespace, out of scope (bayview), blank
SELECT med_center, COUNT(*)
FROM staging.market_zip_raw
GROUP BY 1 ORDER BY 1;

-- 4. Values that will not cast to integer
-- thousands separators, empty strings, negative value
SELECT 'market_size' AS col, market_size AS bad_value
FROM staging.market_zip_raw WHERE market_size !~ '^[0-9]+$'
UNION ALL
SELECT 'members', members
FROM staging.market_zip_raw WHERE members !~ '^[0-9]+$'
ORDER BY 1, 2;

-- 5. Nulls vs empty strings
-- memebrs have 2 empties, blank separator row and real, missing value on zip 93232
SELECT COUNT(*) FILTER (WHERE NULLIF(btrim(zip_code), '')     IS NULL) AS zip_missing,
       COUNT(*) FILTER (WHERE NULLIF(btrim(service_area), '') IS NULL) AS sa_missing,
       COUNT(*) FILTER (WHERE NULLIF(btrim(med_center), '')   IS NULL) AS mc_missing,
       COUNT(*) FILTER (WHERE NULLIF(btrim(market_size), '')  IS NULL) AS market_missing,
       COUNT(*) FILTER (WHERE NULLIF(btrim(members), '')      IS NULL) AS members_missing
FROM staging.market_zip_raw;

-- 6. Numeric ranges, once castable
-- max value: 1,120,500 and 486,447 (this is footer row not zip)
-- negative minimum on members
WITH cast_ok AS (
  SELECT replace(market_size, ',', '')::numeric AS market_size,
         replace(members, ',', '')::numeric     AS members
  FROM staging.market_zip_raw
  WHERE replace(market_size, ',', '') ~ '^-?[0-9]+$'
    AND replace(members, ',', '')     ~ '^-?[0-9]+$'
)
SELECT MIN(market_size), MAX(market_size),
       MIN(members),     MAX(members)
FROM cast_ok;

-- this should hold: members <= market_size
-- but several zips have members > market_size
SELECT zip_code, service_area, med_center, market_size, members
FROM staging.market_zip_raw
WHERE replace(market_size, ',', '') ~ '^-?[0-9]+$'
  AND replace(members, ',', '')     ~ '^-?[0-9]+$'
  AND replace(members, ',', '')::numeric
      > replace(market_size, ',', '')::numeric;

-- 7. Duplicate analysis: exact vs versioned
-- 6 repeated keys
-- 4 exact duplicates
-- 2 versioned rows, should keep the latest version
WITH k AS (
  SELECT *, regexp_replace(replace(btrim(zip_code), 'CA-', ''), '\.0$', '') AS zip_key
  FROM staging.market_zip_raw
)
SELECT zip_key, COUNT(*) AS n,
       COUNT(DISTINCT members)       AS distinct_members,
       COUNT(DISTINCT snapshot_date) AS distinct_dates
FROM k
WHERE zip_key ~ '^[0-9]{5}$'
GROUP BY 1 HAVING COUNT(*) > 1
ORDER BY 1;

-- 8. snapshot_date formats
-- 4 formats for same date (6/30) and a stale date
SELECT snapshot_date, COUNT(*)
FROM staging.market_zip_raw
GROUP BY 1 ORDER BY 1;

-- 9. Structural junk
-- finding: fully blank separator row, total footer row, 2 rows say prior period
SELECT * FROM staging.market_zip_raw
WHERE notes <> '' OR btrim(zip_code) = '' OR upper(btrim(zip_code)) = 'TOTAL';