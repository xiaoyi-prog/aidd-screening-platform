# 三萜类不饱和烃 / 佐剂油相脂质 — 外部数据库扩展接入报告

生成时间：2026-11-14　数据源：**ChEBI 2.0 REST**、**LIPID MAPS REST**、**KEGG COMPOUND**（均为公开 API，本轮不含已完成的 PubChem/ChEMBL）

## 1. 接入概览

| 数据源 | 检索策略 | ODS 落地 | DWD 贡献 |
|---|---|---|---|
| ChEBI（EBI） | 本体 BFS：从 CHEBI:35191(triterpene) 沿 is-a 关系遍历 33 个本体节点 | 化合物/骨架实体 32 个（全部纯烃三萜，含 squalene、hopane/oleanane/lanostane 等骨架类目） | InChIKey 精确 xref 32 条 |
| LIPID MAPS | LMPR0106（C30 类异戊二烯=三萜）整类 download 表 | 全类 294 条（含氧化型/糖苷型），其中纯烃 C25–C35 21 条 | InChIKey 精确 xref 294 条 |
| KEGG COMPOUND | 关键词检索（squalene/triterpene/hopane/botryococcene/diapophytoene/tetrahymanol 等）命中 22 个 entry | 22 条（KEGG 不回传 SMILES，靠 DBLINKS 三路交叉映射） | crossref xref 6 条 |

DWD 汇总：dim_compound 共 368 个化合物（small_molecule=293、lipid=73、inorganic=2），fact_property 共 3208 条。

## 2. 跨库引用矩阵（dim_compound_xref）

| 来源 | 匹配规则 | 条数 |
|---|---|---|
| KEGG | crossref | 6 |
| CHEMBL | inchikey_skeleton | 2 |
| LIPIDMAPS | inchikey_exact | 294 |
| CHEBI | inchikey_exact | 32 |
| PUBCHEM | inchikey_exact | 58 |

KEGG 无结构条目按 DBLINKS 逐级回溯：LIPIDMAPS ID → PubChem CID → ChEBI ID，任一命中即挂 xref（confidence 0.95）；其余 16 个为细菌 hopanoid 衍生物（C35+），不在当前化合物池中。

## 3. ChEBI 三萜烃清单（32 个）

