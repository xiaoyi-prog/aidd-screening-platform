# -*- coding: utf-8 -*-
"""
pipeline_five_stage.py — 步骤3：五级筛选流水线
=================================================================
  Stage 1  AI 虚拟初筛         —— 分子 AI 模型（图神经网络/性质预测器）虚拟打分
  Stage 2  理化功能中筛         —— RDKit 理化性质 + 功能评分，与微量小试实测比对吻合度
  Stage 3  生物安全与配伍深筛    —— 安全阈值 + 配伍规则（调 risk_deep_eval 模块）
  Stage 4  建模分析            —— QSPR/MD 建模复核 + 不确定度评估
  Stage 5  生产放大评估         —— 可放大性指标（粘度/乳化能耗/批间一致性）

设计原则：
  - 每级都是独立可测试的类（stage.run(compound) -> StageVerdict），
    可单独 pytest、可单独重跑；
  - 一切决策落 ads.stage_result，run_id + lineage_event 全程回溯；
  - 「AI 预测 vs 微量小试」吻合度 = 每级输出 prediction vs observed 差值，
    写入 detail.reconciliation。

仅写代码，未运行。
"""
from __future__ import annotations

import json
import os
import uuid
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Optional

DB_DSN = os.environ.get("AIDD_DB_DSN",
                        "postgresql://aidd_app:aidd_app@localhost:55432/aidd")
PIPELINE_VERSION = "five-stage-v1.0.0"


# =====================================================================
# 通用数据结构
# =====================================================================

@dataclass
class Compound:
    inchikey: str
    smiles: str
    name: str
    compound_class: str
    observed: dict = field(default_factory=dict)   # 微量小试实测值（可空）


@dataclass
class StageVerdict:
    stage_no: int
    stage_code: str
    compound_key: str
    verdict: str                    # pass / fail / hold
    score: float
    passed_rules: list
    failed_rules: list
    detail: dict
    model_code: str = ""
    model_version: str = ""


class ScreeningStage(ABC):
    """每级筛选的统一接口 —— 独立可测试的核心抽象。"""
    stage_no: int = 0
    stage_code: str = ""

    @abstractmethod
    def run(self, compound: Compound) -> StageVerdict: ...

    @staticmethod
    def _verdict(passed: bool, failed_rules: list) -> str:
        if not failed_rules:
            return "pass"
        return "hold" if len(failed_rules) <= 1 else "fail"


# =====================================================================
# Stage 1：AI 虚拟初筛
# =====================================================================

class AIPrescreenStage(ScreeningStage):
    """分子 AI 模型预测（可插拔：
      - 内置代理：RDKit 描述符 + 规则基线模型；
      - 外接：DeepPurpose / ChemBERTa / 自训练 GNN，经 model_fn 注入）。
    模型注册表写 meta（model_code/model_version），保证可回溯。"""
    stage_no = 1
    stage_code = "ai_prescreen"

    def __init__(self, model_fn=None, thresholds: Optional[dict] = None):
        # model_fn(smiles) -> {"score": 0~1, "model_code": ..., "model_version": ...}
        self.model_fn = model_fn or self._baseline_model
        self.thresholds = thresholds or {"min_ai_score": 0.35}

    @staticmethod
    def _baseline_model(smiles: str) -> dict:
        """离线基线：未见真实训练模型时的可复现代理。
        特征：环系复杂度+链长适中度+毒警报缺席 → 分数。"""
        from rdkit import Chem
        from rdkit.Chem import Descriptors, Lipinski
        from rdkit.Chem import rdMolDescriptors
        m = Chem.MolFromSmiles(smiles)
        if m is None:
            return {"score": 0.0, "model_code": "baseline_rdkit",
                    "model_version": "v0"}
        alerts = sum(rdMolDescriptors.CalcNumAtomStereoCenters(m) is not None
                     for _ in [0])  # placeholder，真实警报用 PAINS/Tox filter
        mw = Descriptors.MolWt(m)
        rings = Lipinski.RingCount(m)
        size_ok = 1.0 if 200 <= mw <= 900 else 0.4
        ring_ok = 1.0 if rings >= 1 else 0.5
        score = round(min(1.0, 0.5 * size_ok + 0.35 * ring_ok
                          + 0.15 * (1 - min(1, alerts))), 4)
        return {"score": score, "model_code": "baseline_rdkit",
                "model_version": "v0"}

    def run(self, compound: Compound) -> StageVerdict:
        out = self.model_fn(compound.smiles)
        passed, failed = [], []
        if out["score"] >= self.thresholds["min_ai_score"]:
            passed.append("min_ai_score")
        else:
            failed.append("min_ai_score")
        return StageVerdict(
            self.stage_no, self.stage_code, compound.inchikey,
            self._verdict(bool(passed), failed), out["score"],
            passed, failed,
            detail={"ai_score": out["score"],
                    "reconciliation": {
                        "predicted": out["score"],
                        "observed": compound.observed.get("ai_proxy_score"),
                    }},
            model_code=out.get("model_code", ""),
            model_version=out.get("model_version", ""))


