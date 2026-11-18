# -*- coding: utf-8 -*-
"""
fetch_triterpene.py — 三萜类不饱和烃 / 佐剂油相脂质 ODS 数据接入
====================================================================

数据流：
  1) 种子名称解析  ：squalene / squalane / 2,3-oxidosqualene / botryococcene ... → CID
  2) 相似度扩展    ：以 squalene(CID 638072) 与 squalane(CID 656) 为参照，
                      fastsimilarity_2d Tanimoto>=0.85 扩充三萜烃同系物
  3) 属性拉取      ：PUG REST property 批量（≤100 CID/次），全部进 raw_payload
  4) 同义词拉取    ：synonyms 批量，截断前 30 条/化合物
  5) ChEMBL 交叉   ：按 InChIKey 检索 chembl molecule，补药政属性
  6) ODS 落地      ：ods.pubchem_compound / pubchem_property / pubchem_synonym
                     ods.chembl_molecule，统一登记 meta.fetch_batch
  7) DWD ETL       ：RDKit 解析 InChI → dwd.dim_compound (compound_class=lipid)
                     + dim_compound_xref + fact_property (RDKIT_DESC 计算描述符)

用法：
  python fetch_triterpene.py                 # 全流程
  python fetch_triterpene.py --ods-only      # 只抓 ODS，不做 ETL
"""

import argparse
import hashlib
import json
import os
import re
import sys
import time
import uuid

import psycopg
import requests

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
DB_CONF = dict(
    host=os.environ.get("AIDD_DB_HOST", "127.0.0.1"),
    port=int(os.environ.get("AIDD_DB_PORT", "55432")),
    user=os.environ.get("AIDD_DB_USER", "postgres"),
    dbname=os.environ.get("AIDD_DB_NAME", "aidd"),
)
RDKIT_MODEL = ("RDKIT_DESC", "2026.09.2")

PUBCHEM_BASE = "https://pubchem.ncbi.nlm.nih.gov/rest/pug"
CHEMBL_BASE = "https://www.ebi.ac.uk/chembl/api/data"

# 种子化合物：佐剂油相核心 + 三萜烃谱系参照
SEED_NAMES = [
    "squalene",                # 角鲨烯，MF59/AS03/AS01 油相
    "squalane",                # 角鲨烷（氢化角鲨烯），化妆品/佐剂候选
    "2,3-oxidosqualene",       # 角鲨烯环氧化物，三萜环化前体
    "botryococcene",           # C30 类异戊二烯烃，藻源三萜烃代表
    "dehydrosqualene",         # 去氢角鲨烯
]
SIMILARITY_REFS = [
    ("squalene_ref", 638072, 85),   # (标签, 参照CID, Tanimoto 百分阈值)
    ("squalane_ref", 656, 88),
]

# 注意：PubChem 2025 起标签改名——CanonicalSMILES→ConnectivitySMILES，
# IsomericSMILES→SMILES（isomeric），ComponentCount 已下线。
PROP_TAGS = [
    "MolecularFormula", "MolecularWeight", "ConnectivitySMILES", "SMILES",
    "InChI", "InChIKey", "IUPACName", "Charge", "HeavyAtomCount",
    "DefinedAtomStereoCount", "UndefinedAtomStereoCount",
    "DefinedBondStereoCount", "UndefinedBondStereoCount",
    "IsotopeAtomCount", "CovalentUnitCount",
    "XLogP", "ExactMass", "MonoisotopicMass", "TPSA", "Complexity",
    "HBondDonorCount", "HBondAcceptorCount", "RotatableBondCount", "Title",
]
TAG_ALIAS = {"ConnectivitySMILES": "CanonicalSMILES", "SMILES": "IsomericSMILES"}
NUMERIC_TAGS = {
    "MolecularWeight", "ExactMass", "MonoisotopicMass", "XLogP", "TPSA",
    "Complexity", "Charge", "HeavyAtomCount", "HBondDonorCount",
    "HBondAcceptorCount", "RotatableBondCount",
}
PROPERTY_CODE_MAP = {  # ODS property_name → DWD property_code（ETL 用）
    "MolecularWeight": "MW",
    "XLogP": "LOGP",
    "TPSA": "TPSA",
    "HBondDonorCount": "HBD",
    "HBondAcceptorCount": "HBA",
    "RotatableBondCount": "ROT_BONDS",
}
PROPERTY_UNIT_MAP = {
    "MW": "g_mol", "LOGP": "1", "TPSA": "ang2",
    "HBD": "1", "HBA": "1", "ROT_BONDS": "1",
    "RING_COUNT": "1", "HEAVY_ATOMS": "1",
}