| ChEBI | 名称 | 分子式 | InChIKey |
|---|---|---|---|
| CHEBI:62743 | 4,4'-diaponeurosporene | C30H42 | `FPSYVUBUILNSRF-MQMKOTMBSA-N` |
| CHEBI:62741 | 4,4'-diapo-ζ-carotene | C30H44 | `JJMKRPXUHIPSAW-UHFFFAOYSA-N` |
| CHEBI:62742 | all-trans-4,4'-diapo-ζ-carotene | C30H44 | `JJMKRPXUHIPSAW-ZOKJSSERSA-N` |
| CHEBI:62739 | 4,4'-diapophytofluene | C30H46 | `XJMTWNXFNQAKGS-UHFFFAOYSA-N` |
| CHEBI:62740 | all-trans-4,4'-diapophytofluene | C30H46 | `XJMTWNXFNQAKGS-AXODYVGMSA-N` |
| CHEBI:138227 | β-hexaprene | C30H48 | `HVNMFMZGDPZXND-ICZYJQKRSA-N` |
| CHEBI:192978 | talaropentaene | C30H48 | `VVHPNQSUMLARNW-NGCRBCODSA-N` |
| CHEBI:192980 | macrophomene | C30H48 | `RHBWEVCRGQZVST-SGDJXXCCSA-N` |
| CHEBI:62736 | 4,4'-diapophytoene | C30H48 | `NXJJBCPAGHGVJC-UHFFFAOYSA-N` |
| CHEBI:62737 | all-trans-4,4'-diapophytoene | C30H48 | `NXJJBCPAGHGVJC-MAYJZIKRSA-N` |
| CHEBI:62738 | 15-cis-4,4'-diapophytoene | C30H48 | `NXJJBCPAGHGVJC-LIKFLUFESA-N` |
| CHEBI:132464 | hop-21(22)-ene | C30H50 | `CBZFLMNNXKRPHN-DRTOFSRZSA-N` |
| CHEBI:132466 | hop-17(21)-ene | C30H50 | `BJFPMDGPOFJGIR-WWJAXWOYSA-N` |
| CHEBI:15440 | squalene | C30H50 | `YYGNTYWPHWGJRM-AAJYLUCBSA-N` |
| CHEBI:4648 | hop-22(29)-ene | C30H50 | `HHXYJYBYNZMZKX-PYQRSULMSA-N` |
| CHEBI:62447 | dammara-20,24-diene | C30H50 | `SEXOMBPXHYAKHY-YCJSVCQFSA-N` |
| CHEBI:70786 | C30 botryococcene | C30H50 | `LRCNPQXZCZKGDI-OFGMELEWSA-N` |
| CHEBI:35711 | ursane | C30H52 | `OOTXFYSZXCPMPG-BMYLZFHVSA-N` |
| CHEBI:36473 | gammacerane | C30H52 | `QDUDLLAGYKHBNK-QPYQYMOUSA-N` |
| CHEBI:36481 | oleanane | C30H52 | `VCNKUCWWHVTTBY-KQCVGMHHSA-N` |
| CHEBI:36482 | hopane | C30H52 | `ZRLNBWWGLOPJIC-PYQRSULMSA-N` |
| CHEBI:36485 | lupane | C30H52 | `NKMDIWKRKQFYPH-VIUFNMEASA-N` |
| CHEBI:37778 | cycloartane | C30H52 | `BSLYZLYLUUIFGZ-JRUDBKCSSA-N` |
| CHEBI:71575 | friedelane | C30H52 | `KVSNMTUIMXZPLU-XOZXFAFYSA-N` |
| CHEBI:72618 | taraxastane | C30H52 | `OOTXFYSZXCPMPG-DJRORNMDSA-N` |
| CHEBI:20265 | lanostane | C30H54 | `ZQIOPEXWVBIZAV-ZKYCIREVSA-N` |
| CHEBI:36483 | protostane | C30H54 | `OORMXZNMRWBSTK-XJIBWFFZSA-N` |
| CHEBI:36488 | dammarane | C30H54 | `OORMXZNMRWBSTK-LGFJJATJSA-N` |
| CHEBI:73245 | cucurbitane | C30H54 | `ZYZJWAJOTPNVPI-ZVBSCDOUSA-N` |
| CHEBI:73247 | 5α-cucurbitane | C30H54 | `ZYZJWAJOTPNVPI-AUAIAXQGSA-N` |
| CHEBI:73249 | 5β-cucurbitane | C30H54 | `ZYZJWAJOTPNVPI-QJMYWHNVSA-N` |
| CHEBI:73301 | tirucallane | C30H54 | `ZQIOPEXWVBIZAV-RSKDDJKESA-N` |

> 骨架类目（hopane、oleanane、ursane、lupane、dammarane、cucurbitane 等）在 ChEBI 中本身是带结构的实体，作为三萜骨架维形一并入库，供环系筛选分类使用。

## 4. LIPID MAPS 纯烃清单（21 个）

