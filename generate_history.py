"""
generate_history.py
===================
Generates 8 quarters of SYNTHETIC membership history for the submarket
growth model.

WHY THIS EXISTS
    The source case data is a single snapshot. That supports "here is
    the current gap" but not "is the gap widening", and it cannot
    support any retention analysis at all. Both are core to the
    business question, so history is generated rather than left absent.

    Everything this script produces is FABRICATED. It is labelled as
    such in the README and in the loaded table name. It is not a
    forecast, a backcast, or an estimate of anything real.

DESIGN CONSTRAINT
    The final quarter (2026-06-30) is pinned to the exact observed
    values from core.fact_market. That means 04_reconcile.sql continues
    to tie to the case-sheet totals after the history is loaded. The
    generator can never silently break the reconciliation.

USAGE
    pip install psycopg2-binary pandas numpy python-dotenv
    python scripts/generate_history.py
    -> writes data/market_history.csv
"""

import os
import numpy as np
import pandas as pd
import psycopg2
from dotenv import load_dotenv

load_dotenv()

SEED = 42
OUT_PATH = "data/market_history.csv"

QUARTERS = [
    "2024-09-30", "2024-12-31", "2025-03-31", "2025-06-30",
    "2025-09-30", "2025-12-31", "2026-03-31", "2026-06-30",
]

# ---------------------------------------------------------------------
# Trajectory assumptions, expressed as the index value 8 quarters ago
# relative to today = 1.00.
#
#   > 1.00 means the med center had MORE members then than now (decline)
#   < 1.00 means it had FEWER then than now (growth)
#
# These encode the narrative the case implies: Mountain Town is losing
# high tech membership to a PPO competitor while its market grows.
# ---------------------------------------------------------------------
MEMBER_INDEX = {
    # Mountain Town: membership eroding
    "Glacier Peak": 1.06, "Summit": 1.03, "Sierra": 1.00,
    # Desert Valley: strongest performer, still growing
    "Joshua Tree": 0.93, "Mojave": 0.94, "Sahara": 0.92,
    # Manhattan City: mature and flat
    "City Center": 0.99, "Cosmopolitan": 0.98, "Empire": 0.99,
    # Sandy Beach: mixed, Shady Cove declining
    "Gold Coast": 0.96, "Blue Harbor": 0.99, "Shady Cove": 1.05,
}

MARKET_INDEX = {
    # Mountain Town market growing fastest -> share falls even where
    # membership is flat. This is the analytically interesting case:
    # Sierra loses no members yet still loses share.
    "Glacier Peak": 0.91, "Summit": 0.94, "Sierra": 0.97,
    "Joshua Tree": 0.98, "Mojave": 0.98, "Sahara": 0.97,
    "City Center": 0.99, "Cosmopolitan": 0.99, "Empire": 0.99,
    "Gold Coast": 0.98, "Blue Harbor": 0.99, "Shady Cove": 0.99,
}

# Quarterly voluntary termination rate, applied to prior-quarter members
# to decompose net change into gross adds and losses.
BASE_CHURN = 0.021


def fetch_current_state():
    """Read the cleaned current snapshot from Postgres."""
    conn = psycopg2.connect(
        host=os.getenv("PGHOST", "localhost"),
        port=os.getenv("PGPORT", "5432"),
        dbname=os.getenv("PGDATABASE", "submarket_growth"),
        user=os.getenv("PGUSER", "postgres"),
        password=os.getenv("PGPASSWORD"),
    )
    try:
        return pd.read_sql(
            "SELECT zip_code, service_area, med_center, market_size, members "
            "FROM core.v_market_base ORDER BY zip_code",
            conn,
        )
    finally:
        conn.close()


def build_path(start_index, seasonal):
    """
    Interpolate from start_index to exactly 1.00 across 8 quarters.

    Geometric rather than linear because membership compounds. Q1
    quarters get an extra step to reflect January 1 open enrollment,
    when most plan switching actually happens. The final value is
    forced back to exactly 1.00 so the pin to observed data holds.
    """
    path = np.geomspace(start_index, 1.0, len(QUARTERS))
    if seasonal:
        for i, q in enumerate(QUARTERS):
            if q.endswith("03-31"):
                path[i] *= 1.0 + (1.0 - start_index) * 0.25
        path[-1] = 1.0
    return path


def generate(current):
    rng = np.random.default_rng(SEED)
    rows = []

    for _, r in current.iterrows():
        mem_path = build_path(MEMBER_INDEX[r.med_center], seasonal=True)
        mkt_path = build_path(MARKET_INDEX[r.med_center], seasonal=False)

        # Zip-level noise so submarkets are not perfectly correlated.
        # Zeroed in the final quarter to preserve the exact pin.
        noise = rng.normal(0, 0.012, len(QUARTERS))
        noise[-1] = 0.0

        prev_members = None
        for i, q in enumerate(QUARTERS):
            if i == len(QUARTERS) - 1:
                members = int(r.members)          # pinned to observed
                market = int(r.market_size)
            else:
                members = int(round(r.members * mem_path[i] * (1 + noise[i])))
                market = int(round(r.market_size * mkt_path[i]))

            # Decompose net change into gross adds and losses.
            # First quarter has no prior, so both are NULL.
            if prev_members is None:
                lost = gained = None
            else:
                lost = int(round(prev_members * BASE_CHURN * (1 + rng.normal(0, 0.15))))
                gained = members - prev_members + lost
                if gained < 0:                    # floor, push excess to losses
                    lost -= gained
                    gained = 0

            rows.append([r.zip_code, q, market, members, gained, lost])
            prev_members = members

    df = pd.DataFrame(
        rows,
        columns=["zip_code", "snapshot_date", "market_size",
                 "members", "members_gained", "members_lost"],
    )
    df[["members_gained", "members_lost"]] = (
        df[["members_gained", "members_lost"]].astype("Int64")
    )
    return df

def validate(history, current):
    """Fail loudly if the final quarter drifts from observed values."""
    final = history[history.snapshot_date == QUARTERS[-1]]
    assert len(history) == len(current) * len(QUARTERS), "unexpected row count"
    assert final.members.sum() == current.members.sum(), "members do not pin"
    assert final.market_size.sum() == current.market_size.sum(), "market does not pin"
    assert (history.members >= 0).all(), "negative members generated"
    print(f"  rows:           {len(history)}")
    print(f"  final members:  {final.members.sum():,}")
    print(f"  final market:   {final.market_size.sum():,}")


def main():
    print("Reading current snapshot from Postgres...")
    current = fetch_current_state()
    print(f"  {len(current)} zips")

    print("Generating synthetic history...")
    history = generate(current)

    print("Validating...")
    validate(history, current)

    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    history.to_csv(OUT_PATH, index=False)
    print(f"Wrote {OUT_PATH}")

    # Trend preview at service area grain
    preview = (
        history.merge(current[["zip_code", "service_area"]], on="zip_code")
        .groupby(["service_area", "snapshot_date"])[["members", "market_size"]]
        .sum()
    )
    preview["share"] = (preview.members / preview.market_size).round(4)
    print("\nShare trend by service area:")
    print(preview.share.unstack().to_string())


if __name__ == "__main__":
    main()