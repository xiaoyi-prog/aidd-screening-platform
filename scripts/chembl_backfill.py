# -*- coding: utf-8 -*-
"""
chembl_backfill.py — 修正 ChEMBL 交叉映射
==========================================
背景：ChEMBL web services 的 molecule_structure__inchikey 过滤器实际不生效
（静默返回未过滤列表），导致首轮回填混入无关分子。

修正策略：
  1) 清空本轮 ChEMBL 批次数据与相关 xref；
  2) 用 PubChem Title + 前 2 个同义词做 pref_name__icontains 检索；
  3) 对候选分子用 RDKit 从 standard_inchi / canonical_smiles 现算 InChIKey 骨架，
     仅保留骨架能对上 PubChem InChIKey 前段的记录（避免同名异物）；
  4) 重写 ods.chembl_molecule + dwd.dim_compound_xref（match_rule=inchikey_skeleton）。
"""

import json
import sys
import time
import uuid

import psycopg
import requests

sys.path.insert(0, __import__("os").path.dirname(__file__))
from fetch_triterpene import api_get, sha256_json, chembl_bool  # noqa: E402

DB_CONF = dict(host="127.0.0.1", port=55432, user="postgres", dbname="aidd")
SNAPSHOT = "triterpene_adjuvant_oil_2026-11-14"

from rdkit import Chem, RDLogger  # noqa: E402
from rdkit.Chem import Descriptors  # noqa: E402
RDLogger.DisableLog("rdApp.*")


def skeleton_of(mol_json):
    s = mol_json.get("molecule_structures") or {}
    for src in (s.get("standard_inchi"), s.get("canonical_smiles")):
        if not src:
            continue
        m = Chem.MolFromInchi(src) if src.startswith("InChI=") else Chem.MolFromSmiles(src)
        if m is not None:
            try:
                return Chem.MolToInchiKey(m)[:14]
            except Exception:
                pass
    return None


