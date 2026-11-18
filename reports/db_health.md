# AIDD 数据库健康检查报告

- 生成时间：2026-11-14 18:24:09
- 数据库：`aidd` @ 127.0.0.1:55432
- 服务器版本：PostgreSQL 16.9
- 服务端编码：UTF8　库大小：16 MB

## 1. 已安装扩展

| 扩展 | 版本 | 说明 |
|---|---|---|
| pg_trgm | 1.6 | text similarity measurement and index searching based on trigrams |
| pgcrypto | 1.3 | cryptographic functions |
| plpgsql | 1.0 | PL/pgSQL procedural language |

## 2. 对象清单

| Schema | 普通表 | 分区表 | 视图 | 物化视图 | 独立索引 | 外键 |
|---|---:|---:|---:|---:|---:|---:|
| ads | 11 | 0 | 2 | 1 | 7 | 20 |
| dwd | 9 | 0 | 1 | 0 | 13 | 29 |
| meta | 10 | 1 | 2 | 0 | 9 | 7 |
| ods | 16 | 0 | 1 | 0 | 21 | 16 |
| ref | 8 | 0 | 0 | 0 | 0 | 7 |
| **合计** | 54 | 1 | 6 | 1 | 50 | 79 |

## 3. 表级明细（行数 / 大小 / 注释）

