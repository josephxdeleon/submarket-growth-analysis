\set ON_ERROR_STOP on

CREATE TEMP TABLE imputed_zips AS
SELECT zip_code FROM core.fact_market WHERE is_imputed;

DROP TABLE IF EXISTS staging.market_history_raw;

CREATE TABLE staging.market_history_raw (
    zip_code       integer,
    snapshot_date  date,
    market_size    integer,
    members        integer,
    members_gained integer,
    members_lost   integer
);

\copy staging.market_history_raw FROM 'data/market_history.csv' WITH (FORMAT csv, HEADER true)


DROP TABLE IF EXISTS core.fact_market CASCADE;

CREATE TABLE core.fact_market (
    zip_code       integer NOT NULL REFERENCES core.dim_geography(zip_code),
    snapshot_date  date    NOT NULL,
    market_size    integer NOT NULL CHECK (market_size > 0),
    members        integer NOT NULL CHECK (members >= 0),
    members_gained integer CHECK (members_gained >= 0),
    members_lost   integer CHECK (members_lost   >= 0),
    is_imputed     boolean NOT NULL DEFAULT false,
    PRIMARY KEY (zip_code, snapshot_date)
);

CREATE INDEX idx_fact_market_date ON core.fact_market (snapshot_date);

INSERT INTO core.fact_market
    (zip_code, snapshot_date, market_size, members,
     members_gained, members_lost, is_imputed)
SELECT
    h.zip_code,
    h.snapshot_date,
    h.market_size,
    h.members,
    h.members_gained,
    h.members_lost,
    (i.zip_code IS NOT NULL) AS is_imputed
FROM staging.market_history_raw h
LEFT JOIN imputed_zips i USING (zip_code);

DROP TABLE IF EXISTS core.dim_date CASCADE;

CREATE TABLE core.dim_date AS
SELECT
    snapshot_date,
    EXTRACT(YEAR    FROM snapshot_date)::integer  AS year,
    EXTRACT(QUARTER FROM snapshot_date)::integer  AS quarter,
    'Q' || EXTRACT(QUARTER FROM snapshot_date)::text
        || ' ' || EXTRACT(YEAR FROM snapshot_date)::text AS period_label,
    (EXTRACT(QUARTER FROM snapshot_date) = 1)     AS is_open_enrollment,

    ROW_NUMBER() OVER (ORDER BY snapshot_date)    AS period_index,
    (snapshot_date = MAX(snapshot_date) OVER ())  AS is_current
FROM (SELECT DISTINCT snapshot_date FROM core.fact_market) d;

ALTER TABLE core.dim_date ADD PRIMARY KEY (snapshot_date);

SELECT COUNT(*)                        AS rows,
       COUNT(DISTINCT zip_code)        AS zips,
       COUNT(DISTINCT snapshot_date)   AS periods,
       MIN(snapshot_date)              AS first_period,
       MAX(snapshot_date)              AS last_period
FROM core.fact_market;

SELECT SUM(market_size) AS market,
       SUM(members)     AS members,
       ROUND(SUM(members)::numeric / SUM(market_size), 4) AS share
FROM core.fact_market f
JOIN core.dim_date d USING (snapshot_date)
WHERE d.is_current;

SELECT COUNT(*) AS imputed_rows, COUNT(DISTINCT zip_code) AS imputed_zips
FROM core.fact_market WHERE is_imputed;

SELECT zip_code, COUNT(*) AS periods
FROM core.fact_market
GROUP BY zip_code
HAVING COUNT(*) <> (SELECT COUNT(*) FROM core.dim_date);

SELECT d.period_label,
       COUNT(*) FILTER (WHERE f.members_gained IS NULL) AS null_gained,
       COUNT(*) FILTER (WHERE f.members_lost   IS NULL) AS null_lost
FROM core.fact_market f
JOIN core.dim_date d USING (snapshot_date)
GROUP BY d.period_label, d.period_index
ORDER BY d.period_index;

WITH chk AS (
    SELECT zip_code, snapshot_date, members, members_gained, members_lost,
           LAG(members) OVER (PARTITION BY zip_code ORDER BY snapshot_date) AS prior
    FROM core.fact_market
)
SELECT COUNT(*) AS reconciliation_failures
FROM chk
WHERE prior IS NOT NULL
  AND members - prior <> members_gained - members_lost;