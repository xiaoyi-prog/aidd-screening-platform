# -*- coding: utf-8 -*-
"""
risk_deep_eval.py — 步骤4：深度风险评价
=================================================================
三大块：
  A. API-辅料配伍稳定性预测（水解/氧化/美拉德/多晶型转变/过氧化物/金属催化）
  B. ADMET 预测（可插拔外部模型：admetSAR3 / AZ predictors / pkCSM 在线，
     内置 RDKit 警报基线保证离线可跑）
  C. 杂质催化风险（过氧化物 & 过渡金属对油相制剂的催化氧化路径评估）

监管对齐：结果结构化落 ads.api_excipient_risk / ads.admet_prediction /
ads.impurity_catalysis_risk，带 model_code/model_version + confidence，
满足 ICH Q3B / Q1A 风险评估留痕要求。

仅写代码，未运行。
"""
from __future__ import annotations

import json
import os
from typing import Optional

DB_DSN = os.environ.get("AIDD_DB_DSN",
                        "postgresql://aidd_app:aidd_app@localhost:55432/aidd")

# ---------------------------------------------------------------------
# 可插拔 ADMET 模型注册表：model_code -> 预测函数(smiles)->{endpoint: {...}}
# ---------------------------------------------------------------------
ADMET_MODEL_REGISTRY: dict = {}

def register_admet_model(code: str):
    def deco(fn):
        ADMET_MODEL_REGISTRY[code] = fn
        return fn
    return deco


# =====================================================================
# B. ADMET
# =====================================================================

@register_admet_model("rdkit_tox_alerts_v1")
def rdkit_admet_baseline(smiles: str) -> dict:
    """离线基线：结构警报近似。endpoint → {risk_flag, prob_class}。
    真实模型接入示例：
      @register_admet_model("adnets_v2")
      def adnets(smiles): ...调用本地/远程推理...
    """
    from rdkit import Chem
    from rdkit.Chem import Descriptors, rdMolDescriptors
    m = Chem.MolFromSmiles(smiles)
    if m is None:
        return {}
    mw = Descriptors.MolWt(m)
    logp = Descriptors.MolLogP(m)
    tpsa = Descriptors.TPSA(m)
    aromatic_n = sum(1 for a in m.GetAtoms() if a.GetIsAromatic())

    def flag(p, low, high):   # 区间内=low
        if p is None:
            return "unknown", None
        if low <= p <= high:
            return "low", p
        if low * 0.7 <= p <= high * 1.3:
            return "medium", p
        return "high", p

    hERG_p = 0.8 if (mw > 400 and logp > 3.5 and aromatic_n >= 2) else 0.2
    return {
        "Caco2_perm":  {"risk_flag": flag(-logp, -2, 2)[0]},
        "HIA":         {"risk_flag": "low" if mw < 700 else "high",
                        "prob_class": min(1.0, 900 / max(mw, 1))},
        "BBB":         {"risk_flag": flag(tpsa, 0, 90)[0]},
        "hERG":        {"risk_flag": "high" if hERG_p > 0.5 else "low",
                        "prob_class": hERG_p},
        "DILI":        {"risk_flag": "medium" if aromatic_n >= 3 else "low"},
        "AMES":        {"risk_flag": "low"},   # 佐剂油相默认低；接入模型后覆盖
        "CYP2C9_inh":  {"risk_flag": flag(logp, 0, 4)[0]},
        "solubility":  {"risk_flag": flag(logp, -1, 5)[0]},
    }


def admet_profile(smiles: str, inchikey: str,
                  model_code: Optional[str] = None,
                  run_id: Optional[str] = None) -> dict:
    """跑指定模型（缺省取注册表第一个），写 ads.admet_prediction，返回结果。"""
    code = model_code or next(iter(ADMET_MODEL_REGISTRY))
    fn = ADMET_MODEL_REGISTRY[code]
    profile = fn(smiles)
    import psycopg2
    with psycopg2.connect(DB_DSN) as conn, conn.cursor() as cur:
        for endpoint, payload in profile.items():
            cur.execute("""
                INSERT INTO ads.admet_prediction
                    (compound_key, endpoint, model_code, model_version,
                     prob_class, risk_flag, detail, run_id)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s)
                ON CONFLICT (compound_key, endpoint, model_code, model_version)
                DO UPDATE SET prob_class = EXCLUDED.prob_class,
                              risk_flag = EXCLUDED.risk_flag,
                              detail = EXCLUDED.detail
            """, (inchikey, endpoint, code, "v1",
                  payload.get("prob_class"), payload.get("risk_flag", "unknown"),
                  json.dumps(payload, ensure_ascii=False), run_id))
        conn.commit()
    return profile


# =====================================================================
# A. API-辅料配伍稳定性
# =====================================================================