| 表 | 行数(估算) | 大小 | 注释 |
|---|---:|---:|---|
| ads.candidate_pool | 21 | 64 kB | 候选池台账：一个 run 内每个分子的当前层级与存活状态，漏斗转化率的唯一口径 |
| ads.compound_score | 103 | 64 kB | 分项评分长表：每个分数都能回答"谁打的、按什么权重、依据是什么"，杜绝黑箱排名 |
| ads.mv_compound_feature_matrix (物化) | 21 | 56 kB | 分子特征宽表：把长表物性透视成一行一分子，供模型训练与批量打分；刷新用 REFRESH MATERIALIZED VIEW CONCURRENTLY ads.mv_compound_feature_matrix |
| ads.rank_result | 16 | 48 kB | 最终排名与结论：进入湿实验的推荐清单，含人工复核痕迹 |
| ads.run_stage_config | 5 | 32 kB | 每级筛选的阈值/权重/规则配置：允许同一批候选跑多套参数做对比实验 |
| ads.screen_run | 1 | 48 kB | 筛选任务：一次完整的五级漏斗执行，冻结模型快照与配置以保证可复现 |
| ads.stage1_ai_screen | 21 | 64 kB | 一级 AI 虚拟初筛结果：AI 模型对全量候选的零成本预判 + 规则命中明细 |
| ads.stage2_physchem_screen | 19 | 64 kB | 二级理化功能中筛：候选物性 vs 目标功能规格窗口的逐项匹配结果 |
| ads.stage3_safety_screen | 0 | 16 kB | 三级生物安全与配伍深筛：ADMET 风险 + 法规限值安全边际 + API-辅料配伍稳定性 |
| ads.stage4_modeling_screen | 0 | 16 kB | 四级建模分析：对接打分、MD 稳定性、聚集倾向与晶型干扰评估 |
| ads.stage5_scaleup_screen | 0 | 16 kB | 五级生产放大评估：成本、供应、GMP/药典合规与工艺兼容性 |
| ads.stage_trace | 40 | 120 kB | 逐级决策追溯：任何一个分子为何在这一级被淘汰/晋级，都能定位到输入快照、规则版本与模型版本 |
| dwd.bridge_compound_function | 32 | 48 kB | 辅料功能桥表：一个分子可承担多种功能（如 PVP 既是黏合剂又是增溶剂），二级筛选用它找候选集合 |
| dwd.dim_assay | 0 | 24 kB | DWD 测定方法维表：承载可信度分级，用于活性数据加权 |
| dwd.dim_compound | 368 | 632 kB | DWD 分子主数据：唯一键 InChIKey，去盐/去重后的标准结构单位（SCU） |
| dwd.dim_compound_xref | 392 | 200 kB | 分子-源记录映射：同一 InChIKey 可能来自 PubChem CID、ChEMBL ID、DrugBank ID，全部登记以支持回溯 |
| dwd.dim_excipient_grade | 0 | 24 kB | 辅料级别与供应信息：同一化合物不同级别（如 HPMC E5/E15）性能差异显著，必须分级别管理 |
| dwd.dim_target | 0 | 24 kB | DWD 靶点维表（含蛋白、转运体、离子通道；辅料相互作用同样需要） |
| dwd.fact_activity | 0 | 40 kB | DWD 活性事实：IC50/EC50/Ki/Kd/Tm 等，保留原始限定符与有效性注释 |
| dwd.fact_compatibility | 0 | 32 kB | DWD 配伍事实：API-辅料在不同温湿度/时长下的稳定性结果（DSC、HPLC 含量、有关物质） |
| dwd.fact_property | 3208 | 1448 kB | DWD 性质事实长表：计算值/实测值/预测值统一存放，用 value_type + model_version 区分来源 |
| meta.data_quality_result | 44 | 64 kB | 数据质量检查结果：每次 ETL 后按规则跑一遍，作为发布门禁 |
| meta.data_quality_rule | 11 | 32 kB | 数据质量规则：expression 返回违规行数，0 表示通过 |
| meta.etl_job | 14 | 32 kB | ETL 作业注册：声明依赖、调度表达式与入口，供编排器（Airflow/Dagster/自研）读取 |
| meta.etl_run | 1 | 64 kB | ETL 运行实例：记录代码版本、镜像、参数与读写行数，是"同参数同代码可复现"的凭证 |
| meta.fetch_batch | 8 | 72 kB | 抓取批次：ODS 每行的 batch_id 指向此处，记录快照标签、源版本、请求参数与校验和，支持任意批次回放 |
| meta.lineage_event | 22 | 0 bytes | 血缘事件流：ingest→transform→predict→screen→export 全链路，按月分区，用于回答"这个结论是怎么来的" |
| meta.lineage_event_202611 | 22 | 48 kB | - |
| meta.lineage_event_202612 | 0 | 24 kB | - |
| meta.lineage_event_202701 | 0 | 24 kB | - |
| meta.schema_migration | 9 | 32 kB | 数据库迁移登记表：记录每个迁移脚本的版本号、文件校验和与执行耗时，保证环境可复现 |
| meta.source_system | 15 | 32 kB | 数据源登记：公开库/法规库/文献/供应商/内部实验，含许可与更新频率，便于合规审计 |
| ods.chebi_entity | 32 | 360 kB | ODS-ChEBI 化学实体（triterpene 子树本体闭包），含本体父子关系与跨库引用 |
| ods.chembl_activity | 0 | 40 kB | ODS-ChEMBL 活性数据（activities），含数据有效性注释与重复标记，清洗留到 DWD |
| ods.chembl_assay | 0 | 16 kB | ODS-ChEMBL 测定方法（assays），用于活性数据的可信度分级 |
| ods.chembl_molecule | 2 | 136 kB | ODS-ChEMBL 分子主表（molecule_dictionary），字段与源逐列对应 |
| ods.chembl_target | 0 | 16 kB | ODS-ChEMBL 靶点（target_dictionary） |
| ods.drugbank_drug | 0 | 56 kB | ODS-DrugBank 药物条目（XML drug 节点展平），raw_payload 保留完整节点 |
| ods.drugbank_target | 0 | 24 kB | ODS-DrugBank 药物-靶点关系（targets 节点） |
| ods.fda_iid_entry | 0 | 24 kB | ODS-FDA 非活性成分数据库（IID）：某辅料出现在哪些已批准制剂/途径中，用于"已上市可接受性"证据 |
| ods.fda_iig_limit | 0 | 24 kB | ODS-FDA 非活性成分指南（IIG）最大用量：按途径-剂型给出用量上限，是安全边际计算的原始依据 |
| ods.internal_excipient_spec | 0 | 16 kB | ODS-内部辅料规格库：供应商 COA、级别、价格与交期，服务第五级"生产放大评估" |
| ods.kegg_compound | 22 | 296 kB | ODS-KEGG COMPOUND（squalene/triterpene/hopane 族检索），无结构条目靠 DBLINKS 交叉映射 |
| ods.lipidmaps_compound | 294 | 1104 kB | ODS-LIPID MAPS C30 类异戊二烯（三萜）全类表，LMPR0106 批量 download |
| ods.pubchem_classification | 0 | 24 kB | ODS-PubChem MeSH 分类：判断"是否辅料/高分子/脂类"的候选来源 |
| ods.pubchem_compound | 58 | 304 kB | ODS-PubChem 化合物主记录（PUG-View 结构区块），一行一个 CID |
| ods.pubchem_property | 407 | 296 kB | ODS-PubChem 属性长表（PUG-View 全部 section），保留每条属性的原始来源，不做单位换算 |
| ods.pubchem_synonym | 285 | 400 kB | ODS-PubChem 别名表：辅料俗称/商品名与 CID 的映射来源 |
| ref.dosage_form | 15 | 32 kB | 剂型字典：与给药途径组合定位法规限值行 |
| ref.excipient_function | 19 | 32 kB | 辅料功能分类：二级"理化功能中筛"按功能反查目标物性窗口 |
| ref.model_registry | 7 | 32 kB | AI 模型注册表：平台调用的每个模型都必须在此登记版本，预测结果回写 model_code+model_version 形成可复现链路 |
| ref.property_def | 46 | 32 kB | 物性/描述符字典：统一 RDKit 计算值、文献实测值与 AI 预测值的编码，供五级筛选统一取数 |
| ref.regulatory_limit | 2 | 48 kB | 法规限值表：FDA IIG 最大用量、药典限度等，三级"生物安全深筛"计算安全边际的分母 |
| ref.route_admin | 11 | 32 kB | 给药途径字典：辅料安全限值强依赖途径（注射 vs 口服差两个数量级） |
| ref.stage_def | 5 | 48 kB | 五级筛选流水线定义：每级的进入条件、淘汰依据、目标留存规模 |
| ref.unit | 22 | 32 kB | 计量单位字典：统一 ODS/DWD 中各来源的异构单位，换算到 SI 基准单位 |