CHUNK = 80          # PUG REST 单次最多 100 个标识符，留余量
SLEEP = 0.25        # 限速：<=5 req/s
MAX_SYNONYMS = 30

session = requests.Session()
session.headers.update({"User-Agent": "AIDD-screening-platform/0.2"})


def api_get(url, params=None, tries=3):
    """带重试的 GET，失败抛异常；429/5xx 退避重试。"""
    last = None
    for i in range(tries):
        try:
            r = session.get(url, params=params, timeout=45)
            if r.status_code == 429 or r.status_code >= 500:
                last = RuntimeError(f"HTTP {r.status_code}: {r.text[:200]}")
                time.sleep(1.5 * (i + 1))
                continue
            r.raise_for_status()
            time.sleep(SLEEP)
            return r.json()
        except (requests.RequestException, ValueError) as e:
            last = e
            time.sleep(1.0 * (i + 1))
    raise RuntimeError(f"GET failed after {tries} tries: {url} -> {last}")


def sha256_json(obj):
    return hashlib.sha256(
        json.dumps(obj, sort_keys=True, ensure_ascii=False).encode("utf-8")
    ).hexdigest()


def chunked(seq, n):
    for i in range(0, len(seq), n):
        yield seq[i:i + n]


# ---------------------------------------------------------------------------
# 1) 种子名称 → CID
# ---------------------------------------------------------------------------
def resolve_seed_names(names):
    seed_cid, notes = {}, []
    for name in names:
        try:
            data = api_get(f"{PUBCHEM_BASE}/compound/name/{name}/cids/JSON")
            cids = data.get("IdentifierList", {}).get("CID", [])
            if cids:
                seed_cid[name] = cids[0]
                notes.append((name, cids[0]))
            else:
                notes.append((name, None))
        except RuntimeError as e:
            notes.append((name, f"ERROR {e}"))
    return seed_cid, notes


# ---------------------------------------------------------------------------
# 2) 相似度扩展
# ---------------------------------------------------------------------------
def similarity_expand(refs):
    found = {}
    for tag, cid, thr in refs:
        try:
            data = api_get(
                f"{PUBCHEM_BASE}/compound/fastsimilarity_2d/cid/{cid}/cids/JSON",
                params={"Threshold": thr, "MaxRecords": 200},
            )
            cids = data.get("IdentifierList", {}).get("CID", [])
            found[tag] = {"ref_cid": cid, "threshold_pct": thr, "cids": cids}
        except RuntimeError as e:
            found[tag] = {"ref_cid": cid, "threshold_pct": thr,
                          "cids": [], "error": str(e)}
    return found


# ---------------------------------------------------------------------------
# 3) 属性批量拉取
# ---------------------------------------------------------------------------
def fetch_properties(cids):
    props = {}
    tags = ",".join(PROP_TAGS)
    for group in chunked(cids, CHUNK):
        data = api_get(f"{PUBCHEM_BASE}/compound/cid/{','.join(map(str, group))}/property/{tags}/JSON")
        for rec in data.get("PropertyTable", {}).get("Properties", []):
            # 标签别名归一 + 数值字段转 float（PubChem 部分字段回传字符串）
            norm = {}
            for k, v in rec.items():
                if k == "CID":
                    norm[k] = int(v)
                    continue
                if k in TAG_ALIAS:
                    k = TAG_ALIAS[k]
                if k in NUMERIC_TAGS and isinstance(v, str):
                    try:
                        v = float(v)
                    except ValueError:
                        pass
                norm[k] = v
            props[int(rec["CID"])] = norm
    return props


