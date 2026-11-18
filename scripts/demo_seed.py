#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
demo_seed.py —— 冒烟测试数据装载（可重复执行、幂等）

作用：
    用 RDKit 真实解析一批常见药用辅料的 SMILES，走完 ODS → DWD → ADS 的
    最小链路，验证三层表结构、外键、唯一键、评分表与血缘表都工作正常。

重要声明：
    * 结构、InChIKey、分子式与 RDKit 描述符均为**真实计算值**。
    * 熔点为文献常见值，但仅为演示，method 标记为 DEMO_SEED，正式数据请由
      ODS 批次（ods.pubchem_property / 内部实验）覆盖。
    * 一二级的分数是"规则启发式"，不是 AI 模型输出；AI 模型接入是后续步骤。
    * 全部数据可一键清除：见本文件末尾 cleanup()，或用 bootstrap.sh --reset。

用法：
    python db/scripts/demo_seed.py
    python db/scripts/demo_seed.py --clean
"""
from __future__ import annotations

import argparse
import hashlib
import os
import sys
from datetime import datetime

import psycopg
from psycopg.types.json import Jsonb
from rdkit import Chem, RDLogger
from rdkit.Chem import Crippen, Descriptors, inchi, rdMolDescriptors

RDLogger.DisableLog("rdApp.*")

# ---------------------------------------------------------------------------
# 候选集：名称 / SMILES / 功能 / 文献熔点（DEMO）
# ---------------------------------------------------------------------------
COMPOUNDS = [
    ("丙三醇",       "Glycerol",             "OCC(O)CO",                                            ["HUMECTANT", "SOLUBILIZER", "TONICITY"],       17.8),
    ("丙二醇",       "Propylene glycol",     "CC(O)CO",                                             ["HUMECTANT", "SOLUBILIZER"],                   -59.0),
    ("D-甘露醇",     "D-Mannitol",           "OC[C@@H](O)[C@@H](O)[C@H](O)[C@H](O)CO",               ["FILLER", "CRYOPROTECTANT", "TONICITY"],       168.0),
    ("D-山梨醇",     "D-Sorbitol",           "OC[C@H](O)[C@@H](O)[C@H](O)[C@H](O)CO",               ["FILLER", "HUMECTANT"],                        95.0),
    ("木糖醇",       "Xylitol",              "OC[C@@H](O)[C@H](O)[C@@H](O)CO",                      ["FILLER", "TASTE_MASK"],                       94.0),
    ("蔗糖",         "Sucrose",              "OC[C@H]1O[C@@](CO)(O[C@H]2O[C@H](CO)[C@@H](O)[C@H](O)[C@H]2O)[C@@H](O)[C@@H]1O",
                                                                                                    ["FILLER", "TASTE_MASK"],                       186.0),
    ("乳糖",         "Lactose",              "OC[C@H]1O[C@@H](O[C@H]2[C@H](O)[C@@H](O)[C@@H](O)O[C@@H]2CO)[C@H](O)[C@@H](O)[C@H]1O",
                                                                                                    ["FILLER"],                                     202.0),
    ("硬脂酸镁",     "Magnesium stearate",   "CCCCCCCCCCCCCCCCCC(=O)[O-].CCCCCCCCCCCCCCCCCC(=O)[O-].[Mg+2]",
                                                                                                    ["LUBRICANT"],                                  88.0),
    ("硬脂酸",       "Stearic acid",         "CCCCCCCCCCCCCCCCCC(=O)O",                             ["LUBRICANT", "BINDER"],                        69.0),
    ("十二烷基硫酸钠","Sodium lauryl sulfate","CCCCCCCCCCCCOS(=O)(=O)[O-].[Na+]",                    ["SOLUBILIZER", "EMULSIFIER"],                  204.0),
    ("枸橼酸",       "Citric acid",          "OC(=O)CC(O)(CC(=O)O)C(=O)O",                          ["BUFFER", "ANTIOXIDANT"],                      153.0),
    ("酒石酸",       "Tartaric acid",        "OC(=O)[C@H](O)[C@@H](O)C(=O)O",                       ["BUFFER"],                                     171.0),
    ("氯化钠",       "Sodium chloride",      "[Na+].[Cl-]",                                         ["TONICITY"],                                   801.0),
    ("苯甲醇",       "Benzyl alcohol",       "OCc1ccccc1",                                          ["PRESERVATIVE"],                               -15.0),
    ("尼泊金甲酯",   "Methylparaben",        "COC(=O)c1ccc(O)cc1",                                  ["PRESERVATIVE"],                               131.0),
    ("尼泊金丙酯",   "Propylparaben",        "CCCOC(=O)c1ccc(O)cc1",                                ["PRESERVATIVE"],                                96.0),
    ("二丁基羟基甲苯","BHT",                 "Cc1cc(C(C)(C)C)c(O)c(C(C)(C)C)c1",                    ["ANTIOXIDANT"],                                 70.0),
    ("阿斯巴甜",     "Aspartame",            "COC(=O)[C@H](Cc1ccccc1)NC(=O)[C@@H](N)CC(=O)O",       ["TASTE_MASK"],                                 246.0),
    ("薄荷醇",       "Menthol",              "CC(C)[C@@H]1CC[C@@H](C)C[C@H]1O",                     ["TASTE_MASK"],                                  42.0),
    ("苯甲酸钠",     "Sodium benzoate",      "[Na+].[O-]C(=O)c1ccccc1",                             ["PRESERVATIVE"],                               410.0),
    ("碳酸钙",       "Calcium carbonate",    "[Ca+2].[O-]C([O-])=O",                                ["FILLER"],                                     825.0),
]

RUN_CODE = "RUN-DEMO-FILLER-001"
BATCH_LABEL = "demo_seed_2026Q4"

# 一级硬阈值（演示用：辅料空间的宽松边界）
STAGE1_HARD = [("MW", "<=", 1200), ("LOGP", "<=", 6), ("TPSA", "<=", 320),
               ("HBD", "<=", 10), ("HBA", "<=", 15), ("ROT_BONDS", "<=", 15)]


def conninfo() -> str:
    return (f"host={os.getenv('PGHOST', '127.0.0.1')} port={os.getenv('PGPORT', '55432')} "
            f"dbname={os.getenv('PGDATABASE', 'aidd')} user={os.getenv('PGUSER', 'postgres')} "
            f"password={os.getenv('PGPASSWORD', '')}")


def compute(smiles: str) -> dict:
    mol = Chem.MolFromSmiles(smiles)
    if mol is None:
        raise ValueError(f"SMILES 解析失败: {smiles}")
    logp = Crippen.MolLogP(mol)
    mw = Descriptors.MolWt(mol)
    rot = rdMolDescriptors.CalcNumRotatableBonds(mol)
    arom = rdMolDescriptors.CalcNumAromaticRings(mol)
    return {
        "smiles_canonical": Chem.MolToSmiles(mol),
        "smiles_isomeric": Chem.MolToSmiles(mol, isomericSmiles=True),
        "inchi": inchi.MolToInchi(mol),
        "inchikey": inchi.MolToInchiKey(mol),
        "formula": rdMolDescriptors.CalcMolFormula(mol),
        "mw": round(mw, 3),
        "logp": round(logp, 3),
        "tpsa": round(rdMolDescriptors.CalcTPSA(mol), 3),
        "hbd": rdMolDescriptors.CalcNumHBD(mol),
        "hba": rdMolDescriptors.CalcNumHBA(mol),
        "rot": rot,
        "rings": rdMolDescriptors.CalcNumRings(mol),
        "heavy": mol.GetNumHeavyAtoms(),
        "charge": Chem.GetFormalCharge(mol),
        # Delaney(2004) ESOL 经验式：logS = 0.16 - 0.63*clogp - 0.0062*MW + 0.066*RB - 0.74*AP
        "logs": round(0.16 - 0.63 * logp - 0.0062 * mw + 0.066 * rot - 0.74 * arom, 3),
    }


def classify(name_en: str, smi: str) -> str:
    if name_en in ("Sodium chloride", "Calcium carbonate"):
        return "inorganic"
    if "." in smi and ("+" in smi or "-" in smi):
        return "small_molecule"
    return "small_molecule"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--clean", action="store_true", help="清除演示数据")
    args = ap.parse_args()

    with psycopg.connect(conninfo(), autocommit=False) as conn, conn.cursor() as cur:
        if args.clean:
            return cleanup(cur, conn)

        print("→ 创建抓取批次 ...")
        cur.execute("""
            INSERT INTO meta.fetch_batch (source_code, snapshot_label, source_release, request_params,
                                          fetch_started_at, fetch_finished_at, record_count, status, notes)
            VALUES ('PUBCHEM', %s, 'demo', %s, now(), now(), %s, 'success',
                    'RDKit 本地生成的结构与描述符，用于建库冒烟测试')
            ON CONFLICT DO NOTHING
            RETURNING batch_id
        """, (BATCH_LABEL, Jsonb({"scope": "excipient_smoke_test", "n": len(COMPOUNDS)}), len(COMPOUNDS)))
        row = cur.fetchone()
        if row:
            batch_id = row[0]
        else:
            cur.execute("SELECT batch_id FROM meta.fetch_batch WHERE snapshot_label = %s", (BATCH_LABEL,))
            batch_id = cur.fetchone()[0]
        print(f"  batch_id = {batch_id}")

        # ------------------------------------------------------------------
        # ODS + DWD
        # ------------------------------------------------------------------
        print("→ 装载分子（ODS → DWD）...")
        loaded = []
        for idx, (cn, en, smi, funcs, mp) in enumerate(COMPOUNDS, start=1):
            d = compute(smi)
            cid = 900000 + idx           # 演示用占位 CID，正式批次由 PubChem 覆盖
            payload = {
                "source": "demo_seed", "name_cn": cn, "name_en": en, "smiles_input": smi,
                "inchi": d["inchi"], "inchikey": d["inchikey"],
                "descriptors": {k: d[k] for k in ("mw", "logp", "tpsa", "hbd", "hba", "rot", "rings", "heavy", "logs")},
                "note": "结构由 RDKit 实时计算，CID 为演示占位",
            }
            row_hash = hashlib.sha256(str(payload).encode()).hexdigest()

            cur.execute("""
                INSERT INTO ods.pubchem_compound
                    (cid, molecular_formula, molecular_weight, canonical_smiles, isomeric_smiles,
                     inchi, inchikey, iupac_name, charge, heavy_atom_count, batch_id, src_row_hash, raw_payload)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                ON CONFLICT (batch_id, cid) DO NOTHING
            """, (cid, d["formula"], d["mw"], d["smiles_canonical"], d["smiles_isomeric"],
                  d["inchi"], d["inchikey"], en, d["charge"], d["heavy"], batch_id, row_hash, Jsonb(payload)))

            cur.execute("""
                INSERT INTO dwd.dim_compound
                    (inchikey, inchi, smiles_canonical, smiles_isomeric, molecular_formula, molecular_weight,
                     charge, heavy_atom_count, ring_count, compound_class, is_desalted_parent,
                     quality_flags, first_batch_id)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,true,%s,%s)
                ON CONFLICT (inchikey) DO UPDATE
                    SET smiles_canonical = EXCLUDED.smiles_canonical,
                        molecular_weight = EXCLUDED.molecular_weight,
                        updated_at = now()
                RETURNING compound_sk
            """, (d["inchikey"], d["inchi"], d["smiles_canonical"], d["smiles_isomeric"], d["formula"],
                  d["mw"], d["charge"], d["heavy"], d["rings"], classify(en, smi),
                  Jsonb({"demo": True}), batch_id))
            sk = cur.fetchone()[0]

            cur.execute("""
                INSERT INTO dwd.dim_compound_xref (compound_sk, source_system, source_record_id,
                                                   match_rule, match_confidence, batch_id)
                VALUES (%s, 'PUBCHEM', %s, 'inchikey_exact', 1.0, %s)
                ON CONFLICT (source_system, source_record_id) DO NOTHING
            """, (sk, str(cid), batch_id))

            # 计算描述符 → fact_property
            for code, val in (("MW", d["mw"]), ("LOGP", d["logp"]), ("TPSA", d["tpsa"]),
                              ("HBD", d["hbd"]), ("HBA", d["hba"]), ("ROT_BONDS", d["rot"]),
                              ("RING_COUNT", d["rings"]), ("HEAVY_ATOMS", d["heavy"]), ("LOGS", d["logs"])):
                cur.execute("""
                    INSERT INTO dwd.fact_property
                        (compound_sk, property_code, value_type, value_num, unit,
                         method, model_code, model_version, source_system, batch_id)
                    SELECT %s, %s, 'computed', %s, pd.default_unit,
                           'RDKit', 'RDKIT_DESC', '2026.09.2', 'RDKIT', %s
                      FROM ref.property_def pd WHERE pd.property_code = %s
                    ON CONFLICT DO NOTHING
                """, (sk, code, val, batch_id, code))

            # 熔点（文献演示值）
            cur.execute("""
                INSERT INTO dwd.fact_property
                    (compound_sk, property_code, value_type, value_num, unit,
                     method, source_system, batch_id)
                VALUES (%s, 'MELTING_POINT', 'measured', %s, 'degC', 'DEMO_SEED', 'INTERNAL', %s)
                ON CONFLICT DO NOTHING
            """, (sk, mp, batch_id))

            # 功能桥
            for fn in funcs:
                cur.execute("""
                    INSERT INTO dwd.bridge_compound_function
                        (compound_sk, function_code, is_primary, evidence, source_system)
                    VALUES (%s, %s, %s, 'DEMO_SEED 手工标注', 'INTERNAL')
                    ON CONFLICT (compound_sk, function_code) DO NOTHING
                """, (sk, fn, fn == funcs[0]))

            cur.execute("""
                INSERT INTO meta.lineage_event (run_id, layer, entity_type, entity_key, action,
                                                model_code, model_version, params, output_hash)
                VALUES (NULL, 'dwd', 'compound', %s, 'ingest', 'RDKIT_DESC', '2026.09.2', %s, %s)
            """, (d["inchikey"], Jsonb({"batch": str(batch_id), "cid": cid}), row_hash))

            loaded.append({"sk": sk, "name": cn, "funcs": funcs, **d})

        print(f"  已装载 {len(loaded)} 个分子")

        # ------------------------------------------------------------------
        # ADS：一个演示 run，跑一级 + 二级
        # ------------------------------------------------------------------
        print("→ 创建筛选 run 并执行一级/二级 ...")
        cur.execute("""
            INSERT INTO ads.screen_run (run_code, run_name, objective, target_function_code, target_route_code,
                                        funnel_config, model_snapshot, code_version, status, notes)
            VALUES (%s, %s, %s, 'FILLER', 'ORAL', %s, %s, 'demo-0.1.0', 'running',
                    '冒烟测试 run：仅跑一二级，三~五级等待模型服务接入')
            ON CONFLICT (run_code) DO UPDATE SET status = 'running' RETURNING run_id
        """, (RUN_CODE, "演示：口服填充剂候选初筛",
              "验证三层表结构可支撑五级漏斗，不产出真实业务结论",
              Jsonb({"stage1": {"hard_filters": [f"{p}{o}{v}" for p, o, v in STAGE1_HARD]},
                     "stage2": {"min_spec_match_rate": 0.7}}),
              Jsonb({"RDKIT_DESC": "2026.09.2"})))
        run_id = cur.fetchone()[0]

        for stage_no, thresholds in (
                (1, {"hard_filters": {f"{p}": v for p, _, v in STAGE1_HARD}, "min_score": 40}),
                (2, {"min_spec_match_rate": 0.7}), (3, {}), (4, {}), (5, {})):
            cur.execute("""
                INSERT INTO ads.run_stage_config (run_id, stage_no, is_enabled, thresholds, weights)
                VALUES (%s, %s, %s, %s, '{}'::jsonb)
                ON CONFLICT (run_id, stage_no) DO NOTHING
            """, (run_id, stage_no, stage_no <= 2, Jsonb(thresholds)))

        # 取目标功能规格窗口
        cur.execute("SELECT default_specs FROM ref.excipient_function WHERE function_code = 'FILLER'")
        spec_def = cur.fetchone()[0] or {}

        survivors = []
        for c in loaded:
            cur.execute("""
                INSERT INTO ads.candidate_pool (run_id, compound_sk, entry_source)
                VALUES (%s, %s, 'demo_seed') ON CONFLICT DO NOTHING
            """, (run_id, c["sk"]))

            # ---- 一级：硬阈值 + 可解释打分 ----
            checks, passed = [], 0
            for prop, op, limit in STAGE1_HARD:
                val = c[{"MW": "mw", "LOGP": "logp", "TPSA": "tpsa", "HBD": "hbd",
                         "HBA": "hba", "ROT_BONDS": "rot"}[prop]]
                ok = {"<=": val <= limit, "<": val < limit, ">=": val >= limit, ">": val > limit}[op]
                passed += bool(ok)
                checks.append({"rule": f"{prop} {op} {limit}", "value": val, "passed": bool(ok)})

            mw_fit = 1.0 if c["mw"] <= 500 else max(0.0, (1200 - c["mw"]) / 700)
            logp_fit = max(0.0, 1 - abs(c["logp"] - 1.5) / 4.5)
            tpsa_fit = max(0.0, 1 - abs(c["tpsa"] - 90) / 200)
            flex_fit = max(0.0, 1 - c["rot"] / 12)
            components = {"MW_FIT": (mw_fit, 0.25), "LOGP_FIT": (logp_fit, 0.30),
                          "TPSA_FIT": (tpsa_fit, 0.20), "FLEX": (flex_fit, 0.25)}
            s1 = round(100 * sum(v * w for v, w in components.values()), 2)
            s1_status = "pass" if passed == len(STAGE1_HARD) and s1 >= 40 else "fail"

            cur.execute("""
                INSERT INTO ads.stage1_ai_screen
                    (run_id, compound_sk, mw, logp_pred, tpsa, hbd, hba, rot_bonds, solubility_logs,
                     predictions, filter_results, filters_total, filters_passed,
                     stage_score, stage_status, rule_version, model_snapshot, decided_at)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,'demo-rules-1.0',%s,now())
                ON CONFLICT (run_id, compound_sk) DO NOTHING
            """, (run_id, c["sk"], c["mw"], c["logp"], c["tpsa"], c["hbd"], c["hba"], c["rot"], c["logs"],
                  Jsonb({"source": "RDKit 描述符 + 规则启发式（非 AI 模型）"}),
                  Jsonb(checks), len(STAGE1_HARD), passed, s1, s1_status,
                  Jsonb({"RDKIT_DESC": "2026.09.2"})))

            for code, (val, wt) in components.items():
                cur.execute("""
                    INSERT INTO ads.compound_score
                        (run_id, compound_sk, stage_no, score_code, score_value, weight, model_code,
                         model_version, rationale)
                    VALUES (%s,%s,1,%s,%s,%s,'RDKIT_DESC','2026.09.2',%s)
                    ON CONFLICT DO NOTHING
                """, (run_id, c["sk"], code, round(val * 100, 2), wt, f"由 {code.split('_')[0]} 归一化得到的适宜度"))

            cur.execute("""
                INSERT INTO ads.stage_trace (run_id, compound_sk, stage_no, action, input_snapshot,
                                             output_snapshot, rule_version, model_code, model_version)
                VALUES (%s,%s,1,%s,%s,%s,'demo-rules-1.0','RDKIT_DESC','2026.09.2')
            """, (run_id, c["sk"], "pass" if s1_status == "pass" else "reject",
                  Jsonb({"desc": {k: c[k] for k in ("mw", "logp", "tpsa", "hbd", "hba", "rot")}}),
                  Jsonb({"score": s1, "status": s1_status, "filters": checks})))

            if s1_status != "pass":
                cur.execute("""
                    UPDATE ads.candidate_pool SET status = 'rejected', current_stage = 1,
                        exited_at = now(), exit_stage = 1, exit_reason = %s
                     WHERE run_id = %s AND compound_sk = %s
                """, (f"一级硬阈值未通过（{passed}/{len(STAGE1_HARD)}）或得分 {s1} < 40", run_id, c["sk"]))
                continue

            # ---- 二级：功能规格窗口匹配 ----
            cur.execute("""
                UPDATE ads.candidate_pool SET current_stage = 2, status = 'advanced'
                 WHERE run_id = %s AND compound_sk = %s
            """, (run_id, c["sk"]))

            prop_map = {"MW": c["mw"], "LOGP": c["logp"], "TPSA": c["tpsa"], "HBD": c["hbd"],
                        "HBA": c["hba"], "ROT_BONDS": c["rot"], "MELTING_POINT": None}
            cur.execute("""
                SELECT value_num FROM dwd.fact_property
                 WHERE compound_sk = %s AND property_code = 'MELTING_POINT'
                 ORDER BY (value_type = 'measured') DESC LIMIT 1
            """, (c["sk"],))
            r = cur.fetchone()
            prop_map["MELTING_POINT"] = float(r[0]) if r else None

            spec_results, matched, total, missing = [], 0, 0, 0
            for prop, window in spec_def.items():
                total += 1
                val = prop_map.get(prop)
                if val is None:
                    missing += 1
                    spec_results.append({"prop": prop, "spec": window, "value": None, "passed": None})
                    continue
                ok = float(window[0]) <= float(val) <= float(window[1])
                matched += bool(ok)
                spec_results.append({"prop": prop, "spec": window, "value": val, "passed": ok})

            rate = round(matched / total, 3) if total else 0.0
            if missing:
                s2_status = "hold"
            elif rate >= 0.7:
                s2_status = "pass"
            else:
                s2_status = "fail"
            s2 = round(100 * rate, 2)

            cur.execute("""
                INSERT INTO ads.stage2_physchem_screen
                    (run_id, compound_sk, target_function_code, spec_results, specs_total, specs_passed,
                     spec_match_rate, hlb, melting_point_c, water_solubility, function_fit_score,
                     stage_score, stage_status, rule_version, decided_at)
                VALUES (%s,%s,'FILLER',%s,%s,%s,%s,NULL,%s,NULL,%s,%s,%s,'demo-rules-1.0',now())
                ON CONFLICT (run_id, compound_sk) DO NOTHING
            """, (run_id, c["sk"], Jsonb(spec_results), total, matched, rate,
                  prop_map["MELTING_POINT"], s2, s2, s2_status))

            cur.execute("""
                INSERT INTO ads.compound_score (run_id, compound_sk, stage_no, score_code,
                                                score_value, weight, rationale)
                VALUES (%s,%s,2,'FUNCTION_FIT',%s,1.0,%s) ON CONFLICT DO NOTHING
            """, (run_id, c["sk"], s2, f"{matched}/{total} 项规格命中，缺失 {missing} 项"))

            cur.execute("""
                INSERT INTO ads.stage_trace (run_id, compound_sk, stage_no, action, input_snapshot,
                                             output_snapshot, rule_version)
                VALUES (%s,%s,2,%s,%s,%s,'demo-rules-1.0')
            """, (run_id, c["sk"], {"pass": "pass", "hold": "hold", "fail": "reject"}[s2_status],
                  Jsonb({"spec_def": spec_def, "values": prop_map}),
                  Jsonb({"score": s2, "status": s2_status, "spec_results": spec_results})))

            if s2_status == "fail":
                cur.execute("""
                    UPDATE ads.candidate_pool SET status = 'rejected', current_stage = 2,
                        exited_at = now(), exit_stage = 2, exit_reason = %s
                     WHERE run_id = %s AND compound_sk = %s
                """, (f"二级功能规格命中率 {s2}% < 70%", run_id, c["sk"]))
                continue

            cur.execute("""
                UPDATE ads.candidate_pool SET status = 'advanced'
                 WHERE run_id = %s AND compound_sk = %s
            """, (run_id, c["sk"]))
            survivors.append((c, s1, s2, s2_status))

        # ------------------------------------------------------------------
        # 排名（仅二级通过者）
        # ------------------------------------------------------------------
        print(f"→ 二级留存 {len(survivors)} 个，写入排名 ...")
        for rank, (c, s1, s2, s2_status) in enumerate(sorted(survivors, key=lambda x: -(0.4 * x[1] + 0.6 * x[2])), start=1):
            final = round(0.4 * s1 + 0.6 * s2, 2)
            verdict = "conditional" if s2_status == "pass" else "hold"
            cur.execute("""
                INSERT INTO ads.rank_result (run_id, compound_sk, final_score, rank_no, verdict,
                                             recommended_function, evidence)
                VALUES (%s,%s,%s,%s,%s,'FILLER',%s)
                ON CONFLICT (run_id, compound_sk) DO UPDATE
                    SET final_score = EXCLUDED.final_score, rank_no = EXCLUDED.rank_no,
                        verdict = EXCLUDED.verdict, evidence = EXCLUDED.evidence
            """, (run_id, c["sk"], final, rank, verdict,
                  Jsonb({"stage1": s1, "stage2": s2,
                         "note": "三~五级未执行，正式结论需补齐安全与放大评估"})))
            cur.execute("""
                UPDATE ads.candidate_pool SET final_score = %s, status = %s
                 WHERE run_id = %s AND compound_sk = %s
            """, (final, "shortlisted" if verdict == "conditional" else "in_funnel", run_id, c["sk"]))

        cur.execute("UPDATE ads.screen_run SET status = 'completed', finished_at = now() WHERE run_id = %s", (run_id,))

        # 刷新特征宽表
        cur.execute("REFRESH MATERIALIZED VIEW ads.mv_compound_feature_matrix")

        cur.execute("""
            INSERT INTO meta.etl_run (job_code, batch_id, status, rows_read, rows_written,
                                      code_version, finished_at)
            VALUES ('dwd_chem_standardize', %s, 'success', %s, %s, 'demo-0.1.0', now())
        """, (batch_id, len(COMPOUNDS), len(loaded)))

        conn.commit()

        # 摘要
        cur.execute("SELECT stage_no, stage_name, evaluated, passed, held, failed FROM ads.v_funnel_summary "
                    "WHERE run_id = %s ORDER BY stage_no", (run_id,))
        print("\n漏斗摘要：")
        print(f"{'级别':<4}{'阶段':<22}{'评估':>6}{'通过':>6}{'挂起':>6}{'淘汰':>6}")
        for s in cur.fetchall():
            print(f"{s[0]:<4}{s[1]:<22}{s[2]:>6}{s[3]:>6}{s[4]:>6}{s[5]:>6}")
        print(f"\nrun_id = {run_id}")
        return 0


def cleanup(cur, conn) -> int:
    cur.execute("DELETE FROM ads.screen_run WHERE run_code = %s", (RUN_CODE,))
    cur.execute("""
        DELETE FROM dwd.dim_compound WHERE first_batch_id IN
            (SELECT batch_id FROM meta.fetch_batch WHERE notes LIKE '%冒烟测试%')
    """)
    cur.execute("DELETE FROM meta.fetch_batch WHERE notes LIKE '%冒烟测试%'")
    conn.commit()
    print("已清除演示数据")
    return 0


if __name__ == "__main__":
    sys.exit(main())