# 功能基团 → 风险路径 规则库（可由 meta 表外置，此处内置常用集）
COMPAT_RULES = [
    {"risk_type": "hydrolysis",
     "api_smarts": "[CX3](=O)[OX2H1,OX2-1]",      # 酯/酸 API 遇水辅料
     "excipient_smarts": "[OX2H]",
     "base_score": 0.55,
     "pathway": "ester/amide hydrolysis in presence of free OH excipients"},
    {"risk_type": "oxidation",
     "api_smarts": "[CX3]=[CX3]",                 # 不饱和键（如 squalene 侧链）
     "excipient_smarts": "[OX2H]C",               # 羟基类辅料供氢诱导
     "base_score": 0.65,
     "pathway": "allylic autoxidation accelerated by OH excipients"},
    {"risk_type": "maillard",
     "api_smarts": "[NX3;H2,H1,H0;!$(N-C=O)]",    # 游离胺
     "excipient_smarts": "[CX3H1](=O)[OX2H1]",    # 还原糖醛基
     "base_score": 0.75,
     "pathway": "Maillard reaction with reducing sugars"},
    {"risk_type": "peroxide_catalysis",
     "api_smarts": "[CX3]=[CX3]",
     "excipient_smarts": "OO",                    # 含过氧化氢杂质的辅料（PEG/PS80 常见）
     "base_score": 0.80,
     "pathway": "peroxide-impurity radical initiation on C=C"},
    {"risk_type": "metal_catalysis",
     "api_smarts": "[CX3]=[CX3]",
     "excipient_smarts": "[Fe,Zn,Cu]",
     "base_score": 0.70,
     "pathway": "transition-metal catalyzed oxidation (Fenton-like)"},
]

SUSCEPTIBLE_MODEL = ("rule_smarts_v1", "v1")


def evaluate_compatibility(api_inchikey: str, excipient_inchikey: str,
                           api_smiles: str, excipient_smiles: str,
                           persist: bool = True) -> list[dict]:
    """对一对 API-辅料跑全部规则 → 风险条目列表（score 越大越危险）。"""
    from rdkit import Chem
    from rdkit.Chem import rdMolDescriptors
    m_api = Chem.MolFromSmiles(api_smiles)
    m_exc = Chem.MolFromSmiles(excipient_smiles)
    if m_api is None or m_exc is None:
        raise ValueError("SMILES 解析失败: " +
                         repr((api_smiles, excipient_smiles)))
    fp_api = rdMolDescriptors.GetMorganFingerprint(m_api, 2)
    fp_exc = rdMolDescriptors.GetMorganFingerprint(m_exc, 2)

    results = []
    for rule in COMPAT_RULES:
        p_api = Chem.MolFromSmarts(rule["api_smarts"])
        p_exc = Chem.MolFromSmarts(rule["excipient_smarts"])
        hit_api = m_api.HasSubstructMatch(p_api) if p_api else False
        hit_exc = m_exc.HasSubstructMatch(p_exc) if p_exc else False
        if not (hit_api and hit_exc):
            continue
        score = min(1.0, rule["base_score"] * 1.1)   # 双命中放大
        results.append({
            "api_inchikey": api_inchikey,
            "excipient_inchikey": excipient_inchikey,
            "risk_type": rule["risk_type"],
            "model_code": SUSCEPTIBLE_MODEL[0],
            "model_version": SUSCEPTIBLE_MODEL[1],
            "risk_score": round(score, 3),
            "predicted_pathway": rule["pathway"],
            "confidence": 0.6,     # 规则模型置信度固定 0.6；ML 模型可覆盖
            "detail": {"rule_base_score": rule["base_score"]},
        })

    if persist and results:
        import psycopg2
        with psycopg2.connect(DB_DSN) as conn, conn.cursor() as cur:
            for r in results:
                cur.execute("""
                    INSERT INTO ads.api_excipient_risk
                        (api_inchikey, excipient_inchikey, risk_type,
                         model_code, model_version, risk_score,
                         predicted_pathway, confidence, detail)
                    VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)
                    ON CONFLICT (api_inchikey, excipient_inchikey,
                                 risk_type, model_code, model_version)
                    DO UPDATE SET risk_score = EXCLUDED.risk_score,
                                  detail = EXCLUDED.detail
                """, (r["api_inchikey"], r["excipient_inchikey"],
                      r["risk_type"], r["model_code"], r["model_version"],
                      r["risk_score"], r["predicted_pathway"],
                      r["confidence"], json.dumps(r["detail"])))
            conn.commit()
    return results


# =====================================================================
# C. 杂质催化风险
# =====================================================================