# =====================================================================
# Stage 2：理化功能中筛（含「预测 vs 微量小试」吻合度）
# =====================================================================

class PhyschemStage(ScreeningStage):
    """RDKit 计算理化性质 + 功能条目（油相溶解、乳化潜力等），
    若 compound.observed 提供微量小试实测值，则计算吻合度（相对误差）
    并作为 gate —— 吻合度差 → hold（模型需再校准）。"""
    stage_no = 2
    stage_code = "physchem_screen"

    RULES = {
        "max_mw": 1200.0,
        "logp_range": (-2.0, 12.0),
        "max_tpsa": 250.0,
        "max_pred_vs_obs_rel_err": 0.30,   # 预测/实测相对误差上限
    }

    def run(self, compound: Compound) -> StageVerdict:
        from rdkit import Chem
        from rdkit.Chem import Descriptors, Lipinski
        m = Chem.MolFromSmiles(compound.smiles)
        if m is None:
            return StageVerdict(self.stage_no, self.stage_code,
                                compound.inchikey, "fail", 0.0,
                                [], ["smiles_unparseable"], {})
        props = {
            "mw": Descriptors.MolWt(m),
            "logp": Descriptors.MolLogP(m),
            "tpsa": Descriptors.TPSA(m),
            "hbd": Lipinski.NumHDonors(m),
            "hba": Lipinski.NumHAcceptors(m),
            "rot_bonds": Lipinski.NumRotatableBonds(m),
        }
        passed, failed = [], []
        if props["mw"] <= self.RULES["max_mw"]:
            passed.append("max_mw")
        else:
            failed.append("max_mw")
        lo, hi = self.RULES["logp_range"]
        (passed if lo <= props["logp"] <= hi else failed).append("logp_range")
        (passed if props["tpsa"] <= self.RULES["max_tpsa"]
         else failed).append("max_tpsa")

        # 预测 vs 微量小试吻合度（例如实测 logP / 油溶解度）
        reconciliation = {}
        for endpoint, obs in compound.observed.items():
            if endpoint in props and obs:
                rel_err = abs(props[endpoint] - obs) / max(abs(obs), 1e-9)
                reconciliation[endpoint] = {
                    "predicted": props[endpoint], "observed": obs,
                    "rel_err": round(rel_err, 4)}
                if rel_err > self.RULES["max_pred_vs_obs_rel_err"]:
                    failed.append(f"recon_{endpoint}_err")
                else:
                    passed.append(f"recon_{endpoint}_err")

        score = round(len(passed) / max(1, len(passed) + len(failed)), 4)
        return StageVerdict(self.stage_no, self.stage_code,
                            compound.inchikey,
                            self._verdict(bool(passed), failed), score,
                            passed, failed,
                            detail={"props": props,
                                    "reconciliation": reconciliation},
                            model_code="rdkit_descriptors",
                            model_version="2026.09.2")


# =====================================================================
# Stage 3：生物安全与配伍深筛（委托 risk_deep_eval）
# =====================================================================

class BiosafetyCompatStage(ScreeningStage):
    stage_no = 3
    stage_code = "biosafety_compat"

    def __init__(self, excipient_pool: list[str]):
        # excipient_pool: 可配伍辅料的 InChIKey 列表
        self.excipient_pool = excipient_pool

    def run(self, compound: Compound) -> StageVerdict:
        """调用 risk_deep_eval.evaluate_compatibility + admet gate；
        高风险 endpoint（hERG/DILI 高概率）→ fail。"""
        from risk_deep_eval import (admet_profile, evaluate_compatibility,
                                    IMPURITY_EXCITABLE_CLASSES)
        adm = admet_profile(compound.smiles, compound.inchikey)
        hard_fail = [k for k in ("hERG", "DILI", "AMES")
                     if adm.get(k, {}).get("risk_flag") == "high"]
        compat = []
        for exc in self.excipient_pool:
            compat.extend(evaluate_compatibility(compound.inchikey, exc))
        max_risk = max((c["risk_score"] for c in compat), default=0.0)
        passed, failed = [], []
        if not hard_fail:
            passed.append("admet_hard_endpoints")
        else:
            failed.extend(hard_fail)
        if max_risk < 0.6:
            passed.append("compat_risk_max")
        else:
            failed.append("compat_risk_max")
        score = round(1 - max_risk, 4)
        return StageVerdict(self.stage_no, self.stage_code,
                            compound.inchikey,
                            self._verdict(bool(passed), failed), score,
                            passed, failed,
                            detail={"admet": {k: v.get("risk_flag")
                                              for k, v in adm.items()},
                                    "compat_max_risk": max_risk},
                            model_code="risk_deep_eval",
                            model_version="v1")


