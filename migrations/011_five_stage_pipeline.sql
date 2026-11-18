-- =====================================================================
-- 011_five_stage_pipeline.sql
-- 五级筛选流水线 & 深度风险评价 支撑表
--   Stage 1  AI 虚拟初筛        (ai_prescreen)
--   Stage 2  理化功能中筛        (physchem_screen)
--   Stage 3  生物安全与配伍深筛   (biosafety_compat)
--   Stage 4  建模分析            (modeling_analysis)
--   Stage 5  生产放大评估        (scaleup_assessment)
-- 设计原则：每级可独立测试、可回溯（run_id 贯穿 + lineage_event 落账）
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. 流水线批次（一次五级跑批的顶层容器）
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ads.pipeline_run (
    run_id            text PRIMARY KEY,               -- e.g. RUN-20261118-001
    pipeline_version  text NOT NULL,
    status            text NOT NULL DEFAULT 'running'
                      CHECK (status IN ('running','completed','failed','cancelled')),
    started_at        timestamptz NOT NULL DEFAULT now(),
    finished_at       timestamptz,
    config            jsonb NOT NULL DEFAULT '{}'::jsonb,
    notes             text
);

-- ---------------------------------------------------------------------
-- 2. 每级筛选的阶段结果（append-only，可回溯）
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ads.stage_result (
    id                bigserial PRIMARY KEY,
    run_id            text NOT NULL REFERENCES ads.pipeline_run(run_id),
    stage_no          smallint NOT NULL CHECK (stage_no BETWEEN 1 AND 5),
    stage_code        text NOT NULL,
    compound_key      text NOT NULL,                  -- InChIKey
    verdict           text NOT NULL
                      CHECK (verdict IN ('pass','fail','hold','pending')),
    score             numeric,                        -- 0~1 归一化得分
    passed_rules      jsonb NOT NULL DEFAULT '[]'::jsonb,
    failed_rules      jsonb NOT NULL DEFAULT '[]'::jsonb,
    detail            jsonb NOT NULL DEFAULT '{}'::jsonb,
    model_code        text,
    model_version     text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (run_id, stage_no, compound_key)
);
CREATE INDEX IF NOT EXISTS idx_stage_result_run
    ON ads.stage_result (run_id, stage_no);

-- ---------------------------------------------------------------------
-- 3. 高分子链段模拟（步骤2：Polymer-Builder / MOE 交互评估）
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dwd.dim_polymer (
    polymer_code      text PRIMARY KEY,               -- e.g. PS80-chain-5mer
    polymer_class     text NOT NULL,                  -- surfactant/polymer/lipid_chain
    monomer_smiles    text,                           -- 重复单元
    degree_of_polymerization integer NOT NULL DEFAULT 1,
    chain_smiles      text,                           -- 拼接后的整链 SMILES（RDKit 生成）
    builder_tool      text NOT NULL DEFAULT 'rdkit_builder'
                      CHECK (builder_tool IN ('rdkit_builder','polymer_builder','moe_chain')),
    builder_params    jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at        timestamptz NOT NULL DEFAULT now()
);