# ---------------------------------------------------------------------------
# 4) 同义词批量拉取
# ---------------------------------------------------------------------------
def fetch_synonyms(cids):
    syns = {}
    for group in chunked(cids, CHUNK):
        try:
            data = api_get(f"{PUBCHEM_BASE}/compound/cid/{','.join(map(str, group))}/synonyms/JSON")
        except RuntimeError:
            continue  # 个别 CID 无同义词（如未收录），跳过整组会导致缺数据，逐个降级
        for rec in data.get("InformationList", {}).get("Information", []):
            cid = int(rec["CID"])
            names = rec.get("Synonym") or []
            syns[cid] = names[:MAX_SYNONYMS]
    return syns


# ---------------------------------------------------------------------------
# 5) ChEMBL 交叉检索
#    注意：molecule_structure__inchikey 过滤器实际不生效（静默返回未过滤列表），
#    必须用 pref_name__icontains 检索 + RDKit 骨架校验（见 chembl_backfill.py）。
# ---------------------------------------------------------------------------
def fetch_chembl(term_lists, skeleton_set):
    from rdkit import Chem, RDLogger
    RDLogger.DisableLog("rdApp.*")

    def skel_of(m):
        s = m.get("molecule_structures") or {}
        for src in (s.get("standard_inchi"), s.get("canonical_smiles")):
            if not src:
                continue
            mol = (Chem.MolFromInchi(src) if src.startswith("InChI=")
                   else Chem.MolFromSmiles(src))
            if mol is not None:
                try:
                    return Chem.MolToInchiKey(mol)[:14]
                except Exception:
                    pass
        return None

    out, seen_terms, n_req = {}, set(), 0
    for cid, terms in term_lists.items():
        for t in terms:
            key = t.lower().strip()
            if len(key) < 5 or key in seen_terms:
                continue
            seen_terms.add(key)
            try:
                data = api_get(f"{CHEMBL_BASE}/molecule.json",
                               params={"pref_name__icontains": t, "limit": 10})
                n_req += 1
            except RuntimeError as e:
                print(f"    [chembl] {t}: {e}", file=sys.stderr)
                continue
            for m in data.get("molecules", []):
                skel = skel_of(m)
                if skel is None or skel not in skeleton_set:
                    continue  # 同名异物剔除
                cid_ch = m["molecule_chembl_id"]
                if cid_ch not in {mm["molecule_chembl_id"]
                                  for v in out.values() for mm in v}:
                    out.setdefault(skel, []).append(m)
    return out


# ---------------------------------------------------------------------------
# 6) ODS 落地
# ---------------------------------------------------------------------------
def chembl_bool(v):
    """ChEMBL 回传 -1(未知)/0/1，落库布尔列时 -1 视为 NULL。"""
    return None if v in (None, -1) else bool(v)


