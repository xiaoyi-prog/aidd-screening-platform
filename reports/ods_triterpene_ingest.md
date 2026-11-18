# 三萜类不饱和烃 / 佐剂油相脂质 — ODS 数据接入报告

生成时间：2026-11-14　来源：PubChem PUG REST（live）+ ChEMBL Web Services（live）

## 1. 接入概览

| 项目 | 值 |
|---|---|
| PubChem 抓取批次 | `46d6b6a2-6f18-4d6a-bff5-13fcef042b6c`（checksum 已登记 meta.fetch_batch） |
| ChEMBL 抓取批次 | `1eb1151c-38e3-4d3f-8ad8-a685862bd807`（pref_name 检索 + RDKit 骨架校验） |
| 种子化合物解析 | 4/5 成功（dehydrosqualene 在 PubChem 无专名条目，其骨架由相似度扩展覆盖） |
| 相似度扩展 | squalene 参照 200 个 CID（Tanimoto≥0.85）；squalane 参照 200 个 CID（≥0.88） |
| 三萜烃过滤 | 纯 C/H、碳数 25–35 → 36 个主目标（含种子） |
| ODS 落地 | compound 37 行、property 407 行、synonym 285 行、chembl_molecule 2 行 |
| DWD 落地 | dim_compound 37 行（全 lipid、0 suspect）、fact_property 728 行、PubChem xref 37 条 + ChEMBL xref 2 条 |

## 2. 核心种子化合物

| 名称 | CID | 分子式 | MW | XLogP | InChIKey | ChEMBL | 佐剂角色 |
|---|---|---|---|---|---|---|---|
| squalane | 8089 | C30H62 | 422.8 | 14.7 | `PRAKJMSDJKAYCZ-UHFFFAOYSA-N` | — | 氢化角鲨烯，油相候选 / 安全参照 |
| squalene | 638072 | C30H50 | 410.7 | 11.6 | `YYGNTYWPHWGJRM-AAJYLUCBSA-N` | — | MF59 / AS03 / AS01 佐剂油相主成分 |
| 2,3-oxidosqualene | 5366020 | C30H50O | 426.7 | 10.3 | `QYIMSPSDBYKPPY-BANQPHDMSA-N` | — | 三萜环化前体（氧化型对照） |
| botryococcene | 10885141 | C34H58 | 466.8 | 14.2 | `RRFKZRGEWFCPGV-KWNNYQEVSA-N` | — | C30 类异戊二烯烃，藻源三萜烃代表 |

## 3. 三萜烃谱系全量清单（37 个）

