DROP TABLE IF EXISTS core.fact_market;
DROP TABLE IF EXISTS core.dim_geography;
DROP TABLE IF EXISTS core.ref_service_area_target;

CREATE TABLE core.dim_geography (
    zip_code      integer PRIMARY KEY,
    service_area  text NOT NULL,
    med_center    text NOT NULL
);

CREATE TABLE core.fact_market (
    zip_code      integer PRIMARY KEY REFERENCES core.dim_geography(zip_code),
    market_size   integer NOT NULL CHECK (market_size > 0),
    members       integer NOT NULL CHECK (members >= 0),
    snapshot_date date    NOT NULL,
    is_imputed    boolean NOT NULL DEFAULT false
);

CREATE TABLE core.ref_service_area_target (
    service_area   text PRIMARY KEY,
    target_market  integer NOT NULL,
    target_members integer NOT NULL
);

INSERT INTO core.ref_service_area_target VALUES
    ('Desert Valley',  400000, 225000),
    ('Manhattan City', 250000, 105000),
    ('Mountain Town',  300000,  90000),
    ('Sandy Beach',    100000,  45000);


-- Transformation
DROP TABLE IF EXISTS staging.market_zip_clean;

CREATE TABLE staging.market_zip_clean AS

-- Normalize key, strip white space, CA- prefix, and .0 suffix
WITH keyed AS (
    SELECT
        regexp_replace(replace(btrim(zip_code), 'CA-', ''), '\.0$', '') AS zip_key,
        btrim(service_area) AS service_area_raw,
        btrim(med_center)   AS med_center_raw,
        btrim(market_size)  AS market_size_raw,
        btrim(members)      AS members_raw,
        btrim(snapshot_date) AS snapshot_date_raw,
        ctid                AS physical_row
    FROM staging.market_zip_raw
),

-- valid row has 5 digit numeric key
-- drop blank separator row and total footer
valid_key AS (
    SELECT * FROM keyed
    WHERE zip_key ~ '^[0-9]{5}$'
),

-- normalization maps
sa_map (variant, canonical) AS (
    VALUES
        ('desert valley',  'Desert Valley'),
        ('desert vly',     'Desert Valley'),
        ('manhattan city', 'Manhattan City'),
        ('manhattan cty',  'Manhattan City'),
        ('mountain town',  'Mountain Town'),
        ('mtn town',       'Mountain Town'),
        ('sandy beach',    'Sandy Beach'),
        ('sandy bch',      'Sandy Beach'),
        ('coastal ridge',  'Coastal Ridge')
),

mc_map (variant, canonical) AS (
    VALUES
        ('joshua tree',  'Joshua Tree'),
        ('joshua tre',   'Joshua Tree'),
        ('mojave',       'Mojave'),
        ('sahara',       'Sahara'),
        ('city center',  'City Center'),
        ('cosmopolitan', 'Cosmopolitan'),
        ('empire',       'Empire'),
        ('glacier peak', 'Glacier Peak'),
        ('glacier pk',   'Glacier Peak'),
        ('sierra',       'Sierra'),
        ('summit',       'Summit'),
        ('gold coast',   'Gold Coast'),
        ('blue harbor',  'Blue Harbor'),
        ('shady cove',   'Shady Cove'),
        ('bayview',      'Bayview')
),

normalized AS (
    SELECT
        v.zip_key::integer AS zip_code,
        sa.canonical       AS service_area,
        mc.canonical       AS med_center,

        -- strip thousands separators
        NULLIF(replace(v.market_size_raw, ',', ''), '')::integer AS market_size,
        NULLIF(replace(v.members_raw,     ',', ''), '')::integer AS members,

        -- parse date formats
        CASE
            WHEN v.snapshot_date_raw ~ '^\d{4}-\d{2}-\d{2}'
                THEN to_date(left(v.snapshot_date_raw, 10), 'YYYY-MM-DD')
            WHEN v.snapshot_date_raw ~ '^\d{2}/\d{2}/\d{4}$'
                THEN to_date(v.snapshot_date_raw, 'MM/DD/YYYY')
            WHEN v.snapshot_date_raw ~ '^\d{2}-[A-Za-z]{3}-\d{4}$'
                THEN to_date(v.snapshot_date_raw, 'DD-Mon-YYYY')
        END AS snapshot_date,

        v.physical_row
    FROM valid_key v
    LEFT JOIN sa_map sa ON lower(v.service_area_raw) = sa.variant
    LEFT JOIN mc_map mc ON lower(v.med_center_raw)   = mc.variant
),

-- scope filter (remove coastal ridge)
in_scope AS (
    SELECT * FROM normalized
    WHERE service_area <> 'Coastal Ridge'
),

-- remove duplicates, use latest snapshot
ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY zip_code
               ORDER BY snapshot_date DESC NULLS LAST, physical_row
           ) AS rn
    FROM in_scope
)

SELECT zip_code, service_area, med_center, market_size, members, snapshot_date
FROM ranked
WHERE rn = 1;

-- Load core
INSERT INTO core.dim_geography (zip_code, service_area, med_center)
SELECT zip_code, service_area, med_center
FROM staging.market_zip_clean;

ALTER TABLE core.fact_market ALTER COLUMN members DROP NOT NULL;

INSERT INTO core.fact_market (zip_code, market_size, members, snapshot_date)
SELECT zip_code, market_size, members, snapshot_date
FROM staging.market_zip_clean;

-- back-solve missing value
WITH gaps AS (
    SELECT g.service_area,
           COUNT(*) FILTER (WHERE f.members IS NULL) AS n_missing,
           t.target_members - COALESCE(SUM(f.members), 0) AS residual
    FROM core.fact_market f
    JOIN core.dim_geography g USING (zip_code)
    JOIN core.ref_service_area_target t USING (service_area)
    GROUP BY g.service_area, t.target_members
),
solvable AS (
    SELECT f.zip_code, gaps.residual
    FROM core.fact_market f
    JOIN core.dim_geography g USING (zip_code)
    JOIN gaps ON gaps.service_area = g.service_area
    WHERE f.members IS NULL
      AND gaps.n_missing = 1
      AND gaps.residual >= 0
)
UPDATE core.fact_market f
SET members    = solvable.residual,
    is_imputed = true
FROM solvable
WHERE f.zip_code = solvable.zip_code;

ALTER TABLE core.fact_market ALTER COLUMN members SET NOT NULL;


-- Quality checks, all four must return zero rows

-- 1. Unmapped categorical variants
SELECT 'unmapped_service_area' AS check_name, COUNT(*) AS failures
FROM staging.market_zip_clean WHERE service_area IS NULL
UNION ALL
SELECT 'unmapped_med_center', COUNT(*)
FROM staging.market_zip_clean WHERE med_center IS NULL
UNION ALL
SELECT 'unparsed_snapshot_date', COUNT(*)
FROM staging.market_zip_clean WHERE snapshot_date IS NULL
UNION ALL
SELECT 'still_null_members', COUNT(*)
FROM core.fact_market WHERE members IS NULL;

-- 2. Expected shape
SELECT COUNT(*)                                    AS row_count,          -- expect 58
       COUNT(DISTINCT service_area)                AS service_areas,      -- expect 4
       COUNT(DISTINCT med_center)                  AS med_centers,        -- expect 12
       COUNT(*) FILTER (WHERE f.is_imputed)        AS imputed_rows        -- expect 1
FROM core.fact_market f
JOIN core.dim_geography USING (zip_code);