# =====================================================================
# Stage 4：建模分析（QSPR / MD 复核 + 不确定度）
# =====================================================================

class ModelingAnalysisStage(ScreeningStage):
    stage_no = 4
    stage_code = "modeling_analysis"

    def run(self, compound: Compound) -> StageVerdict:
        """集成建模：对 Stage1/2 的多次预测取均值±不确定度；
        不确定度过大（各模型分歧）→ hold。外接 MD（GROMACS/MOE）时
        经 polymer_sim.moe_docking / 自定义 runner 注入。"""
        import psycopg2
        with psycopg2.connect(DB_DSN) as conn, conn.cursor() as cur:
            cur.execute("""
                SELECT score FROM ads.stage_result
                WHERE compound_key = %s AND stage_no IN (1,2)
                  AND verdict = 'pass'
            """, (compound.inchikey,))
            scores = [float(r[0]) for r in cur.fetchall()]
        if not scores:
            return StageVerdict(self.stage_no, self.stage_code,
                                compound.inchikey, "hold", 0.0,
                                [], ["no_upstream_pass"],
                                {"reason": "上游无 pass 记录"})
        mean = sum(scores) / len(scores)
        spread = (max(scores) - min(scores)) if len(scores) > 1 else 0.0
        passed, failed = [], []
        if spread <= 0.25:
            passed.append("model_consensus")
        else:
            failed.append("model_consensus")
        return StageVerdict(self.stage_no, self.stage_code,
                            compound.inchikey,
                            self._verdict(bool(passed), failed),
                            round(mean, 4), passed, failed,
                            detail={"mean_score": mean, "spread": spread,
                                    "n_models": len(scores)},
                            model_code="ensemble_consensus",
                            model_version="v1")


# =====================================================================
# Stage 5：生产放大评估
# =====================================================================

class ScaleupStage(ScreeningStage):
    stage_no = 5
    stage_code = "scaleup_assessment"

    RULES = {
        "max_viscosity_cP": 50.0,          # 可注射/可灌装
        "max_emulsification_energy": 2.5,  # 相对 kWh/L 归一
        "min_batch_consistency": 0.85,     # 批间一致性（实测或模拟）
    }

    def run(self, compound: Compound) -> StageVerdict:
        """指标来源：
          - 粘度：观测值 compound.observed['viscosity_cP']，缺省用
            RDKit 描述符 + 链长经验模型预测；
          - 乳化能耗 / 一致性：小试数据优先，缺省标记 hold。
        所有 'hold' 项都给出补测清单 → 生产闭环。"""
        import psycopg2
        with psycopg2.connect(DB_DSN) as conn, conn.cursor() as cur:
            cur.execute("""
                SELECT score_value FROM dwd.fact_polymer_interaction
                WHERE partner_inchikey = %s
                  AND assay_kind = 'crystallization_inhibition'
                ORDER BY score_value DESC LIMIT 1
            """, (compound.inchikey,))
            row = cur.fetchone()
        ci_score = float(row[0]) if row else 0.0

        obs = compound.observed
        passed, failed, todo = [], [], []
        visc = obs.get("viscosity_cP")
        if visc is not None:
            (passed if visc <= self.RULES["max_viscosity_cP"]
             else failed).append("max_viscosity_cP")
        else:
            todo.append("viscosity_cP")
        energy = obs.get("emulsification_energy")
        if energy is not None:
            (passed if energy <= self.RULES["max_emulsification_energy"]
             else failed).append("max_emulsification_energy")
        else:
            todo.append("emulsification_energy")
        consistency = obs.get("batch_consistency")
        if consistency is not None:
            (passed if consistency >= self.RULES["min_batch_consistency"]
             else failed).append("min_batch_consistency")
        else:
            todo.append("batch_consistency")
        (passed if ci_score >= 0.5 else failed).append("crystallization_inhibition")

        verdict = "fail" if failed and not passed else \
                  ("hold" if todo or failed else "pass")
        return StageVerdict(self.stage_no, self.stage_code,
                            compound.inchikey, verdict,
                            round(ci_score, 4), passed, failed,
                            detail={"ci_score": ci_score,
                                    "pending_measurements": todo,
                                    "observed": obs},
                            model_code="scaleup_heuristics",
                            model_version="v1")


