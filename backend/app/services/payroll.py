"""Take-home pay estimates. Deterministic code, clearly labelled as an estimate in the UI.

Per week (US, single filer, no extra withholding):
  * Federal income tax: the week's gross annualised (x52), minus the standard deduction, run through
    the 2026 brackets, then divided back by 52 — the IRS percentage-method idea, simplified.
  * FICA (Social Security 6.2% + Medicare 1.45%): international students on F-1/J-1 visas are
    generally exempt (nonresident aliens), everyone else pays it.
  * State income tax: a flat rate each employer sets (default 4.25%).
"""
from __future__ import annotations

STANDARD_DEDUCTION_2026 = 16_100.0
# (upper bound of the bracket, rate) — 2026 single filer
BRACKETS_2026 = [
    (12_400.0, 0.10),
    (50_400.0, 0.12),
    (105_700.0, 0.22),
    (201_775.0, 0.24),
    (256_225.0, 0.32),
    (640_600.0, 0.35),
    (float("inf"), 0.37),
]
SOCIAL_SECURITY = 0.062
MEDICARE = 0.0145


def federal_annual(taxable: float) -> float:
    tax, lower = 0.0, 0.0
    for upper, rate in BRACKETS_2026:
        if taxable <= lower:
            break
        tax += (min(taxable, upper) - lower) * rate
        lower = upper
    return tax


def weekly_taxes(gross_by_state_rate: dict[float, float], fica_exempt: bool) -> dict:
    """gross_by_state_rate: {state tax % -> gross earned this week under that rate}."""
    gross = sum(gross_by_state_rate.values())
    taxable = max(0.0, gross * 52 - STANDARD_DEDUCTION_2026)
    federal = federal_annual(taxable) / 52
    state = sum(g * (pct / 100) for pct, g in gross_by_state_rate.items())
    fica = 0.0 if fica_exempt else gross * (SOCIAL_SECURITY + MEDICARE)
    total = federal + state + fica
    return {
        "gross": round(gross, 2),
        "federal": round(federal, 2),
        "state": round(state, 2),
        "fica": round(fica, 2),
        "taxes": round(total, 2),
        "net": round(gross - total, 2),
        "rate": (total / gross) if gross else 0.0,
    }