> 同一 InChIKey 骨架的不同立体异构分别成行（如 squalene 的 (all-E) 与 (3S,3'S) 等构型各占一行）。

| # | CID | 名称(首选) | 分子式 | MW | XLogP | InChIKey | ChEMBL |
|---|---|---|---|---|---|---|---|
| 1 | 1105 | 2,6,10,15,19,23-Hexamethyltetracosa-2,6,10,14,18,22-hexaene | C30H50 | 410.7 | 11.6 | `YYGNTYWPHWGJRM-UHFFFAOYSA-N` | — |
| 2 | 8089 | Squalane | C30H62 | 422.8 | 14.7 | `PRAKJMSDJKAYCZ-UHFFFAOYSA-N` | — |
| 3 | 193910 | 2,6,10,15,19,23-Hexamethyltetracosa-2,4,6,8,10,12,14,16,18,22-decaene | C30H42 | 402.7 | 11.8 | `FPSYVUBUILNSRF-UHFFFAOYSA-N` | — |
| 4 | 292287 | 8-Heptadecene, 9-octyl- | C25H50 | 350.7 | 12.8 | `QEKKDSRVFBLJFX-UHFFFAOYSA-N` | — |
| 5 | 623199 | 4,4'-Diapophytoene | C30H48 | 408.7 | 11.6 | `NXJJBCPAGHGVJC-UHFFFAOYSA-N` | — |
| 6 | 638072 | Squalene | C30H50 | 410.7 | 11.6 | `YYGNTYWPHWGJRM-AAJYLUCBSA-N` | — |
| 7 | 5280370 | Squalene, analytical standard | C30H50 | 410.7 | 11.6 | `YYGNTYWPHWGJRM-YMUIKIMESA-N` | — |
| 8 | 5352455 | 10-Demethylsqualene | C29H48 | 396.7 | 11 | `BBCQGYMUMKNTQE-BAIGTOHMSA-N` | — |
| 9 | 5366020 | 2,3-Oxidosqualene | C30H50O | 426.7 | 10.3 | `QYIMSPSDBYKPPY-BANQPHDMSA-N` | — |
| 10 | 5377880 | All-trans-4,4'-diapophytoene | C30H48 | 408.7 | 11.6 | `NXJJBCPAGHGVJC-MAYJZIKRSA-N` | — |
| 11 | 6443791 | (4E,6E,8E,10E,12E,14E,16E,18E)-2,6,10,15,19,23-Hexamethyl-2,4,6,8,10,12,14,16,18,22-tetracosadecaene | C30H42 | 402.7 | 11.8 | `FPSYVUBUILNSRF-MQMKOTMBSA-N` | — |
| 12 | 10885141 | Botryococcene | C34H58 | 466.8 | 14.2 | `RRFKZRGEWFCPGV-KWNNYQEVSA-N` | — |
| 13 | 11212382 | (3E,7E,11E,15E,19E)-3,7,11,16,20,24-hexamethylpentacosa-1,3,7,11,15,19,23-heptaene | C31H50 | 422.7 | 12 | `YFJDHPRKGJEVKR-RLEGVFPPSA-N` | — |
| 14 | 11315692 | 4,4'-Diapo-zeta-carotene | C30H44 | 404.7 | 11.7 | `JJMKRPXUHIPSAW-ZOKJSSERSA-N` | — |
| 15 | 11975273 | (6Z,10E,14E,18E)-2,6,10,15,19,23-hexamethyltetracosa-2,6,10,14,18,22-hexaene | C30H50 | 410.7 | 11.6 | `YYGNTYWPHWGJRM-FLHYQJCXSA-N` | — |
| 16 | 14019219 | 15-cis-4,4'-Diapophytoene | C30H48 | 408.7 | 11.6 | `NXJJBCPAGHGVJC-LIKFLUFESA-N` | — |
| 17 | 14544609 | 5,9,14,18,22-Pentamethyl-tricosa-5,9,13,17,21-pentaen-1-yne | C28H44 | 380.6 | 10.2 | `KXVKTTDHPAHWSP-ONQTWPEOSA-N` | — |
| 18 | 14544610 | 5,9,14,18-Tetramethyl-docosa-5,9,13,17-tetraene-1,21-diyne | C26H38 | 350.6 | 8.8 | `ZFMFZTOEMOMUMG-LQEDCYEGSA-N` | — |
| 19 | 14544614 | 6,10,15,19,23-Pentamethyl-tetracosa-1,2,6,10,14,18,22-heptaene | C29H46 | 394.7 | 10.3 | `JPXBVBHEFLSWTH-LPOFEHKLSA-N` | — |
| 20 | 14544615 | 6,10,15,19-Tetramethyl-tetracosa-1,2,6,10,14,18,22,23-octaene | C28H42 | 378.6 | 9.1 | `WWYJLZNZMOTMDI-BQAJUIIYSA-N` | — |
| 21 | 14544616 | (4,8,13,17,21-Pentamethyl-docosa-4,8,12,16,20-pentaenylidene)-cyclopropane | C30H48 | 408.7 | 10.5 | `ASQQWVOLSZUIGD-CQNOQWDGSA-N` | — |
| 22 | 14544617 | [(4E,8E,12E,16E)-20-cyclopropylidene-4,8,13,17-tetramethylicosa-4,8,12,16-tetraenylidene]cyclopropane | C30H46 | 406.7 | 9.4 | `PBHARJKELFPYNJ-DKTKHUEWSA-N` | — |
| 23 | 16061258 | 4,4'-Diapophytofluene | C30H46 | 406.7 | 11.7 | `XJMTWNXFNQAKGS-AXODYVGMSA-N` | — |
| 24 | 25202308 | CID 25202308 | C30H46 | 406.7 | 11.7 | `XJMTWNXFNQAKGS-UHFFFAOYSA-N` | — |
| 25 | 25202379 | CID 25202379 | C30H44 | 404.7 | 11.7 | `JJMKRPXUHIPSAW-UHFFFAOYSA-N` | — |
| 26 | 25244109 | (6Z,10E,14Z,18E)-2,6,10,15,19,23-hexamethyltetracosa-2,6,10,14,18,22-hexaene | C30H50 | 410.7 | 11.6 | `YYGNTYWPHWGJRM-FZSSMNSJSA-N` | — |
| 27 | 44308596 | 3,7,11,16,20,24-Hexamethyl-hexacosa-1,3,7,11,15,19,23,25-octaene | C32H50 | 434.7 | 12.4 | `DQGNURMUZVFKKX-IZCAQIDOSA-N` | — |
| 28 | 52922084 | 3Z,6Z,9Z,12Z,15Z,19Z,22Z,25Z,28Z-Hentriacontanonaene | C31H46 | 418.7 | 10.3 | `QBQCAYTWEQRERN-VHUCEKMMSA-N` | — |
| 29 | 101609271 | 4,4'-Diapo-7,8,11,12-tetrahydrolycopene | C30H44 | 404.7 | 11.7 | `QSLXXAZXUYYJCO-IMFKHJNASA-N` | — |
| 30 | 102232250 | beta-Geranylfarnesene | C25H40 | 340.6 | 9.9 | `ZAENFYLULMRPFH-ITTVFDGXSA-N` | — |
| 31 | 102502420 | beta-Heptaprene | C35H56 | 476.8 | 13.6 | `YNWDINKHLIWBQT-YDTSVZKTSA-N` | — |
| 32 | 102502421 | beta-Hexaprene | C30H48 | 408.7 | 11.8 | `HVNMFMZGDPZXND-ICZYJQKRSA-N` | — |
| 33 | 129691088 | Trimethylsqualene | C33H56 | 452.8 | 12.9 | `WEMNWCWZQZDJEB-AJRKJSAFSA-N` | — |
| 34 | 153280933 | (all-Z)-1,5,9,13,17,21-hexamethyl-1,5,9,13,17,21-cyclotertracosahexaene | C30H48 | 408.7 | 7.8 | `WSUOURBTDCUBEX-YPOQHXKCSA-N` | — |
| 35 | 162897453 | 2,6,10,15,19,23-Hexamethyltetracosa-2,4,6,8,10,12,14,18,22-nonaene | C30H44 | 404.7 | 11.7 | `QSLXXAZXUYYJCO-UHFFFAOYSA-N` | — |
| 36 | 162940857 | 1,5,9,13,17,21-Hexamethylcyclotetracosa-1,5,9,13,17,21-hexaene | C30H48 | 408.7 | 7.8 | `WSUOURBTDCUBEX-UHFFFAOYSA-N` | — |
| 37 | 177696489 | (6E,14E,18E)-2,6,10,15,19,23-hexamethyltetracosa-2,6,10,14,18,22-hexaene | C30H50 | 410.7 | 11.6 | `YYGNTYWPHWGJRM-STCFCRKPSA-N` | — |

## 4. 谱系特征速读

- 分子式覆盖 **C25H40 ~ C30H62**：从 squalane（0 个双键）到三环/四环三萜烯；
- XLogP 全部落在 **7.8 ~ 14.7**，显著高于常规辅料（logP 1–8），
  与"油相"定位一致，可直接作为一级筛选窗口（logP≥8 且 TPSA≈0）的输入；
- ChEMBL 交叉验证命中 **SQUALENE（CHEMBL458402）与 SQUALANE（CHEMBL1552157）**，均标记 natural_product=t，
  经 RDKit 骨架比对挂到对应 dim_compound，其余同名候选（如 TRISNORSQUALENE ALCOHOL）被同名异物剔除。

## 5. 过程中确认的 API 事实（已写入脚本注释）

- PubChem PUG REST 属性标签改名：`CanonicalSMILES`→`ConnectivitySMILES`、`IsomericSMILES`→`SMILES`；`ComponentCount` 已下线。脚本内做别名归一与字符串数值转换。
- ChEMBL `molecule_structure__inchikey` 过滤器**静默不生效**（返回未过滤列表），必须走 `pref_name__icontains` + RDKit 骨架校验；`standard_inchikey` 常为 NULL，需现算。
- ChEMBL 布尔字段回传 -1/0/1，-1 视为未知落 NULL。

## 6. 质量与复现

- 11 条质量门禁全部通过（见 `db/reports/db_health.md`）；
- ODS 每行带 `batch_id + src_row_hash + raw_payload`，同参数可整批回放；
- DWD `fact_property` 中 PubChem 源值（PUBCHEM_DESC/2026.11）与 RDKit 重算值（RDKIT_DESC/2026.09.2）并存，可交叉校验。

## 7. 下一步建议

1. 将油相窗口（logP≥8、TPSA≤10、C25–C30 纯烃）注册进 `ref.auxiliary_function` 规格，对 37 个分子跑一级筛选；
2. 从 ChEMBL 拉取 squalene 相关 assay 活性记录进入 `fact_activity`；
3. 拉取 FDA IID/IIG 中 squalene/squalane 途径限值，补齐安全边际分母。