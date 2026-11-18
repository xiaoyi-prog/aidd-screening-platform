# -*- coding: utf-8 -*-
"""
fetch_triterpene_ext.py — 三萜烃/佐剂油相脂质 · 外部数据库扩展接入
====================================================================
除 PubChem / ChEMBL 之外的三个主流库（都是公开 API，无需鉴权）：

  1) ChEBI 2.0 REST（EBI）
     - 本体 BFS：从 CHEBI:35191(triterpene) 沿 incoming "is a" 收集整个子树
     - 化合物节点取 default_structure(InChIKey) + chemical_data + database_accessions
  2) LIPID MAPS REST
     - /rest/compound/lm_id/LMPR0106/all/download → C30 类异戊二烯（三萜）全类表
  3) KEGG COMPOUND（rest.kegg.jp；rest.kegg.ws 在当前网络不可达）
     - find/compound/{squalene,triterpene,...} + get/{entry}，DBLINKS 做交叉映射

ODS 落地：ods.chebi_entity / ods.lipidmaps_compound / ods.kegg_compound（迁移 010）
DWD ETL  ：dim_compound + xref + fact_property（RDKIT_DESC 描述符）
"""

import csv
import hashlib
import json
import os
import re
import sys
import time
import uuid

import psycopg
import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fetch_triterpene import api_get, sha256_json, chunked  # noqa: E402

DB_CONF = dict(host="127.0.0.1", port=55432, user="postgres", dbname="aidd")
SNAP_DATE = "2026-11-14"

CHEBI_ROOT = ("CHEBI:35191", "triterpene")
CHEBI_BASE = "https://www.ebi.ac.uk/chebi/backend/api/public"
LM_BASE = "https://www.lipidmaps.org/rest"
KEGG_BASE = "https://rest.kegg.jp"

LM_CLASSES = ["LMPR0106"]  # C30 isoprenoids (triterpenes)
KEGG_KEYWORDS = ["squalene", "triterpene", "triterpenoid", "hopane",
                 "botryococcene", "diapophytoene", "tetrahymanol"]
MAX_CHEBI_NODES = 1500

def api_get_text(url, params=None, tries=3):
    """带重试的 GET（纯文本响应，如 KEGG）。"""
    last = None
    for i in range(tries):
        try:
            r = requests.get(url, params=params, timeout=45)
            if r.status_code == 429 or r.status_code >= 500:
                last = RuntimeError(f"HTTP {r.status_code}")
                time.sleep(1.5 * (i + 1))
                continue
            r.raise_for_status()
            time.sleep(0.15)
            return r.text
        except requests.RequestException as e:
            last = e
            time.sleep(1.0 * (i + 1))
    raise RuntimeError(f"GET failed after {tries} tries: {url} -> {last}")


# ---------------------------------------------------------------------------

from rdkit import Chem, RDLogger  # noqa: E402
from rdkit.Chem import Crippen, Descriptors, rdMolDescriptors  # noqa: E402
RDLogger.DisableLog("rdApp.*")

CARBON_RE = re.compile(r"^C(\d+)(H\d*)$")
RDKIT_UNIT = {"MW": "g_mol", "LOGP": "1", "TPSA": "ang2", "HBD": "1",
              "HBA": "1", "ROT_BONDS": "1", "RING_COUNT": "1", "HEAVY_ATOMS": "1"}


def is_hydrocarbon(formula, cmin=25, cmax=35):
    m = CARBON_RE.match(formula or "")
    if not m:
        return False
    return cmin <= int(m.group(1)) <= cmax


def inchikey_from_structure(inchi=None, smiles=None):
    mol = None
    if inchi:
        mol = Chem.MolFromInchi(inchi)
    if mol is None and smiles:
        mol = Chem.MolFromSmiles(smiles)
    if mol is None:
        return None
    try:
        return Chem.MolToInchiKey(mol)
    except Exception:
        return None