## 4. 数据质量门禁

| 规则 | 对象 | 级别 | 违规数 | 结果 | 说明 |
|---|---|---|---:|---|---|
| DQ_COMPOUND_DUP_KEY | dwd.dim_compound | error | 0 | PASS | InChIKey 重复：去重逻辑异常 |
| DQ_COMPOUND_INCHIKEY_FMT | dwd.dim_compound | error | 0 | PASS | InChIKey 格式不合规：RDKit 标准化可能被绕过 |
| DQ_COMPOUND_INCHIKEY_NN | dwd.dim_compound | error | 0 | PASS | InChIKey 为空：主键失效，禁止发布 |
| DQ_PROPERTY_NEED_VALUE | dwd.fact_property | error | 0 | PASS | 性质事实无值 |
| DQ_RANK_SCORE_RANGE | ads.rank_result | error | 0 | PASS | 综合得分越界（应 0-100） |
| DQ_LINEAGE_FRESH | meta.lineage_event | info | 0 | PASS | 血缘事件超过 7 天未更新：检查流水线是否停摆 |
| DQ_ACTIVITY_UNIT | dwd.fact_activity | warn | 0 | PASS | 活性数值缺单位 |
| DQ_COMPOUND_NO_SMILES | dwd.dim_compound | warn | 0 | PASS | 缺少异构 SMILES：三级之后的建模无法进行 |
| DQ_PROPERTY_MODEL_TRACE | dwd.fact_property | warn | 0 | PASS | 预测值未记录模型版本：不可复现 |
| DQ_S3_MARGIN_DIRTY | ads.stage3_safety_screen | warn | 0 | PASS | 安全边际出现负值：分子数或单位换算错误 |
| DQ_SETP1_MODEL_SNAPSHOT | ads.screen_run | warn | 0 | PASS | 已完成的 run 缺少模型快照：结果无法复算 |

**通过 11 / 11 条规则**

## 5. 分层数据量

- dwd.dim_compound: **368**
- dwd.dim_compound_xref: **392**
- dwd.fact_property: **3208**
- dwd.fact_activity: **0**
- dwd.fact_compatibility: **0**
- dwd.bridge_compound_function: **32**
- dwd.dim_excipient_grade: **0**
- ads.screen_run: **1**
- ads.candidate_pool: **21**
- ads.compound_score: **103**
- ads.rank_result: **16**
- ads.stage_trace: **40**
- meta.lineage_event: **22**

## 6. 迁移记录

| 版本 | 校验和(前12位) | 耗时(ms) | 应用时间 |
|---|---|---:|---|
| 001_extensions_schemas.sql | `fe7e78df4b2c` | 309 | 2026-11-14 17:13:24 |
| 002_ref_dictionaries.sql | `9cd49a90fb4c` | 222 | 2026-11-14 17:13:25 |
| 003_meta_governance.sql | `66d7a979028a` | 251 | 2026-11-14 17:13:25 |
| 004_ods_layer.sql | `0c0b690ef1bd` | 277 | 2026-11-14 17:13:26 |
| 005_dwd_layer.sql | `39494b44883e` | 281 | 2026-11-14 17:13:27 |
| 006_ads_layer.sql | `db48f3e73c3b` | 248 | 2026-11-14 17:13:27 |
| 007_views_feature_store.sql | `ec6dc60c4cf9` | 184 | 2026-11-14 17:13:28 |
| 008_meta_seed.sql | `d212e7a91cbe` | 159 | 2026-11-14 17:13:28 |
| 010_ods_external_sources.sql | `65e30e62fe48` | 166 | 2026-11-14 17:49:34 |

## 7. 血缘分区

- `meta.lineage_event_202611` → FOR VALUES FROM ('2026-11-01 00:00:00+08') TO ('2026-12-01 00:00:00+08')
- `meta.lineage_event_202611_entity_ix` → None
- `meta.lineage_event_202611_pkey` → None
- `meta.lineage_event_202612` → FOR VALUES FROM ('2026-12-01 00:00:00+08') TO ('2027-01-01 00:00:00+08')
- `meta.lineage_event_202612_entity_ix` → None
- `meta.lineage_event_202612_pkey` → None
- `meta.lineage_event_202701` → FOR VALUES FROM ('2027-01-01 00:00:00+08') TO ('2027-02-01 00:00:00+08')
- `meta.lineage_event_202701_entity_ix` → None
- `meta.lineage_event_202701_pkey` → None
- `meta.lineage_event_event_id_seq` → None
- `meta.lineage_event_pkey` → None