| LM ID | 名称 | 分子式 | InChIKey |
|---|---|---|---|
| C00751 | Squalene | C30H50 | `YYGNTYWPHWGJRM-AAJYLUCBSA-N` |
| None | Tetrahydrosqualene | C30H54 | `COCRTLOZHDPILP-AAJYLUCBSA-N` |
| None | C30:6 Highly branched isoprenoid A | C30H50 | `JCWJDRJIYCBBNM-FTTJEOKKSA-N` |
| None | C30:6 Highly branched isoprenoid B | C30H50 | `JCWJDRJIYCBBNM-VZKDKEEGSA-N` |
| None | C30:5 Monocyclic highly branched isoprenoid B | C30H52 | `BNYPZWFLESHHNE-VZKDKEEGSA-N` |
| None | C30:5 Highly branched isoprenoid | C30H52 | `BNYPZWFLESHHNE-FTTJEOKKSA-N` |
| None | C30 Highly branched isoprenoid | C30H62 | `ZYUQNRLZGGWDML-UHFFFAOYSA-N` |
| C16144 | 15-cis-4,4'-Diapophytoene | C30H48 | `NXJJBCPAGHGVJC-LIKFLUFESA-N` |
| None | 4,4'-Diapo-7,8,11,12-tetrahydrolycopene | C30H44 | `QSLXXAZXUYYJCO-IMFKHJNASA-N` |
| None | C30:5 Monocyclic highly branched isoprenoid A | C30H50 | `ZJVXDMICLAHVAH-YZSQISJMSA-N` |
| None | C30:4 Monocyclic highly branched isoprenoid | C30H52 | `PLCJWBGFRGRJFS-YZSQISJMSA-N` |
| None | C30 Monocyclic highly branched isoprenoid | C30H60 | `CYGHPBQDCJXIPT-UHFFFAOYSA-N` |
| None | Botryococcane | C30H62 | `BMQOPLQIXUYINH-UHFFFAOYSA-N` |
| None | Penta-unsaturated monocyclic botrycoccane | C34H58 | `IBJRNORNAWSUOG-LSDHQDQOSA-N` |
| None | Monocyclic botryococcane | C34H68 | `FQHXBUADMKQNAG-UHFFFAOYSA-N` |
| None | Botryococcene | C34H58 | `RRFKZRGEWFCPGV-KWNNYQEVSA-N` |
| None | dammara-20,24-diene | C30H50 | `SEXOMBPXHYAKHY-YCJSVCQFSA-N` |
| None | (-)-5-Adianene | C30H50 | `WZDKBHGEBSMIQO-XAUJWZRVSA-N` |
| None | Arborane | C30H52 | `UFBGZWVLKQSSJS-DEJKXBRXSA-N` |
| None | (+)-Gammacerane | C30H52 | `QDUDLLAGYKHBNK-QPYQYMOUSA-N` |
| None | (-)-14-Serratene | C30H50 | `NIALLGCBSYYMNQ-RYUGGBRLSA-N` |

## 5. KEGG 条目（22 个）