# ---------------------------------------------------------------------------
# 1) ChEBI：本体 BFS
# ---------------------------------------------------------------------------
def chebi_bfs():
    """返回 {chebi_id: entity_dict}，BFS 全子树；超限截断并记录。"""
    entities, visited = {}, set()
    queue = [CHEBI_ROOT]
    truncated = False
    while queue:
        if len(visited) >= MAX_CHEBI_NODES:
            truncated = True
            break
        cid, cname = queue.pop(0)
        num = cid.split(":")[1]
        if cid in visited:
            continue
        visited.add(cid)
        try:
            data = api_get(f"{CHEBI_BASE}/compound/{num}")
        except RuntimeError as e:
            print(f"    [chebi] {cid} 获取失败: {e}", file=sys.stderr)
            continue
        entities[cid] = {"entity": data, "parent_id": cid, "parent_name": cname}

        rels = (data.get("ontology_relations") or {}).get("incoming_relations") or []
        for r in rels:
            if r.get("relation_type") == "is a" and r.get("init_id"):
                child = f"CHEBI:{r['init_id']}"
                if child not in visited:
                    queue.append((child, r.get("init_name") or cname))
        time.sleep(0.15)
    print(f"    BFS 访问 {len(visited)} 个本体节点"
          + ("（达到上限截断）" if truncated else ""))
    return entities


def chebi_compound_rows(entities):
    """筛出化合物节点（有 formula 或名字带 squalene/squalane）。"""
    rows = []
    for cid, wrap in entities.items():
        d = wrap["entity"]
        cd = d.get("chemical_data")
        formula = charge = mass = mono = None
        if isinstance(cd, list) and cd:
            cd = cd[0]
        if isinstance(cd, dict):
            formula, charge = cd.get("formula"), cd.get("charge")
            mass, mono = cd.get("mass"), cd.get("monoisotopic_mass")
        ds = d.get("default_structure") or {}
        name = d.get("name") or d.get("ascii_name") or ""
        keep = bool(formula) or re.search(r"squalene|squalane", name, re.I)
        if not keep:
            continue
        # database_accessions → 跨库引用
        xref = {}
        da = d.get("database_accessions") or {}
        if isinstance(da, dict):
            for src, lst in da.items():
                accs = [a.get("accession_number") for a in (lst or [])
                        if a.get("accession_number")]
                if accs:
                    xref[src] = accs
        rows.append({
            "chebi_id": cid, "name": name,
            "definition": d.get("definition"),
            "stars": d.get("stars"),
            "formula": formula, "mass": mass, "monoisotopic_mass": mono,
            "charge": charge, "smiles": ds.get("smiles"),
            "standard_inchi": ds.get("standard_inchi"),
            "standard_inchikey": ds.get("standard_inchi_key"),
            "parent_class_id": wrap["parent_id"],
            "parent_class_name": wrap["parent_name"],
            "cross_refs": xref, "raw": d,
        })
    print(f"    化合物/种子实体 {len(rows)} 个（其余为纯分类节点，不入 ODS）")
    return rows


# ---------------------------------------------------------------------------
# 2) LIPID MAPS：download 全类表
# ---------------------------------------------------------------------------
def lipidmaps_rows():
    rows = []
    for cls in LM_CLASSES:
        url = f"{LM_BASE}/compound/lm_id/{cls}/all/download"
        last = None
        for _ in range(3):
            try:
                r = requests.get(url, timeout=120)
                r.raise_for_status()
                last = r.text
                break
            except requests.RequestException as e:
                last = str(e)
                time.sleep(2)
        if last is None:
            raise RuntimeError(f"LIPID MAPS download 失败: {url}")
        lines = [ln for ln in last.splitlines() if ln.strip()]
        # 第一行是日期戳，第二行才是表头
        reader = csv.DictReader(lines[1:], delimiter="\t")
        for rec in reader:
            rec = {k: (v or None) for k, v in rec.items() if k}
            if not rec.get("lm_id"):
                continue
            rec["_class_query"] = cls
            rows.append(rec)
        print(f"    {cls}: {len(rows)} 条")
    return rows


