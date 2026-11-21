"""Group-level Linear Mixed-Effects Model (LMM) with built-in lesion severity covariates."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import pandas as pd
import statsmodels.formula.api as smf


def run_group_lmm(
    data_path: Path,
    formula: str,
    group_col: str = "subject_id",
    include_lesion_volume: bool = True,
    include_roi_damage: bool = True,
    re_formula: str | None = None,
    out_dir: Path | None = None,
) -> dict:
    """Fit a statsmodels MixedLM dropping NaN (lesion-excluded) ROI rows automatically."""
    sep = "\t" if data_path.suffix.lower() in (".tsv", ".txt") else ","
    df = pd.read_csv(data_path, sep=sep)

    effective_formula = formula.strip()
    if include_lesion_volume and "total_lesion_volume_ml" in df.columns:
        if "total_lesion_volume_ml" not in effective_formula:
            effective_formula += " + total_lesion_volume_ml"
    if include_roi_damage and "roi_percent_damage" in df.columns:
        if "roi_percent_damage" not in effective_formula:
            effective_formula += " + roi_percent_damage"

    lhs = effective_formula.split("~", 1)[0].strip()
    n_total_rows = len(df)
    df_clean = df.dropna(subset=[lhs, group_col]).copy()
    n_dropped_nan = n_total_rows - len(df_clean)

    model = smf.mixedlm(
        effective_formula,
        data=df_clean,
        groups=df_clean[group_col],
        re_formula=re_formula,
    )
    fit = model.fit(reml=True, method="lbfgs")

    fe_rows = []
    for name in fit.fe_params.index:
        fe_rows.append(
            {
                "term": str(name),
                "estimate": float(fit.fe_params[name]),
                "std_err": float(fit.bse_fe[name]),
                "z_value": float(fit.tvalues[name]),
                "p_value": float(fit.pvalues[name]),
            }
        )

    summary = {
        "formula": effective_formula,
        "group_col": group_col,
        "n_rows_input": int(n_total_rows),
        "n_rows_used": int(len(df_clean)),
        "n_rows_dropped_nan": int(n_dropped_nan),
        "n_groups": int(df_clean[group_col].nunique()),
        "converged": bool(fit.converged),
        "aic": float(fit.aic) if pd.notna(fit.aic) else None,
        "bic": float(fit.bic) if pd.notna(fit.bic) else None,
        "loglik": float(fit.llf),
        "fixed_effects": fe_rows,
    }

    if out_dir is not None:
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / "lmm_summary.json").write_text(
            json.dumps(summary, indent=2), encoding="utf-8"
        )
        pd.DataFrame(fe_rows).to_csv(out_dir / "lmm_fixed_effects.csv", index=False)

    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description="Group-level LMM with lesion covariates.")
    parser.add_argument("--data", required=True, type=Path)
    parser.add_argument("--formula", required=True, help="e.g. 'fc_value ~ condition'")
    parser.add_argument("--group-col", default="subject_id")
    parser.add_argument("--no-lesion-volume", action="store_true")
    parser.add_argument("--no-roi-damage", action="store_true")
    parser.add_argument("--re-formula", default=None)
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()

    res = run_group_lmm(
        args.data,
        args.formula,
        group_col=args.group_col,
        include_lesion_volume=not args.no_lesion_volume,
        include_roi_damage=not args.no_roi_damage,
        re_formula=args.re_formula,
        out_dir=args.out,
    )
    print(json.dumps(res, indent=2))


if __name__ == "__main__":
    main()