-- 链段/高分子 与 小分子/蛋白 的相互作用评估结果
CREATE TABLE IF NOT EXISTS dwd.fact_polymer_interaction (
    id                bigserial PRIMARY KEY,
    polymer_code      text NOT NULL REFERENCES dwd.dim_polymer(polymer_code),
    partner_inchikey  text NOT NULL,                  -- 小分子(辅料)或蛋白序列哈希
    partner_kind      text NOT NULL DEFAULT 'small_molecule'
                      CHECK (partner_kind IN ('small_molecule','protein','excipient')),
    assay_kind        text NOT NULL                   -- 评估类型
                      CHECK (assay_kind IN
                        ('docking','mmgbsa','cosolvent_md','crystallization_inhibition',
                         'h_bond_profile','contact_map')),
    tool              text NOT NULL,                  -- moe / gromacs / rdkit_proxy ...
    tool_version      text,
    score_value       numeric,                        -- 统一：越大越好
    score_unit        text,
    detail            jsonb NOT NULL DEFAULT '{}'::jsonb,
    run_id            text,                           -- 关联 pipeline_run（可空=独立实验）
    created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_polymer_inter_polymer
    ON dwd.fact_polymer_interaction (polymer_code, partner_inchikey);

-- ---------------------------------------------------------------------
-- 4. 深度风险评价（步骤4）
-- ---------------------------------------------------------------------
-- API-辅料配伍稳定性预测（对接 dwd.fact_compatibility，预测侧另存）
CREATE TABLE IF NOT EXISTS ads.api_excipient_risk (
    id                bigserial PRIMARY KEY,
    api_inchikey      text NOT NULL,
    excipient_inchikey text NOT NULL,
    risk_type         text NOT NULL CHECK (risk_type IN
                        ('hydrolysis','oxidation','maillard','photodegradation',
                         'polymorph_conversion','peroxide_catalysis','metal_catalysis')),
    model_code        text NOT NULL,
    model_version     text NOT NULL,
    risk_score        numeric NOT NULL CHECK (risk_score BETWEEN 0 AND 1),  -- 越大越危险
    predicted_pathway text,
    confidence        numeric(4,3) CHECK (confidence BETWEEN 0 AND 1),
    mitigation        text,
    detail            jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (api_inchikey, excipient_inchikey, risk_type, model_code, model_version)
);

-- ADMET 预测结果
CREATE TABLE IF NOT EXISTS ads.admet_prediction (
    id                bigserial PRIMARY KEY,
    compound_key      text NOT NULL,
    endpoint          text NOT NULL,                  -- Caco2/BBB/hERG/HIA/DILI/CYP2C9...
    model_code        text NOT NULL,
    model_version     text NOT NULL,
    value_num         numeric,
    prob_class        numeric,                        -- 分类概率 0~1
    risk_flag         text CHECK (risk_flag IN ('low','medium','high','unknown')),
    detail            jsonb NOT NULL DEFAULT '{}'::jsonb,
    run_id            text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (compound_key, endpoint, model_code, model_version)
);

-- 杂质催化风险（过氧化物、金属残留等对制剂的催化威胁）
CREATE TABLE IF NOT EXISTS ads.impurity_catalysis_risk (
    id                bigserial PRIMARY KEY,
    formulation_key   text NOT NULL,                  -- API+辅料组合哈希或描述
    impurity_class    text NOT NULL CHECK (impurity_class IN
                        ('peroxide','transition_metal','aldehyde','reducing_sugar',
                         'radical_initiator','unknown')),
    source_excipient_inchikey text,
    catalyzed_pathway text NOT NULL,                  -- e.g. squalene_autoxidation
    risk_score        numeric NOT NULL CHECK (risk_score BETWEEN 0 AND 1),
    evidence          jsonb NOT NULL DEFAULT '{}'::jsonb,
    mitigation        text,
    created_at        timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 5. 视图：五级漏斗汇总
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW ads.v_pipeline_funnel AS
SELECT
    run_id,
    stage_no,
    stage_code,
    count(*)                                             AS candidates,
    count(*) FILTER (WHERE verdict = 'pass')             AS passed,
    count(*) FILTER (WHERE verdict = 'hold')             AS held,
    round(avg(score) FILTER (WHERE verdict = 'pass'), 4) AS avg_pass_score
FROM ads.stage_result
GROUP BY run_id, stage_no, stage_code
ORDER BY run_id, stage_no;

-- 记录迁移
INSERT INTO meta.schema_migration (migration_id, description, checksum)
VALUES ('011_five_stage_pipeline',
        'five-stage screening pipeline, polymer interaction, deep risk tables',
        md5(pg_read_file('011_five_stage_pipeline.sql')))
ON CONFLICT (migration_id) DO NOTHING;

COMMIT;