# ---------------------------------------------------------------------------
# 3) KEGG COMPOUND
# ---------------------------------------------------------------------------
def kegg_entries():
    entry_ids = set()
    for kw in KEGG_KEYWORDS:
        try:
            data = api_get_text(f"{KEGG_BASE}/find/compound/{kw}")
            for ln in (data or "").splitlines():
                eid = ln.split("\t")[0].strip()
                if re.fullmatch(r"C\d+", eid):
                    entry_ids.add(eid)
        except RuntimeError as e:
            print(f"    [kegg] find {kw} 失败: {e}", file=sys.stderr)
    print(f"    关键词检索命中 {len(entry_ids)} 个 entry")

    field_re = re.compile(r"^(ENTRY|NAME|FORMULA|EXACT_MASS|MOL_WEIGHT|"
                          r"SMILES|INCHIKEY|INCHI|REACTION|PATHWAY|BRITE|"
                          r"DBLINKS|ATOM|BOND|SEQUENCE)\s+(.*)$")
    rows = []
    for eid in sorted(entry_ids):
        try:
            text = api_get_text(f"{KEGG_BASE}/get/{eid}")
        except RuntimeError as e:
            print(f"    [kegg] get {eid} 失败: {e}", file=sys.stderr)
            continue
        fields, order = {}, []
        cur = None
        for ln in text.splitlines():
            m = field_re.match(ln)
            if m:
                cur = m.group(1)
                if cur not in fields:
                    order.append(cur)
                    fields[cur] = []
                fields[cur].append(m.group(2).strip())
            elif cur and ln.startswith((" ", "  ", "\t")):
                fields[cur].append(ln.strip())
        clean = {k: " ".join(v) for k, v in fields.items()}
        name = (clean.get("NAME") or "").rstrip("/")
        dblink = {}
        for k, v in re.findall(r"([A-Za-z][A-Za-z0-9]+):\s*(\S+)",
                               clean.get("DBLINKS", "")):
            dblink.setdefault(k, []).append(v)
        rows.append({
            "entry": eid, "name": name,
            "formula": clean.get("FORMULA"),
            "exact_mass": clean.get("EXACT_MASS"),
            "mol_weight": clean.get("MOL_WEIGHT"),
            "smiles": clean.get("SMILES"),
            "inchi": clean.get("INCHI"),
            "inchikey": clean.get("INCHIKEY"),
            "reactions": clean.get("REACTION"),
            "pathways": clean.get("PATHWAY"),
            "dblinks": dblink, "raw": text,
        })
        time.sleep(0.15)
    return rows


# ---------------------------------------------------------------------------
# ODS 落地
# ---------------------------------------------------------------------------
def insert_ods(conn, chebi_rows, lm_rows, kegg_rows, batches):
    n_che = n_lm = n_kegg = 0
    with conn.cursor() as cur:
        for r in chebi_rows:
            cur.execute("""
                INSERT INTO ods.chebi_entity
                    (chebi_id, name, definition, stars, formula, mass,
                     monoisotopic_mass, charge, smiles, standard_inchi,
                     standard_inchikey, parent_class_id, parent_class_name,
                     cross_refs, batch_id, src_row_hash, raw_payload)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                ON CONFLICT (batch_id, chebi_id) DO NOTHING
            """, (r["chebi_id"], r["name"], r["definition"], r["stars"],
                  r["formula"], r["mass"], r["monoisotopic_mass"], r["charge"],
                  r["smiles"], r["standard_inchi"], r["standard_inchikey"],
                  r["parent_class_id"], r["parent_class_name"],
                  json.dumps(r["cross_refs"], ensure_ascii=False),
                  batches["CHEBI"], sha256_json(r["raw"]),
                  json.dumps(r["raw"], ensure_ascii=False)))
            n_che += cur.rowcount

        for r in lm_rows:
            payload = {k: v for k, v in r.items()}
            cur.execute("""
                INSERT INTO ods.lipidmaps_compound
                    (lm_id, regno, name, sys_name, synonyms, abbrev, core,
                     main_class, sub_class, class_level4, formula, exact_mass,
                     inchi, inchikey, smiles, kegg_id, hmdb_id, chebi_id,
                     pubchem_cid, batch_id, src_row_hash, raw_payload)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                ON CONFLICT (batch_id, lm_id) DO NOTHING
            """, (r.get("lm_id"), r.get("regno"), r.get("name"), r.get("sys_name"),
                  r.get("synonyms"), r.get("abbrev"), r.get("core"),
                  r.get("main_class"), r.get("sub_class"), r.get("class_level4"),
                  r.get("formula"), r.get("exactmass"), r.get("inchi"),
                  r.get("inchi_key"), r.get("smiles"), r.get("kegg_id"),
                  r.get("hmdb_id"), r.get("chebi_id"), r.get("pubchem_cid"),
                  batches["LIPIDMAPS"], sha256_json(payload),
                  json.dumps(payload, ensure_ascii=False)))
            n_lm += cur.rowcount

        for r in kegg_rows:
            cur.execute("""
                INSERT INTO ods.kegg_compound
                    (entry, name, formula, exact_mass, mol_weight, smiles,
                     inchi, inchikey, reactions, pathways, dblinks,
                     batch_id, src_row_hash, raw_payload)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                ON CONFLICT (batch_id, entry) DO NOTHING
            """, (r["entry"], r["name"], r["formula"],
                  float(r["exact_mass"]) if r["exact_mass"] else None,
                  float(r["mol_weight"]) if r["mol_weight"] else None,
                  r["smiles"], r["inchi"], r["inchikey"],
                  re.findall(r"R\d+", r["reactions"] or ""),
                  re.findall(r"map\d+", r["pathways"] or ""),
                  json.dumps(r["dblinks"], ensure_ascii=False),
                  batches["KEGG"], sha256_json({"entry": r["entry"], "raw": r["raw"]}),
                  json.dumps({"raw_text": r["raw"]}, ensure_ascii=False)))
            n_kegg += cur.rowcount
    return n_che, n_lm, n_kegg


