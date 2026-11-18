# -*- coding: utf-8 -*-
"""
polymer_sim.py — 步骤2：高分子链段与蛋白/小分子相互作用模拟评估
=================================================================
目标：评估辅料高分子/表面活性剂链段（如 PS80、甘油三酯链、squalene）与
      蛋白抗原/小分子 API 的相互作用，重点评估【抑制结晶】等功能性效果。

三层实现策略（按可用工具自动降级）：
  A. MOF 命令行（MOE / Polymer-Builder） —— 若环境变量 MOE_BIN / POLYMER_BUILDER_BIN 存在
  B. RDKit 代理模型 —— 构链 + 描述符 + H-bond/接触近似打分（本文件默认路径，纯离线）
  C. 打通预留 —— docking/MM-GBSA 结果可经 CLI import 进 dwd.fact_polymer_interaction

仅写代码，未运行。依赖：psycopg2, rdkit（venv 已具备）。
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import subprocess
import tempfile
from dataclasses import dataclass, field, asdict
from typing import Optional

DB_DSN = os.environ.get("AIDD_DB_DSN",
                        "postgresql://aidd_app:aidd_app@localhost:55432/aidd")

# =====================================================================
# 1. 高分子链构建（Polymer-Builder 思路：重复单元 → N 聚 → 整链 SMILES）
# =====================================================================

@dataclass
class PolymerChain:
    polymer_code: str
    polymer_class: str            # surfactant / polymer / lipid_chain
    monomer_smiles: str
    dp: int                       # degree of polymerization
    chain_smiles: str = ""
    builder_tool: str = "rdkit_builder"
    builder_params: dict = field(default_factory=dict)

    def to_row(self) -> dict:
        return {
            "polymer_code": self.polymer_code,
            "polymer_class": self.polymer_class,
            "monomer_smiles": self.monomer_smiles,
            "degree_of_polymerization": self.dp,
            "chain_smiles": self.chain_smiles,
            "builder_tool": self.builder_tool,
            "builder_params": json.dumps(self.builder_params),
        }


def build_chain_rdkit(monomer_smiles: str, dp: int, tail_smiles: str = "") -> str:
    """线性缩聚近似：将重复单元以 SMILES 字符串拼接（Polymer-Builder 的
    'repeat unit concatenation' 最简实现）。

    注意：这是拓扑近似，不保证化学价键合理性；产链后必须经 RDKit
    MolFromSmiles 校验，不合理则降级为分单元评估。
    """
    from rdkit import Chem
    unit = monomer_smiles.rstrip(".")
    core = f"{tail_smiles}" if tail_smiles else ""
    chain = core + ".".join([unit] * dp) if core else ".".join([unit] * dp)
    mol = Chem.MolFromSmiles(chain)
    if mol is None:
        # 拼接失败 → 退化为不连接的多单元（disconnected components）
        # 仍然可用于组分级相互作用打分
        chain = ".".join([unit] * dp)
        if Chem.MolFromSmiles(chain) is None:
            raise ValueError(f"monomer_smiles 无法解析: {monomer_smiles}")
    return Chem.MolToSmiles(mol)


def build_chain_polymer_builder(monomer_smiles: str, dp: int,
                                bin_path: str) -> str:
    """调用外部 Polymer-Builder CLI（约定参数名，接入时按实际文档调整）。"""
    with tempfile.TemporaryDirectory() as td:
        inp = os.path.join(td, "in.json")
        outp = os.path.join(td, "out.json")
        with open(inp, "w", encoding="utf-8") as f:
            json.dump({"monomer": monomer_smiles, "dp": dp,
                       "topology": "linear"}, f)
        subprocess.run([bin_path, "build", "-i", inp, "-o", outp],
                       check=True, capture_output=True, timeout=600)
        with open(outp, encoding="utf-8") as f:
            return json.load(f)["chain_smiles"]


def build_chain(polymer_code: str, polymer_class: str,
                monomer_smiles: str, dp: int) -> PolymerChain:
    pb_bin = os.environ.get("POLYMER_BUILDER_BIN")
    if pb_bin and os.path.exists(pb_bin):
        chain = build_chain_polymer_builder(monomer_smiles, dp, pb_bin)
        tool = "polymer_builder"
    else:
        chain = build_chain_rdkit(monomer_smiles, dp)
        tool = "rdkit_builder"
    return PolymerChain(polymer_code, polymer_class, monomer_smiles, dp,
                        chain_smiles=chain, builder_tool=tool)


# 常用佐剂体系链段预设（MF59 / AS03 类油相+表面活性剂）
PRESET_POLYMERS = [
    # Tween 80 的聚氧乙烯山梨坦头部近似（重复 EO 单元）
    ("ps80_peo_head", "surfactant", "OCCO", 20),
    # 甘油三酯脂肪酸链（油酸链）
    ("triolein_oleoyl_chain", "lipid_chain", "CCCCCCCCC=CCCCCCCCC(=O)OCC(COC(=O)CCCCCCCC=CCCCCCCCC)COP(=O)(O)O", 1),
    # 角鲨烯链段（已在库中，供对照）
    ("squalene_segment", "lipid_chain", "C=C(C)CCC=C(C)CCC=C(C)CCC=C(C)CCC=C(C)C", 1),
    # AS03 的 α-生育酚
    ("alphatocopherol_chain", "lipid_chain", "Cc2c(C)c1oc(CCC(C)CCCC(C)CCCC(C)C)c3cc(O)ccc1c3CC", 1),
]


# =====================================================================
# 2. 相互作用打分
# =====================================================================

@dataclass
class InteractionScore:
    polymer_code: str
    partner_inchikey: str
    partner_kind: str
    assay_kind: str
    tool: str
    tool_version: str
    score_value: float
    score_unit: str
    detail: dict


def hbond_profile_rdkit(chain_smiles: str, partner_smiles: str) -> dict:
    """RDKit 代理：H 键供体/受体数目与可得性剖面（crystallization_inhibition 的
    关键特征：嵌段单元对溶质 H 键位点的竞争覆盖度）。"""
    from rdkit import Chem
    from rdkit.Chem import Lipinski
    m_c = Chem.MolFromSmiles(chain_smiles)
    m_p = Chem.MolFromSmiles(partner_smiles)
    if m_c is None or m_p is None:
        raise ValueError("SMILES 解析失败")
    return {
        "chain_hbd": Lipinski.NumHDonors(m_c),
        "chain_hba": Lipinski.NumHAcceptors(m_c),
        "partner_hbd": Lipinski.NumHDonors(m_p),
        "partner_hba": Lipinski.NumHAcceptors(m_p),
        # 覆盖度近似：链上受体能否饱和溶质供体（+供体饱和溶质受体）
        "hbond_coverage": min(1.0, Lipinski.NumHAcceptors(m_c) /
                              max(1, Lipinski.NumHDonors(m_p))),
        "hbond_coverage_rev": min(1.0, Lipinski.NumHDonors(m_c) /
                                  max(1, Lipinski.NumHAcceptors(m_p))),
    }


def crystallization_inhibition_score(chain_smiles: str,
                                     partner_smiles: str) -> float:
    """抑制结晶代理打分 [0,1]，越大越好。

    组成（文献一致的机制近似，供中筛排序；最终以 MD/实测 XRPD 复核）：
      w1 * H键覆盖度（两方向最小值）       0.40
      w2 * 链柔性（rotatable bond 密度）    0.25  —— 柔性链更易插入晶面
      w3 * 链-溶质 Tanimoto 相似性惩罚      -0.15 —— 太相似易共晶析出
      w4 * 疏水接触面（LogP 差值正相关）    0.20
    """
    from rdkit import Chem
    from rdkit.Chem import Descriptors, Lipinski, rdMolDescriptors, DataStructs

    m_c = Chem.MolFromSmiles(chain_smiles)
    m_p = Chem.MolFromSmiles(partner_smiles)
    prof = hbond_profile_rdkit(chain_smiles, partner_smiles)
    cov = min(prof["hbond_coverage"], prof["hbond_coverage_rev"])

    n_rot = Lipinski.NumRotatableBonds(m_c)
    heavy = m_c.GetNumHeavyAtoms() or 1
    flexibility = min(1.0, n_rot / heavy * 5)          # 经验缩放

    fp_c = rdMolDescriptors.GetMorganFingerprintAsBitVect(m_c, 2, 1024)
    fp_p = rdMolDescriptors.GetMorganFingerprintAsBitVect(m_p, 2, 1024)
    sim = DataStructs.TanimotoSimilarity(fp_c, fp_p)

    logp_c = Descriptors.MolLogP(m_c)
    logp_p = Descriptors.MolLogP(m_p)
    hydrophobic = min(1.0, abs(logp_c - logp_p) / 8)

    score = (0.40 * cov + 0.25 * flexibility
             - 0.15 * sim + 0.20 * hydrophobic)
    return round(min(1.0, max(0.0, score)), 4)


def moe_docking(chain_smiles: str, partner_smiles: str,
                moe_bin: str) -> float:
    """MOE 命令行对接（svl 脚本约定：dock.svl 输出 JSON 分数）。
    接入真实 MOE 时只需保证输出 {"score": float}。"""
    with tempfile.TemporaryDirectory() as td:
        lig = os.path.join(td, "lig.smi")
        out = os.path.join(td, "out.json")
        with open(lig, "w", encoding="utf-8") as f:
            f.write(chain_smiles + "\n")
        subprocess.run([moe_bin, "-batch", "dock.svl",
                        "-lig", lig, "-out", out],
                       check=True, capture_output=True, timeout=1800)
        with open(out, encoding="utf-8") as f:
            return float(json.load(f)["score"])


def evaluate_pair(chain: PolymerChain, partner_smiles: str,
                  partner_inchikey: str,
                  partner_kind: str = "small_molecule") -> list[InteractionScore]:
    """一条高分子链 × 一个搭档 → 全套相互作用评分（写库用 list）。"""
    results: list[InteractionScore] = []
    moe_bin = os.environ.get("MOE_BIN")

    # ① 结晶抑制（RDKit 代理，离线可用）
    ci = crystallization_inhibition_score(chain.chain_smiles, partner_smiles)
    results.append(InteractionScore(
        chain.polymer_code, partner_inchikey, partner_kind,
        "crystallization_inhibition", "rdkit_proxy", "2026.09.2",
        ci, "score_0_1", {"method": "hbond+flexibility+tanimoto proxy"}))

    # ② H 键剖面
    prof = hbond_profile_rdkit(chain.chain_smiles, partner_smiles)
    results.append(InteractionScore(
        chain.polymer_code, partner_inchikey, partner_kind,
        "h_bond_profile", "rdkit_proxy", "2026.09.2",
        prof["hbond_coverage"], "fraction", prof))

    # ③ MOE docking（可选，环境变量存在才执行）
    if moe_bin and os.path.exists(moe_bin):
        try:
            ds = moe_docking(chain.chain_smiles, partner_smiles, moe_bin)
            results.append(InteractionScore(
                chain.polymer_code, partner_inchikey, partner_kind,
                "docking", "moe_cli", os.environ.get("MOE_VERSION", "unknown"),
                ds, "kcal/mol", {}))
        except subprocess.CalledProcessError as exc:
            results.append(InteractionScore(
                chain.polymer_code, partner_inchikey, partner_kind,
                "docking", "moe_cli", "error", 0.0, "n/a",
                {"stderr": exc.stderr.decode(errors="replace")[-500:]}))

    return results


# =====================================================================
# 3. 蛋白搭档（抗原）—— 无 PDB 时退化为序列特征哈希
# =====================================================================

def protein_partner_key(sequence: str) -> str:
    """蛋白无 InChIKey，用 sha1(序列) 作为 partner_inchikey 占位，
    partner_kind='protein' 区分。"""
    return "PROT-" + hashlib.sha1(sequence.encode()).hexdigest()[:32]


# =====================================================================
# 4. 持久化
# =====================================================================

def persist_polymer_and_scores(chains: list[PolymerChain],
                               scores: list[InteractionScore],
                               run_id: Optional[str] = None) -> int:
    import psycopg2
    rows = 0
    with psycopg2.connect(DB_DSN) as conn, conn.cursor() as cur:
        for ch in chains:
            cur.execute("""
                INSERT INTO dwd.dim_polymer
                    (polymer_code, polymer_class, monomer_smiles,
                     degree_of_polymerization, chain_smiles,
                     builder_tool, builder_params)
                VALUES (%(polymer_code)s, %(polymer_class)s, %(monomer_smiles)s,
                        %(degree_of_polymerization)s, %(chain_smiles)s,
                        %(builder_tool)s, %(builder_params)s)
                ON CONFLICT (polymer_code) DO UPDATE
                    SET chain_smiles = EXCLUDED.chain_smiles,
                        builder_tool = EXCLUDED.builder_tool,
                        builder_params = EXCLUDED.builder_params
            """, ch.to_row())
        for s in scores:
            cur.execute("""
                INSERT INTO dwd.fact_polymer_interaction
                    (polymer_code, partner_inchikey, partner_kind,
                     assay_kind, tool, tool_version,
                     score_value, score_unit, detail, run_id)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
            """, (s.polymer_code, s.partner_inchikey, s.partner_kind,
                  s.assay_kind, s.tool, s.tool_version,
                  s.score_value, s.score_unit,
                  json.dumps(s.detail, ensure_ascii=False), run_id))
            rows += 1
        conn.commit()
    return rows


# =====================================================================
# 5. 主入口（演示：预设链 × 库内油相辅料）
# =====================================================================

def main() -> None:
    import psycopg2
    chains = [build_chain(code, cls, mono, dp)
              for code, cls, mono, dp in PRESET_POLYMERS]

    # 取库中油相辅料作为搭档（squalene / oleic acid 类）
    with psycopg2.connect(DB_DSN) as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT inchikey::text, COALESCE(smiles_isomeric, smiles_canonical)
            FROM dwd.dim_compound
            WHERE compound_class = 'lipid' AND smiles_isomeric IS NOT NULL
            LIMIT 20
        """)
        partners = cur.fetchall()

    all_scores: list[InteractionScore] = []
    for ch in chains:
        for ik, smi in partners:
            all_scores.extend(evaluate_pair(ch, smi, ik))

    n = persist_polymer_and_scores(chains, all_scores)
    print(f"[polymer_sim] chains={len(chains)} interactions_persisted={n}")


if __name__ == "__main__":
    main()