def insert_ods(conn, cid_props, cid_syns, chembl_by_key, batch_pub, batch_che, params):
    rows_c, rows_p, rows_s, rows_m = 0, 0, 0, 0
    with conn.cursor() as cur:
        # compound 主记录
        for cid, rec in cid_props.items():
            cur.execute("""
                INSERT INTO ods.pubchem_compound
                    (cid, molecular_formula, molecular_weight, exact_mass,
                     canonical_smiles, isomeric_smiles, inchi, inchikey, iupac_name,
                     charge, heavy_atom_count, defined_atom_stereo_count,
                     undefined_atom_stereo_count, defined_bond_stereo_count,
                     undefined_bond_stereo_count, isotope_atom_count,
                     component_count, covalent_unit_count,
                     batch_id, src_row_hash, raw_payload)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                ON CONFLICT (batch_id, cid) DO NOTHING
            """, (cid,
                  rec.get("MolecularFormula"),
                  rec.get("MolecularWeight"),
                  rec.get("ExactMass"),
                  rec.get("CanonicalSMILES"),
                  rec.get("IsomericSMILES"),
                  rec.get("InChI"),
                  rec.get("InChIKey"),
                  rec.get("IUPACName"),
                  rec.get("Charge"),
                  rec.get("HeavyAtomCount"),
                  rec.get("DefinedAtomStereoCount"),
                  rec.get("UndefinedAtomStereoCount"),
                  rec.get("DefinedBondStereoCount"),
                  rec.get("UndefinedBondStereoCount"),
                  rec.get("IsotopeAtomCount"),
                  rec.get("ComponentCount"),
                  rec.get("CovalentUnitCount"),
                  batch_pub, sha256_json(rec), json.dumps(rec, ensure_ascii=False)))
            rows_c += cur.rowcount

        # 属性长表
        for cid, rec in cid_props.items():
            for tag in NUMERIC_TAGS:
                v = rec.get(tag)
                if v is None:
                    continue
                payload = {"cid": cid, "tag": tag, "value": v}
                cur.execute("""
                    INSERT INTO ods.pubchem_property
                        (cid, property_name, value_num, source_name,
                         batch_id, src_row_hash, raw_payload)
                    VALUES (%s,%s,%s,%s,%s,%s,%s)
                    ON CONFLICT (batch_id, cid, property_name, source_name, value_text)
                    DO NOTHING
                """, (cid, tag, v, "PubChem/Cactvs",
                      batch_pub, sha256_json(payload),
                      json.dumps(payload, ensure_ascii=False)))
                rows_p += cur.rowcount

        # 同义词
        for cid, names in cid_syns.items():
            for nm in names:
                payload = {"cid": cid, "synonym": nm}
                cur.execute("""
                    INSERT INTO ods.pubchem_synonym (cid, synonym, batch_id, src_row_hash, raw_payload)
                    VALUES (%s,%s,%s,%s,%s)
                    ON CONFLICT (batch_id, cid, synonym) DO NOTHING
                """, (cid, nm, batch_pub, sha256_json(payload),
                      json.dumps(payload, ensure_ascii=False)))
                rows_s += cur.rowcount

        # ChEMBL 分子
        for key, mols in chembl_by_key.items():
            for m in mols:
                struct = m.get("molecule_structures") or {}
                props = m.get("molecule_properties") or {}
                cur.execute("""
                    INSERT INTO ods.chembl_molecule
                        (chembl_id, pref_name, molecule_type, max_phase, first_approval,
                         oral, parenteral, topical, natural_product, chirality,
                         structure_type, canonical_smiles, standard_inchi,
                         standard_inchikey, molecular_formula, molecular_weight,
                         black_box_warning, withdrawn_flag,
                         batch_id, src_row_hash, raw_payload)
                    VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                    ON CONFLICT (batch_id, chembl_id) DO NOTHING
                """, (m["molecule_chembl_id"], m.get("pref_name"),
                      m.get("molecule_type"), m.get("max_phase"),
                      m.get("first_approval"),
                      chembl_bool(m.get("oral")), chembl_bool(m.get("parenteral")),
                      chembl_bool(m.get("topical")), chembl_bool(m.get("natural_product")),
                      m.get("chirality"),
                      m.get("structure_type"), struct.get("canonical_smiles"),
                      struct.get("standard_inchi"), struct.get("standard_inchikey"),
                      props.get("full_molformula"),
                      float(props["full_mw"]) if props.get("full_mw") not in (None, "") else None,
                      m.get("black_box_warning"), m.get("withdrawn_flag"),
                      batch_che, sha256_json(m), json.dumps(m, ensure_ascii=False)))
                rows_m += cur.rowcount

        # 登记批次参数
        cur.execute("""
            UPDATE meta.fetch_batch
               SET request_params = %s::jsonb, record_count = %s,
                   fetch_finished_at = now(), status = 'success',
                   checksum_sha256 = %s
             WHERE batch_id = %s
        """, (json.dumps(params, ensure_ascii=False), rows_c,
              sha256_json({str(cid): rec for cid, rec in cid_props.items()}),
              batch_pub))
        cur.execute("""
            UPDATE meta.fetch_batch
               SET request_params = %s::jsonb, record_count = %s,
                   fetch_finished_at = now(), status = 'success'
             WHERE batch_id = %s
        """, (json.dumps({"match_rule": "molecule_structure__inchikey",
                          "inchikeys": len(chembl_by_key)}, ensure_ascii=False),
              rows_m, batch_che))
    return rows_c, rows_p, rows_s, rows_m