# ---------------------------------------------------------------------------
# DWD ETL
# ---------------------------------------------------------------------------
def run_etl(conn, chebi_rows, lm_rows, kegg_rows, batches):
    n_comp, n_fact, n_xref = 0, 0, 0

    # inchikey 候选聚合（跨源去重）+ 结构补全映射
    ikey_srcs, ikey_struct = {}, {}
    for r in chebi_rows:
        ik = r.get("standard_inchikey")
        if ik:
            ikey_srcs.setdefault(ik, []).append(("CHEBI", r["chebi_id"], 1.0, "inchikey_exact"))
            ikey_struct.setdefault(ik, (r.get("standard_inchi"), r.get("smiles")))
    for r in lm_rows:
        ik = r.get("inchi_key")
        if ik:
            ikey_srcs.setdefault(ik, []).append(("LIPIDMAPS", r["lm_id"], 1.0, "inchikey_exact"))
            ikey_struct.setdefault(ik, (r.get("inchi"), r.get("smiles")))
    for r in kegg_rows:
        ik = r.get("inchikey") or inchikey_from_structure(r.get("inchi"), r.get("smiles"))
        if ik:
            ikey_srcs.setdefault(ik, []).append(("KEGG", r["entry"], 0.95, "inchikey_exact"))
            ikey_struct.setdefault(ik, (r.get("inchi"), r.get("smiles")))
        else:
            # 无结构：靠 DBLINKS 交叉映射（PubChem CID / ChEBI）
            r["_dblink_match_pending"] = True

    with conn.cursor() as cur:
        for ik, srcs in ikey_srcs.items():
            cur.execute("SELECT compound_sk FROM dwd.dim_compound WHERE inchikey=%s", (ik,))
            row = cur.fetchone()
            inchi, smiles = ikey_struct.get(ik, (None, None))
            mol = Chem.MolFromInchi(inchi) if inchi else (Chem.MolFromSmiles(smiles) if smiles else None)
            quality = "valid" if mol is not None else "suspect"
            formula = None
            if mol is not None:
                formula = Chem.rdMolDescriptors.CalcMolFormula(mol)
            hydro = is_hydrocarbon(formula) if formula else False

            cur.execute("""
                INSERT INTO dwd.dim_compound
                    (inchikey, inchi, smiles_canonical,
                     molecular_formula, compound_class, structure_quality,
                     quality_flags, first_batch_id, ring_count)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)
                ON CONFLICT (inchikey) DO UPDATE SET
                    inchi            = COALESCE(EXCLUDED.inchi, dwd.dim_compound.inchi),
                    smiles_canonical = COALESCE(EXCLUDED.smiles_canonical, dwd.dim_compound.smiles_canonical),
                    molecular_formula= COALESCE(EXCLUDED.molecular_formula, dwd.dim_compound.molecular_formula),
                    ring_count       = COALESCE(dwd.dim_compound.ring_count, EXCLUDED.ring_count),
                    updated_at       = now()
                RETURNING compound_sk
            """, (ik, inchi, smiles, formula,
                  "lipid" if hydro else "small_molecule",
                  quality, json.dumps({"undefined_stereo": 0}),
                  batches["CHEBI"],
                  rdMolDescriptors.CalcNumRings(mol) if mol is not None else None))
            csk = cur.fetchone()[0]

            # PubChem 源的 smiles 若缺失而本源有结构，补写
            for src, rid, conf, rule in srcs:
                cur.execute("""
                    INSERT INTO dwd.dim_compound_xref
                        (compound_sk, source_system, source_record_id,
                         match_rule, match_confidence, batch_id)
                    VALUES (%s,%s,%s,%s,%s,%s)
                    ON CONFLICT (source_system, source_record_id) DO NOTHING
                """, (csk, src, rid, rule, conf, batches[src]))
                n_xref += cur.rowcount

            if mol is not None:
                vals = {
                    "MW": Descriptors.MolWt(mol),
                    "LOGP": Crippen.MolLogP(mol),
                    "TPSA": rdMolDescriptors.CalcTPSA(mol),
                    "HBD": rdMolDescriptors.CalcNumLipinskiHBD(mol),
                    "HBA": rdMolDescriptors.CalcNumLipinskiHBA(mol),
                    "ROT_BONDS": rdMolDescriptors.CalcNumRotatableBonds(mol),
                    "RING_COUNT": rdMolDescriptors.CalcNumRings(mol),
                    "HEAVY_ATOMS": mol.GetNumHeavyAtoms(),
                }
                for code, v in vals.items():
                    cur.execute("""
                        INSERT INTO dwd.fact_property
                            (compound_sk, property_code, value_type, value_num, unit,
                             model_code, model_version, source_system, source_record_id,
                             confidence, batch_id)
                        VALUES (%s,%s,'computed',%s,%s,'RDKIT_DESC','2026.09.2','RDKIT',%s,1.0,%s)
                        ON CONFLICT DO NOTHING
                    """, (csk, code, v, RDKIT_UNIT[code], ik[:14], batches[srcs[0][0]]))
                    n_fact += cur.rowcount
            n_comp += 1

        # KEGG 无结构条目：DBLINKS 三路交叉映射
        for r in kegg_rows:
            if not r.get("_dblink_match_pending"):
                continue
            dbl = r.get("dblinks") or {}
            match = None
            # a) LIPIDMAPS id → 已有 xref
            for lm in dbl.get("LIPIDMAPS", []):
                cur.execute("""SELECT compound_sk FROM dwd.dim_compound_xref
                                WHERE source_system='LIPIDMAPS' AND source_record_id=%s""",
                            (lm,))
                hit = cur.fetchone()
                if hit:
                    match = (hit[0], 'crossref')
                    break
            # b) PubChem CID → 已有 xref
            if not match:
                for c in dbl.get("PubChem", []):
                    cur.execute("""SELECT compound_sk FROM dwd.dim_compound_xref
                                    WHERE source_system='PUBCHEM' AND source_record_id=%s""",
                                (str(c),))
                    hit = cur.fetchone()
                    if hit:
                        match = (hit[0], 'crossref')
                        break
            # c) ChEBI id → ods.chebi_entity 的 InChIKey
            if not match:
                for ch in dbl.get("ChEBI", []):
                    cur.execute("""SELECT standard_inchikey FROM ods.chebi_entity
                                    WHERE chebi_id=%s""", (f"CHEBI:{ch}",))
                    hit = cur.fetchone()
                    if hit and hit[0]:
                        cur.execute("SELECT compound_sk FROM dwd.dim_compound WHERE inchikey=%s",
                                    (hit[0],))
                        hit2 = cur.fetchone()
                        if hit2:
                            match = (hit2[0], 'crossref')
                            break
            if match:
                cur.execute("""
                    INSERT INTO dwd.dim_compound_xref
                        (compound_sk, source_system, source_record_id,
                         match_rule, match_confidence, batch_id)
                    VALUES (%s,'KEGG',%s,%s,0.95,%s)
                    ON CONFLICT (source_system, source_record_id) DO NOTHING
                """, (match[0], r["entry"], match[1], batches["KEGG"]))
                n_xref += cur.rowcount
    return n_comp, n_fact, n_xref