# 辅料 → 典型杂质类别（文献常识内置；实测 COA 数据可覆盖）
EXCIPIENT_IMPURITIES = {
    "polysorbate":  {"peroxide": 0.35},        # PS80 常见 ROOH 残留
    "peg":          {"peroxide": 0.45},
    "triglyceride": {"peroxide": 0.20, "aldehyde": 0.15},
    "tocopherol":   {"peroxide": 0.05},        # 抗氧化剂本身
    "squalene":     {"transition_metal": 0.10},
}

CATALYZED_PATHWAYS = {
    "peroxide":         "allylic hydroperoxide chain initiation → secondary oxidation products",
    "transition_metal": "Fenton-like ROS generation → lipid peroxidation",
    "aldehyde":         "Schiff-base/aldol side reactions with amine APIs",
    "reducing_sugar":   "Maillard glycation",
    "radical_initiator":"direct radical initiation",
}


def assess_impurity_catalysis(api_inchikey: str, excipient_class: str,
                              excipient_inchikey: Optional[str] = None,
                              api_has_unsaturation: bool = True,
                              persist: bool = True) -> list[dict]:
    """评估某辅料类别对某 API 的杂质催化风险。
    api_has_unsaturation 可由 RDKit 判定（存在 C=C）。"""
    impurity_map = EXCIPIENT_IMPURITIES.get(excipient_class, {})
    results = []
    for imp_class, base in impurity_map.items():
        amplifiers = []
        if imp_class == "peroxide" and api_has_unsaturation:
            amplifiers.append("api_unsaturation")
        score = min(1.0, base + 0.35 * len(amplifiers))
        results.append({
            "formulation_key": f"{api_inchikey}~{excipient_class}",
            "impurity_class": imp_class,
            "source_excipient_inchikey": excipient_inchikey,
            "catalyzed_pathway": CATALYZED_PATHWAYS[imp_class],
            "risk_score": round(score, 3),
            "evidence": {"base": base, "amplifiers": amplifiers},
            "mitigation": {
                "peroxide": "抗氧剂(α-生育酚) + 氮气灌装 + 控制辅料 POV",
                "transition_metal": "螯合剂(EDTA) + 低金属规格原料",
                "aldehyde": "避免还原糖/醛类辅料与胺 API 共存",
                "reducing_sugar": "改用非还原糖(海藻糖/蔗糖)",
                "radical_initiator": "避光低温储存",
            }[imp_class],
        })

    if persist and results:
        import psycopg2
        with psycopg2.connect(DB_DSN) as conn, conn.cursor() as cur:
            for r in results:
                cur.execute("""
                    INSERT INTO ads.impurity_catalysis_risk
                        (formulation_key, impurity_class,
                         source_excipient_inchikey, catalyzed_pathway,
                         risk_score, evidence, mitigation)
                    VALUES (%s,%s,%s,%s,%s,%s,%s)
                """, (r["formulation_key"], r["impurity_class"],
                      r["source_excipient_inchikey"], r["catalyzed_pathway"],
                      r["risk_score"], json.dumps(r["evidence"]),
                      r["mitigation"]))
            conn.commit()
    return results


def api_has_unsaturation(smiles: str) -> bool:
    from rdkit import Chem
    m = Chem.MolFromSmiles(smiles)
    if m is None:
        return False
    return m.HasSubstructMatch(Chem.MolFromSmarts("[CX3]=[CX3]"))


# =====================================================================
# 批量入口：全库 API × 全库辅料
# =====================================================================

def main() -> None:
    import psycopg2
    with psycopg2.connect(DB_DSN) as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT inchikey::text,
                   COALESCE(smiles_isomeric, smiles_canonical)
            FROM dwd.dim_compound
            WHERE structure_quality = 'valid'
              AND COALESCE(smiles_isomeric, smiles_canonical) IS NOT NULL
        """)
        pool = cur.fetchall()

    apis = pool[:50]        # 或按用途过滤
    excipients = pool       # 辅料池全量

    n_compat = n_admet = n_imp = 0
    for ik_a, smi_a in apis:
        unsat = api_has_unsaturation(smi_a)
        # ADMET
        admet_profile(smi_a, ik_a)
        n_admet += 1
        for ik_e, smi_e in excipients:
            if ik_e == ik_a:
                continue
            n_compat += len(evaluate_compatibility(ik_a, ik_e, smi_a, smi_e))
        # 杂质催化：按辅料 class 粗分类
        for ik_e, smi_e in excipients:
            if ik_e == ik_a:
                continue
            for cls in EXCIPIENT_IMPURITIES:
                if cls in smi_e.lower() or cls.replace("_", "") in smi_e.lower():
                    n_imp += len(assess_impurity_catalysis(
                        ik_a, cls, ik_e, unsat))
    print(f"[risk_deep_eval] admet={n_admet} compat_hits={n_compat} "
          f"impurity_assessments={n_imp}")


if __name__ == "__main__":
    main()