# ---------------------------------------------------------------------------
# 7) DWD ETL
# ---------------------------------------------------------------------------
def run_etl(conn, cid_props, batch_pub):
    from rdkit import Chem, RDLogger
    from rdkit.Chem import Crippen, Descriptors, rdMolDescriptors
    RDLogger.DisableLog("rdApp.*")

    n_comp, n_fact, n_xref, n_suspect = 0, 0, 0, 0
    with conn.cursor() as cur:
        # 注册 PubChem 计算描述符模型（幂等）
        cur.execute("""
            INSERT INTO ref.model_registry
                (model_code, model_version, task_type, model_name_cn, framework,
                 notes, status, owner)
            VALUES ('PUBCHEM_DESC','2026.11','descriptor','PubChem Cactvs 计算描述符',
                    'pubchem-pug-rest','来源：PUG REST property 区块（XLogP/TPSA/复杂度等）',
                    'active','data-eng')
            ON CONFLICT (model_code, model_version) DO NOTHING
        """)

        for cid, rec in cid_props.items():
            ik = rec.get("InChIKey")
            inchi = rec.get("InChI")
            if not ik:
                continue
            mol = Chem.MolFromInchi(inchi) if inchi else None
            quality = "valid" if mol is not None else "suspect"
            if mol is None:
                n_suspect += 1
            flags = {"undefined_stereo": rec.get("UndefinedAtomStereoCount", 0) or 0}
            formula = rec.get("MolecularFormula") or ""
            is_lipid = re.fullmatch(r"C\d+H\d*", formula) is not None

            cur.execute("""
                INSERT INTO dwd.dim_compound
                    (inchikey, inchi, smiles_canonical, smiles_isomeric,
                     molecular_formula, molecular_weight, charge, heavy_atom_count,
                     compound_class, structure_quality, quality_flags, first_batch_id)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                ON CONFLICT (inchikey) DO UPDATE SET
                    inchi             = COALESCE(EXCLUDED.inchi, dwd.dim_compound.inchi),
                    smiles_canonical  = COALESCE(EXCLUDED.smiles_canonical, dwd.dim_compound.smiles_canonical),
                    smiles_isomeric   = COALESCE(EXCLUDED.smiles_isomeric, dwd.dim_compound.smiles_isomeric),
                    molecular_formula = COALESCE(EXCLUDED.molecular_formula, dwd.dim_compound.molecular_formula),
                    updated_at        = now()
                RETURNING compound_sk, (xmax = 0) AS inserted
            """, (ik, inchi, rec.get("CanonicalSMILES"), rec.get("IsomericSMILES"),
                  formula, rec.get("MolecularWeight"), rec.get("Charge"),
                  rec.get("HeavyAtomCount"),
                  "lipid" if is_lipid else "small_molecule",
                  quality, json.dumps(flags), batch_pub))
            row = cur.fetchone()
            compound_sk = row[0]

            # xref
            cur.execute("""
                INSERT INTO dwd.dim_compound_xref
                    (compound_sk, source_system, source_record_id, match_rule,
                     match_confidence, batch_id)
                VALUES (%s,'PUBCHEM',%s,'inchikey_exact',1.0,%s)
                ON CONFLICT (source_system, source_record_id) DO NOTHING
            """, (compound_sk, str(cid), batch_pub))
            n_xref += cur.rowcount

            # PubChem 源值进 fact_property（computed，PUBCHEM_DESC 模型）
            for tag, code in PROPERTY_CODE_MAP.items():
                v = rec.get(tag)
                if v is None:
                    continue
                cur.execute("""
                    INSERT INTO dwd.fact_property
                        (compound_sk, property_code, value_type, value_num, unit,
                         model_code, model_version, source_system, source_record_id,
                         confidence, batch_id)
                    VALUES (%s,%s,'computed',%s,%s,'PUBCHEM_DESC','2026.11','PUBCHEM',%s,1.0,%s)
                    ON CONFLICT DO NOTHING
                """, (compound_sk, code, v, PROPERTY_UNIT_MAP[code],
                      str(cid), batch_pub))
                n_fact += cur.rowcount

            # RDKit 标准化重算（RDKIT_DESC 模型），与 PubChem 值并存可交叉校验
            if mol is not None:
                rdkit_vals = {
                    "MW": Descriptors.MolWt(mol),
                    "LOGP": Crippen.MolLogP(mol),
                    "TPSA": rdMolDescriptors.CalcTPSA(mol),
                    "HBD": rdMolDescriptors.CalcNumLipinskiHBD(mol),
                    "HBA": rdMolDescriptors.CalcNumLipinskiHBA(mol),
                    "ROT_BONDS": rdMolDescriptors.CalcNumRotatableBonds(mol),
                    "RING_COUNT": rdMolDescriptors.CalcNumRings(mol),
                    "HEAVY_ATOMS": mol.GetNumHeavyAtoms(),
                }
                for code, v in rdkit_vals.items():
                    cur.execute("""
                        INSERT INTO dwd.fact_property
                            (compound_sk, property_code, value_type, value_num, unit,
                             model_code, model_version, source_system, source_record_id,
                             confidence, batch_id)
                        VALUES (%s,%s,'computed',%s,%s,'RDKIT_DESC','2026.09.2','RDKIT',%s,1.0,%s)
                        ON CONFLICT DO NOTHING
                    """, (compound_sk, code, v, PROPERTY_UNIT_MAP[code],
                          str(cid), batch_pub))
                    n_fact += cur.rowcount

            n_comp += 1
    return n_comp, n_fact, n_xref, n_suspect


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ods-only", action="store_true", help="只抓 ODS，不跑 DWD ETL")
    args = ap.parse_args()

    print("[1/7] 种子名称解析 ...")
    seed_cid, seed_notes = resolve_seed_names(SEED_NAMES)
    for name, r in seed_notes:
        print(f"    {name:24s} -> {r}")

    print("[2/7] 相似度扩展 ...")
    sim = similarity_expand(SIMILARITY_REFS)
    all_cids = set(seed_cid.values())
    for tag, info in sim.items():
        print(f"    {tag}: {len(info['cids'])} 个相似 CID")
        all_cids.update(info["cids"])
    print(f"    合并后 CID 总数: {len(all_cids)}")

    print("[3/7] 批量拉取属性 ...")
    props = fetch_properties(sorted(all_cids))
    print(f"    拉到 {len(props)} 个化合物的属性")

    # 三萜烃过滤：纯 C/H 且碳数 25-35 为主目标；种子化合物全保留（含氧化前体）
    def is_hydrocarbon(rec):
        f = rec.get("MolecularFormula") or ""
        return re.fullmatch(r"C\d+H\d*", f) is not None

    def carbon_count(f):
        m = re.match(r"C(\d+)", f or "")
        return int(m.group(1)) if m else 0

    hydro = {c: r for c, r in props.items()
             if is_hydrocarbon(r) and 25 <= carbon_count(r.get("MolecularFormula")) <= 35}
    seed_set = set(seed_cid.values())
    keep = dict(hydro)
    for c in seed_set:
        if c in props:
            keep[c] = props[c]
    print(f"    三萜烃主目标 {len(hydro)} 个 + 种子保留 {len(seed_set & set(props))} 个"
          f" = 入库 {len(keep)} 个")

    print("[4/7] 批量拉取同义词 ...")
    syns = fetch_synonyms(sorted(keep))
    print(f"    {len(syns)} 个化合物有同义词")

    print("[5/7] ChEMBL 交叉检索（pref_name + 骨架校验）...")
    term_lists = {}
    for c, r in keep.items():
        t = [r.get("Title") or ""] + syns.get(c, [])[:2]
        term_lists[c] = [x for x in t if x]
    skel_set = {r["InChIKey"][:14] for r in keep.values() if r.get("InChIKey")}
    chembl = fetch_chembl(term_lists, skel_set)
    print(f"    ChEMBL 骨架校验通过 {sum(len(v) for v in chembl.values())} 条 / {len(chembl)} 个骨架")

    batch_pub, batch_che = str(uuid.uuid4()), str(uuid.uuid4())
    params = {
        "seed_names": SEED_NAMES,
        "seed_resolved": {k: v for k, v in seed_cid.items()},
        "similarity": {t: {"ref_cid": i["ref_cid"], "threshold": i["threshold_pct"],
                           "n": len(i["cids"])} for t, i in sim.items()},
        "filters": {"hydrocarbon": "pure CH, carbon 25-35", "seed_keep_all": True},
        "api": "PUG REST / fastsimilarity_2d",
    }
    conn = psycopg.connect(**DB_CONF)
    try:
        with conn.transaction():
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO meta.fetch_batch
                        (batch_id, source_code, snapshot_label, source_release,
                         request_params, status)
                    VALUES (%s,'PUBCHEM','triterpene_adjuvant_oil_2026-11-14',
                            'PUG REST (live)', '{}','running')
                """, (batch_pub,))
                cur.execute("""
                    INSERT INTO meta.fetch_batch
                        (batch_id, source_code, snapshot_label, source_release,
                         request_params, status)
                    VALUES (%s,'CHEMBL','triterpene_adjuvant_oil_2026-11-14',
                            'ChEMBL web services (live)', '{}','running')
                """, (batch_che,))
        print("[6/7] ODS 落地 ...")
        rows = insert_ods(conn, keep, syns, chembl, batch_pub, batch_che, params)
        conn.commit()
        print(f"    compound={rows[0]}  property={rows[1]}  synonym={rows[2]}"
              f"  chembl_molecule={rows[3]}")

        if not args.ods_only:
            print("[7/7] DWD ETL (RDKit) ...")
            etl = run_etl(conn, keep, batch_pub)
            conn.commit()
            print(f"    dim_compound 处理={etl[0]} (suspect={etl[3]})  "
                  f"fact_property={etl[1]}  xref={etl[2]}")
    finally:
        conn.close()

    # 汇总 JSON 供报告使用
    summary = {
        "batch_pubchem": batch_pub, "batch_chembl": batch_che,
        "seed_resolved": seed_cid, "seed_notes": seed_notes,
        "similarity": {t: {"ref_cid": i["ref_cid"], "n": len(i["cids"])}
                       for t, i in sim.items()},
        "ods_rows": {"compound": len(keep), "synonym": sum(len(v) for v in syns.values()),
                     "chembl_molecule": sum(len(v) for v in chembl.values())},
        "compounds": [
            {"cid": c, "formula": r.get("MolecularFormula"),
             "mw": r.get("MolecularWeight"), "xlogp": r.get("XLogP"),
             "inchikey": r.get("InChIKey"),
             "title": r.get("Title") or (syns.get(c) or [None])[0]}
            for c, r in sorted(keep.items())
        ],
    }
    out = os.path.join(os.path.dirname(__file__), "..", "reports",
                       "triterpene_ingest_summary.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2, default=str)
    print(f"摘要已写入 {os.path.normpath(out)}")


if __name__ == "__main__":
    main()
