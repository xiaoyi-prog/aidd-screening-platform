# AIDD 活性分子筛选平台

基于 PostgreSQL 的佐剂/油相脂质分子筛选数据平台：多源数据库接入（PubChem、ChEMBL、ChEBI、LIPID MAPS、KEGG）→ ETL 清洗 → 五级筛选流水线 → 深度风险评价。

## 目录结构

```
db/
├── migrations/        # 数据库迁移 (001-011)
│   ├── 001_extensions_schemas.sql       # 扩展与 schema
│   ├── 002_ref_dictionaries.sql         # 参考字典
│   ├── 003_meta_governance.sql          # 元数据治理 (fetch_batch / lineage / DQ)
│   ├── 004_ods_layer.sql                # ODS 原始层
│   ├── 005_dwd_layer.sql                # DWD 明细层
│   ├── 006_ads_layer.sql                # ADS 应用层
│   ├── 007_views_feature_store.sql      # 特征仓库视图
│   ├── 008_meta_seed.sql                # 元数据种子
│   ├── 009_roles_grants.sql             # 角色权限
│   ├── 010_ods_external_sources.sql     # ChEBI/LIPIDMAPS/KEGG 外源接入
│   └── 011_five_stage_pipeline.sql      # 五级筛选流水线 + 风险评价表
├── scripts/           # ETL 与筛选脚本
│   ├── fetch_triterpene.py              # 步骤1: PubChem+ChEMBL 三萜烃抓取
│   ├── fetch_triterpene_ext.py          # 步骤1: ChEBI/LIPIDMAPS/KEGG 抓取
│   ├── chembl_backfill.py               # ChEMBL 骨架校验回填
│   ├── backfill_smiles.py               # LIPID MAPS/ChEBI SMILES 回填 (RDKit InChIKey 校验)
│   ├── healthcheck.py                   # 11 条数据质量门禁巡检
│   ├── polymer_sim.py                   # 步骤2: 高分子链段-蛋白/小分子相互作用模拟
│   ├── pipeline_five_stage.py           # 步骤3: 五级筛选流水线
│   └── risk_deep_eval.py                # 步骤4: 配伍稳定性/ADMET/杂质催化风险
├── reports/           # 各阶段报告
├── docs/              # 文档
└── docker-compose.yml # PostgreSQL 16 环境定义
```

## 五级筛选流水线

| 级别 | 名称 | 说明 |
|------|------|------|
| 1 | AI 虚拟初筛 | 分子 AI 模型打分（可插拔 GNN / DeepPurpose / ChemBERTa） |
| 2 | 理化功能中筛 | RDKit 理化性质 + AI预测 vs 微量小试吻合度 gate |
| 3 | 生物安全与配伍深筛 | ADMET 硬终点 + API-辅料配伍风险 |
| 4 | 建模分析 | 集成一致性 / 不确定度评估 |
| 5 | 生产放大评估 | 粘度 / 乳化能耗 / 批间一致性 / 抑制结晶 |

每级为独立可测试模块（`ScreeningStage` 抽象类），`run_id` + `meta.lineage_event` 全程回溯。

## 环境要求

- PostgreSQL 16（免安装二进制亦可），database `aidd`
- Python 3.13 + `psycopg2` + `rdkit`
- 可选：MOE / Polymer-Builder CLI（通过 `MOE_BIN` / `POLYMER_BUILDER_BIN` 环境变量接入）

## 快速开始

```bash
# 1. 建库（二进制 PostgreSQL，端口 55432）
bash db/scripts/bootstrap.sh

# 2. 依次执行迁移
psql -p 55432 -d aidd -f db/migrations/001_extensions_schemas.sql
# ... 至 011

# 3. 数据抓取
python db/scripts/fetch_triterpene.py
python db/scripts/fetch_triterpene_ext.py
python db/scripts/backfill_smiles.py

# 4. 质量巡检
python db/scripts/healthcheck.py

# 5. 聚合物模拟 / 五级流水线 / 风险评价
python db/scripts/polymer_sim.py
python db/scripts/pipeline_five_stage.py
python db/scripts/risk_deep_eval.py
```