def main():
    conn = psycopg.connect(**DB_CONF)
    with conn.cursor() as cur:
        cur.execute("""SELECT batch_id FROM meta.fetch_batch
                        WHERE snapshot_label=%s AND source_code='PUBCHEM' AND status='success'""",
                    (SNAPSHOT,))
        row = cur.fetchone()
        if not row:
            sys.exit("未找到 PubChem 主批次")
        batch_pub = row[0]
        cur.execute("""SELECT batch_id FROM meta.fetch_batch
                        WHERE snapshot_label=%s AND source_code='CHEMBL' ORDER BY fetch_started_at DESC""",
                    (SNAPSHOT,))
        batch_che = cur.fetchone()[0]

        # 1) 清空错误数据
        cur.execute("DELETE FROM dwd.dim_compound_xref WHERE source_system='CHEMBL'")
        cur.execute("DELETE FROM ods.chembl_molecule WHERE batch_id=%s", (batch_che,))
        print("已清空旧 ChEMBL 数据")

        # 2) 取 PubChem 化合物与检索词
        cur.execute("""SELECT cid, inchikey, raw_payload->>'Title'
                         FROM ods.pubchem_compound WHERE batch_id=%s""", (batch_pub,))
        comps = [(cid, ik, title) for cid, ik, title in cur.fetchall()]
        skel_set = {ik[:14] for _, ik, _ in comps if ik}
        terms = {}
        for cid, ik, title in comps:
            cur.execute("""SELECT synonym FROM ods.pubchem_synonym
                            WHERE batch_id=%s AND cid=%s AND synonym ~ '[a-zA-Z]{5,}'
                            ORDER BY record_id LIMIT 3""", (batch_pub, cid))
            cands = ([title] if title and len(title) >= 5 else []) + [r[0] for r in cur.fetchall()]
            terms[cid] = cands[:3]

        # 3) pref_name 检索，聚合候选
        candidates = {}
        seen_terms = set()
        n_req = 0
        for cid, cands in terms.items():
            for t in cands:
                key = t.lower().strip()
                if key in seen_terms:
                    continue
                seen_terms.add(key)
                try:
                    data = api_get("https://www.ebi.ac.uk/chembl/api/data/molecule.json",
                                   params={"pref_name__icontains": t, "limit": 10})
                    n_req += 1
                except RuntimeError as e:
                    print(f"  [chembl] {t}: {e}", file=sys.stderr)
                    continue
                for m in data.get("molecules", []):
                    cid_ch = m["molecule_chembl_id"]
                    if cid_ch not in candidates:
                        candidates[cid_ch] = m
        print(f"检索词 {len(seen_terms)} 个 / 请求 {n_req} 次，候选 ChEMBL 分子 {len(candidates)} 个")

        # 4) 骨架校验后入库
        inserted = 0
        xref_map = {}   # skel -> [chembl_id]
        for cid_ch, m in candidates.items():
            skel = skeleton_of(m)
            if skel is None or skel not in skel_set:
                continue
            s = m.get("molecule_structures") or {}
            p = m.get("molecule_properties") or {}
            mw = p.get("full_mw")
            cur.execute("""
                INSERT INTO ods.chembl_molecule
                    (chembl_id, pref_name, molecule_type, max_phase, first_approval,
                     oral, parenteral, topical, natural_product, chirality,
                     structure_type, canonical_smiles, standard_inchi,
                     standard_inchikey, molecular_formula, molecular_weight,
                     black_box_warning, withdrawn_flag,
                     batch_id, src_row_hash, raw_payload)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                ON CONFLICT (batch_id, chembl_id) DO UPDATE SET
                    pref_name = EXCLUDED.pref_name
            """, (cid_ch, m.get("pref_name"), m.get("molecule_type"), m.get("max_phase"),
                  m.get("first_approval"),
                  chembl_bool(m.get("oral")), chembl_bool(m.get("parenteral")),
                  chembl_bool(m.get("topical")), chembl_bool(m.get("natural_product")),
                  m.get("chirality"), m.get("structure_type"),
                  s.get("canonical_smiles"), s.get("standard_inchi"), s.get("standard_inchikey"),
                  p.get("full_molformula"), float(mw) if mw not in (None, "") else None,
                  m.get("black_box_warning"), m.get("withdrawn_flag"),
                  batch_che, sha256_json(m), json.dumps(m, ensure_ascii=False)))
            inserted += 1
            xref_map.setdefault(skel, []).append(cid_ch)

        # 5) xref：按骨架挂到 dim_compound（同骨架多立体异构共享 ChEMBL 记录）
        n_xref = 0
        for skel, ch_ids in xref_map.items():
            cur.execute("SELECT compound_sk FROM dwd.dim_compound WHERE inchikey_skeleton=%s",
                        (skel,))
            for (csk,) in cur.fetchall():
                for ch_id in ch_ids:
                    cur.execute("""
                        INSERT INTO dwd.dim_compound_xref
                            (compound_sk, source_system, source_record_id,
                             match_rule, match_confidence, batch_id)
                        VALUES (%s,'CHEMBL',%s,'inchikey_skeleton',0.95,%s)
                        ON CONFLICT (source_system, source_record_id) DO NOTHING
                    """, (csk, ch_id, batch_che))
                    n_xref += cur.rowcount

        cur.execute("""UPDATE meta.fetch_batch
                          SET record_count=%s, status='success', fetch_finished_at=now(),
                              request_params=%s::jsonb,
                              notes='pref_name__icontains + RDKit 骨架校验（inchikey 过滤器不生效，已回填修正）'
                        WHERE batch_id=%s""",
                    (inserted, json.dumps({"match_rule": "pref_name__icontains",
                                           "verify": "rdkit skeleton"}), batch_che))
        conn.commit()
        print(f"验证通过并入库 ChEMBL 分子 {inserted} 个，xref {n_xref} 条")
    conn.close()


if __name__ == "__main__":
    main()