# ---------------------------------------------------------------------------
def main():
    print("[1/5] ChEBI 本体 BFS（CHEBI:35191 triterpene）...")
    entities = chebi_bfs()
    chebi_rows = chebi_compound_rows(entities)
    chebi_hydro = [r for r in chebi_rows if is_hydrocarbon(r["formula"])]
    print(f"    其中纯烃三萜 {len(chebi_hydro)} 个")

    print("[2/5] LIPID MAPS 下载 LMPR0106 全类表 ...")
    lm_rows = lipidmaps_rows()
    lm_hydro = [r for r in lm_rows
                if is_hydrocarbon(r.get("formula"))]
    print(f"    纯烃 C25-35 {len(lm_hydro)} 个 / 全类 {len(lm_rows)} 个")

    print("[3/5] KEGG COMPOUND 检索 ...")
    kegg_rows = kegg_entries()

    batches = {src: str(uuid.uuid4()) for src in ("CHEBI", "LIPIDMAPS", "KEGG")}
    conn = psycopg.connect(**DB_CONF)
    try:
        with conn.transaction():
            with conn.cursor() as cur:
                params = {
                    "chebi": {"root": CHEBI_ROOT, "max_nodes": MAX_CHEBI_NODES},
                    "lipidmaps": {"classes": LM_CLASSES, "endpoint": "rest download"},
                    "kegg": {"keywords": KEGG_KEYWORDS, "host": "rest.kegg.jp"},
                }
                for src, rows in (("CHEBI", chebi_rows), ("LIPIDMAPS", lm_rows),
                                  ("KEGG", kegg_rows)):
                    cur.execute(f"""
                        INSERT INTO meta.fetch_batch
                            (batch_id, source_code, snapshot_label, source_release,
                             request_params, record_count, fetch_finished_at, status)
                        VALUES (%s,%s,%s,'live API ({src})',%s,%s,now(),'success')
                    """, (batches[src], src, f"triterpene_ext_{SNAP_DATE}",
                          json.dumps(params[src.lower()], ensure_ascii=False),
                          len(rows)))
        print("[4/5] ODS 落地 ...")
        n_che, n_lm, n_kegg = insert_ods(conn, chebi_rows, lm_rows, kegg_rows, batches)
        conn.commit()
        print(f"    chebi_entity={n_che}  lipidmaps={n_lm}  kegg={n_kegg}")

        print("[5/5] DWD ETL ...")
        nc, nf, nx = run_etl(conn, chebi_rows, lm_rows, kegg_rows, batches)
        conn.commit()
        print(f"    dim_compound 处理={nc}  fact_property={nf}  xref={nx}")
    finally:
        conn.close()

    summary = {
        "date": SNAP_DATE,
        "batches": batches,
        "chebi": {"nodes": len(entities), "entities": len(chebi_rows),
                  "hydrocarbon": len(chebi_hydro)},
        "lipidmaps": {"total": len(lm_rows), "hydrocarbon": len(lm_hydro)},
        "kegg": {"entries": len(kegg_rows),
                 "with_structure": sum(1 for r in kegg_rows if r.get("smiles") or r.get("inchi") or r.get("inchikey"))},
        "compounds": {
            "chebi_hydro": [{"chebi_id": r["chebi_id"], "name": r["name"],
                             "formula": r["formula"], "inchikey": r["standard_inchikey"]}
                            for r in chebi_hydro],
            "lipidmaps_hydro": [{"lm_id": r["lm_id"], "name": r["name"],
                                 "formula": r["formula"], "inchikey": r["inchi_key"]}
                                for r in lm_hydro],
            "kegg": [{"entry": r["entry"], "name": r["name"], "formula": r["formula"],
                      "dblinks": r["dblinks"]} for r in kegg_rows],
        },
    }
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "reports",
                       "external_lipid_ingest_summary.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2, default=str)
    print(f"摘要已写入 {os.path.normpath(out)}")


if __name__ == "__main__":
    main()