# =====================================================================
# 流水线编排 + 回溯
# =====================================================================

STAGES: list[ScreeningStage] = [
    AIPrescreenStage(),
    PhyschemStage(),
    BiosafetyCompatStage(excipient_pool=[]),   # 运行时注入辅料池
    ModelingAnalysisStage(),
    ScaleupStage(),
]


def create_run(config: dict) -> str:
    import psycopg2
    run_id = f"RUN-{uuid.uuid4().hex[:12].upper()}"
    with psycopg2.connect(DB_DSN) as conn, conn.cursor() as cur:
        cur.execute("""
            INSERT INTO ads.pipeline_run (run_id, pipeline_version, config)
            VALUES (%s, %s, %s)
        """, (run_id, PIPELINE_VERSION, json.dumps(config, ensure_ascii=False)))
        # lineage 落账
        cur.execute("""
            INSERT INTO meta.lineage_event
                (event_type, object_schema, object_name, detail)
            VALUES ('pipeline_run_started', 'ads', 'pipeline_run', %s)
        """, (json.dumps({"run_id": run_id}),))
        conn.commit()
    return run_id


def persist_stage_result(run_id: str, v: StageVerdict) -> None:
    import psycopg2
    with psycopg2.connect(DB_DSN) as conn, conn.cursor() as cur:
        cur.execute("""
            INSERT INTO ads.stage_result
                (run_id, stage_no, stage_code, compound_key, verdict, score,
                 passed_rules, failed_rules, detail, model_code, model_version)
            VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
            ON CONFLICT (run_id, stage_no, compound_key)
            DO UPDATE SET verdict = EXCLUDED.verdict,
                          score = EXCLUDED.score,
                          passed_rules = EXCLUDED.passed_rules,
                          failed_rules = EXCLUDED.failed_rules,
                          detail = EXCLUDED.detail,
                          created_at = now()
        """, (run_id, v.stage_no, v.stage_code, v.compound_key, v.verdict,
              v.score, json.dumps(v.passed_rules), json.dumps(v.failed_rules),
              json.dumps(v.detail, ensure_ascii=False),
              v.model_code, v.model_version))
        conn.commit()


def finish_run(run_id: str, status: str = "completed") -> None:
    import psycopg2
    with psycopg2.connect(DB_DSN) as conn, conn.cursor() as cur:
        cur.execute("""
            UPDATE ads.pipeline_run
            SET status = %s, finished_at = now()
            WHERE run_id = %s
        """, (status, run_id))
        conn.commit()


def run_pipeline(compounds: list[Compound],
                 excipient_pool: list[str],
                 stages: Optional[list[ScreeningStage]] = None) -> str:
    """全流程执行；异常时标记 run 失败后继续抛出（可回溯）。"""
    stages = stages or STAGES
    # 注入辅料池到 Stage 3
    for st in stages:
        if isinstance(st, BiosafetyCompatStage):
            st.excipient_pool = excipient_pool
    run_id = create_run({"n_compounds": len(compounds),
                         "n_excipients": len(excipient_pool)})
    try:
        for comp in compounds:
            # 短路策略：fail 即停该分子后续级别（hold 继续）
            stopped = False
            for st in stages:
                if stopped:
                    break
                v = st.run(comp)
                persist_stage_result(run_id, v)
                if v.verdict == "fail":
                    stopped = True
        finish_run(run_id, "completed")
    except Exception:
        finish_run(run_id, "failed")
        raise
    return run_id


def main() -> None:
    import psycopg2
    with psycopg2.connect(DB_DSN) as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT inchikey::text,
                   COALESCE(smiles_isomeric, smiles_canonical),
                   COALESCE(pref_name, ''),
                   compound_class
            FROM dwd.dim_compound
            WHERE structure_quality = 'valid'
              AND COALESCE(smiles_isomeric, smiles_canonical) IS NOT NULL
        """)
        rows = cur.fetchall()
        cur.execute("""
            SELECT DISTINCT inchikey::text FROM dwd.dim_compound
            WHERE compound_class IN ('lipid','small_molecule')
            LIMIT 50
        """)
        exc_pool = [r[0] for r in cur.fetchall()]
    compounds = [Compound(ik, smi, nm, cls) for ik, smi, nm, cls in rows]
    run_id = run_pipeline(compounds, exc_pool)
    print(f"[pipeline] run_id={run_id} compounds={len(compounds)}")


if __name__ == "__main__":
    main()
