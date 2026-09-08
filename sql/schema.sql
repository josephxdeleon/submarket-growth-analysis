CREATE SCHEMA IF NOT EXISTS staging;

DROP TABLE IF EXISTS staging.market_zip_raw;

CREATE TABLE staging.market_zip_raw (
    zip_code text,
    service_area text,
    med_center text,
    market_size text,
    members text,
    snapshot_date text,
    notes text,
    loaded_at timestamptz DEFAULT now()
);

CREATE SCHEMA IF NOT EXISTS core;