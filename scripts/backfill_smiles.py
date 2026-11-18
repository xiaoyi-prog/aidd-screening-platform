# -*- coding: utf-8 -*-
"""
DWD 结构字段回填：dim_compound.smiles_isomeric 缺失行
来源优先级：ods.lipidmaps_compound.smiles → ods.chebi_entity.smiles
        → 兜底：RDKit 由 InChI 现算 isomeric SMILES
每条回填值经 RDKit 解析校验，且 InChIKey 必须与 dim_compound.inchikey 一致才落库。
"""
import json
import os
import sys

import psycopg
from psycopg.types.json import Jsonb
from rdkit import Chem, RDLogger

RDLogger.DisableLog("rdApp.*")

HOST, PORT, USER, DB = "127.0.0.1", 55432, "postgres", "aidd"


def isomeric_from(source_smiles=None, source_inchi=None):
    """结构字符串 → (isomeric_smiles, inchikey, quality)。解析失败或 key 不符返回 (None, None, reason)。"""
    mol = None
    if source_smiles:
        mol = Chem.MolFromSmiles(source_smiles)
    if mol is None and source_inchi:
        mol = Chem.MolFromInchi(source_inchi)
    if mol is None:
        return None, None, "parse_failed"
    ik = Chem.MolToInchiKey(mol)
    if not ik:
        return None, None, "inchikey_failed"
    return Chem.MolToSmiles(mol), ik, "valid"


def main():
    conn = psycopg.connect(host=HOST, port=PORT, user=USER, dbname=DB)
    with conn.cursor() as cur:
        # 1) 待回填行
        cur.execute("""
            SELECT compound_sk, inchikey, inchi
              FROM dwd.dim_compound
             WHERE smiles_isomeric IS NULL
             ORDER BY compound_sk
        """)
        targets = cur.fetchall()
        print(f"待回填 {len(targets)} 行")

        # 2) ODS 结构映射（LIPIDMAPS 优先）
        cur.execute("""
            SELECT c.compound_sk, m.smiles, m.inchi
              FROM dwd.dim_compound c
              JOIN dwd.dim_compound_xref x ON x.compound_sk = c.compound_sk
              JOIN ods.lipidmaps_compound m
                ON x.source_system = 'LIPIDMAPS' AND x.source_record_id = m.lm_id
             WHERE c.smiles_isomeric IS NULL AND m.smiles IS NOT NULL
        """)
        lm_map = {r[0]: (r[1], r[2]) for r in cur.fetchall()}
        cur.execute("""
            SELECT c.compound_sk, m.smiles, m.standard_inchi
              FROM dwd.dim_compound c
              JOIN dwd.dim_compound_xref x ON x.compound_sk = c.compound_sk
              JOIN ods.chebi_entity m
                ON x.source_system = 'CHEBI' AND x.source_record_id = m.chebi_id
             WHERE c.smiles_isomeric IS NULL AND m.smiles IS NOT NULL
        """)
        chebi_map = {r[0]: (r[1], r[2]) for r in cur.fetchall()}

        stats = {"lipidmaps": 0, "chebi": 0, "rdkit_inchi_fallback": 0}
        rejected = []
        for sk, ik_expected, dwd_inchi in targets:
            src = None
            rule = None
            if sk in lm_map:
                src, rule = lm_map[sk], "lipidmaps"
            elif sk in chebi_map:
                src, rule = chebi_map[sk], "chebi"
            else:
                src, rule = (None, dwd_inchi), "rdkit_inchi_fallback"

            smiles_src, inchi_src = src
            iso, ik_calc, quality = isomeric_from(smiles_src, inchi_src)
            if iso is None:
                rejected.append((ik_expected, rule, quality))
                continue
            if ik_calc != ik_expected:
                rejected.append((ik_expected, rule, f"key_mismatch:{ik_calc}"))
                continue
            cur.execute("""
                UPDATE dwd.dim_compound
                   SET smiles_isomeric = %s
                 WHERE compound_sk = %s AND smiles_isomeric IS NULL
            """, (iso, sk))
            stats[rule] += 1

        conn.commit()

        # 4) 复核
        cur.execute("SELECT count(*) FROM dwd.dim_compound WHERE smiles_isomeric IS NULL")
        remain = cur.fetchone()[0]
        print(f"回填完成: {stats} | 剩余缺失: {remain}")
        if rejected:
            print("被拒绝(结构不匹配或解析失败):")
            for r in rejected[:10]:
                print("  ", r)

    conn.close()
    return 0 if remain == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