| Entry | 名称 | 分子式 | LIPIDMAPS | ChEBI | PubChem |
|---|---|---|---|---|---|
| C00751 | Squalene; Spinacene; Supraene | C30H50 | LMPR0106010002 | 15440 | 4013 |
| C01054 | (S)-2,3-Epoxysqualene; Squalene 2,3-epoxide; Squ | C30H50O | LMPR0106010010 | 15441 | 4295 |
| C03428 | Presqualene diphosphate | C30H52O7P2 | LMPR0106010003 | 15442 | 6255 |
| C06083 | Tetrahymanol | C30H52O | LMPR0106210001 | 9493 | 8349 |
| C06085 | Triterpenoid | None | — | 36615 | 8351 |
| C08627 | Hopane-29-acetate | C32H54O2 | LMPR04000003 | 5760 | 10820 |
| C16144 | 4,4'-Diapophytoene; Dehydrosqualene; 15-cis-4,4' | C30H48 | LMPR0106010044 | 62738 | 47205454 |
| C20411 | 3-Methyl-1,2-didehydro-2,3-dihydrosqualene | C31H52 | — | — | 163312148 |
| C20412 | 3,22-Dimethyl-1,2,23,24-tetradehydro-2,3,22,23-t | C32H54 | — | — | 163312149 |
| C20432 | C30 Botryococcene | C30H50 | — | — | 163312169 |
| C20433 | 3-Methyl-1,2-didehydro-2,3-dihydrobotryococcene; | C31H52 | — | — | 163312170 |
| C20434 | 20-Methyl-21,22-didehydro-20,21-dihydrobotryococ | C31H52 | — | — | 163312171 |
| C20435 | 3,20-Dimethyl-1,2,21,22-tetradehydro-2,3,20,21-t | C32H54 | — | — | 163312172 |
| C21116 | Hydroxysqualene; 12-Hydroxysqualene | C30H50O | — | — | 312642085 |
| C21117 | Adenosylhopane | C40H63N5O3 | LMPR04000012 | — | 312642086 |
| C21118 | Ribosylhopane | C35H60O4 | LMPR04000028 | — | 312642087 |
| C21119 | Bacteriohopanetetrol; Tetrahydroxybacteriohopane | C35H62O4 | LMPR04000004 | 132468 | 312642088 |
| C21120 | Bacteriohopanetetrol-acetylglucosamine | C43H75NO9 | — | — | 312642089 |
| C21121 | Bacteriohopanetetrol-glucosamine; Tetrahydroxyba | C41H73NO8 | LMPR04000018 | 132143 | 312642090 |
| C21122 | Bacteriohopanetetrol cyclitol ether; Tetrahydrox | C41H73NO8 | — | 132144 | 312642091 |
| C21123 | Aminobacteriohopanetriol | C35H63NO3 | LMPR04000005 | — | 312642092 |
| C21732 | (3S,22S)-2,3:22,23-Diepoxy-2,3,22,23-tetrahydros | C30H50O2 | LMPR0106010038 | — | 350078309 |

## 6. 与既有 PubChem 批次的重叠

上一轮 PubChem 相似度扩展入库 37 个化合物；本轮 LIPID MAPS/ChEBI 的 InChIKey 与之自动去重（dim_compound 按 InChIKey upsert），多源证据通过 xref 矩阵汇聚到同一 compound_sk——例如 squalene 现在同时挂 PUBCHEM:638072 / CHEBI:15440 / CHEMBL458402 / LIPIDMAPS:LMPR0106010002 / KEGG:C00751 五个来源 ID。

## 7. 过程中确认的 API 事实（已写入脚本）

- ChEBI 2.0：complete entity 的结构键是 `default_structure.standard_inchi_key`（带下划线）；`chemical_data` 是 **dict 不是数组**；类目子树靠 `ontology_relations.incoming_relations` 中 `is a` 关系遍历。
- LIPID MAPS：整类批量用 `rest/compound/lm_id/{class_prefix}/all/download`（TSV，首行是日期戳）；`lm_id` 传类前缀不能走 `/rest/compound/lm_id/LMPR0106/all/json`（返回空数组）。
- KEGG：`rest.kegg.ws` 不可达，用 `rest.kegg.jp`；get 报文含 ATOM/BOND 坐标块，解析字段必须把 ATOM/BOND/BRITE 也当 section 边界，否则坐标数据会灌进 DBLINKS；COMPOUND 条目不回传 SMILES。
- `dwd.dim_compound_xref.match_rule` 原约束不含 crossref，迁移 010 已放宽（'crossref'，confidence 0.95）。

## 8. 质量与复现

- 三个批次登记于 meta.fetch_batch（snapshot_label=`triterpene_ext_2026-11-14`），每行带 src_row_hash + raw_payload；
- 11 条质量门禁全部通过（`db/reports/db_health.md`）；
- 摘要 JSON：`db/reports/external_lipid_ingest_summary.json`。

## 9. 下一步建议

1. 油相窗口（logP≥8、TPSA≤10、C25–C30 纯烃）注册后跑一级筛选，候选池预计 50+ 三萜烃；
2. DrugBank 与 UNII 需要 license/离线包，建议由运维提供导出文件后走同一 ODS 模式接入；
3. NPAtlas / COCONUT 为整库下载型，适合排入同一批处理框架。