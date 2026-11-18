-- ============================================================================
-- 006_ads_layer.sql
-- ADS 应用层：五级筛选流水线的运行定义、候选池、各级快照、评分与决策追溯
--
-- 流水线（与 ref.stage_def 一一对应）：
--   1 AI 虚拟初筛  → 2 理化功能中筛 → 3 生物安全与配伍深筛
--   → 4 建模分析   → 5 生产放大评估
--
-- 设计要点：
--   * screen_run 冻结 model_snapshot + funnel_config + code_version，
--     即"同一 run 永远可复算"，这是可复现的前提。
--   * candidate_pool 是漏斗台账（进/出/留存），每级表是该级的完整打分快照。
--   * compound_score 用长表存分项得分，权重与解释留在库里，避免"黑箱排名"。
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 6.1 筛选run
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ads.screen_run (
    run_id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_code             text NOT NULL UNIQUE,
    run_name             text NOT NULL,
    objective            text,
    target_function_code text REFERENCES ref.excipient_function(function_code),
    target_route_code    text REFERENCES ref.route_admin(route_code),
    target_dosage_form   text REFERENCES ref.dosage_form(form_code),
    funnel_config        jsonb NOT NULL DEFAULT '{}'::jsonb,
    model_snapshot       jsonb NOT NULL DEFAULT '{}'::jsonb,
    code_version         text,
    input_scope          jsonb NOT NULL DEFAULT '{}'::jsonb,
    status               text NOT NULL DEFAULT 'draft'
                         CHECK (status IN ('draft', 'running', 'completed', 'archived', 'failed')),
    created_by           text DEFAULT current_user,
    created_at           timestamptz NOT NULL DEFAULT now(),
    finished_at          timestamptz,
    notes                text
);
COMMENT ON TABLE ads.screen_run IS '筛选任务：一次完整的五级漏斗执行，冻结模型快照与配置以保证可复现';
COMMENT ON COLUMN ads.screen_run.model_snapshot IS '本次 run 使用的模型版本快照，形如 {"PROP_MLP":"v1.3.0","TOX_ADMET":"v3.1.2"}';
COMMENT ON COLUMN ads.screen_run.input_scope IS '候选来源范围，例如 {"source":"dwd_full","function_code":"SOLUBILIZER","min_mw":100}';

CREATE TABLE IF NOT EXISTS ads.run_stage_config (
    run_id        uuid NOT NULL REFERENCES ads.screen_run(run_id) ON DELETE CASCADE,
    stage_no      smallint NOT NULL CHECK (stage_no BETWEEN 1 AND 5),
    is_enabled    boolean NOT NULL DEFAULT true,
    thresholds    jsonb NOT NULL DEFAULT '{}'::jsonb,
    weights       jsonb NOT NULL DEFAULT '{}'::jsonb,
    filter_rules  jsonb NOT NULL DEFAULT '[]'::jsonb,
    target_rows   bigint,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, stage_no)
);
COMMENT ON TABLE ads.run_stage_config IS '每级筛选的阈值/权重/规则配置：允许同一批候选跑多套参数做对比实验';
COMMENT ON COLUMN ads.run_stage_config.filter_rules IS '规则数组，例如 [{"field":"herg_prob","op":"<=","value":0.3,"hard":true}]';

-- ---------------------------------------------------------------------------
-- 6.2 候选池台账
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ads.candidate_pool (
    run_id          uuid NOT NULL REFERENCES ads.screen_run(run_id) ON DELETE CASCADE,
    compound_sk     bigint NOT NULL REFERENCES dwd.dim_compound(compound_sk),
    entry_source    text NOT NULL DEFAULT 'dwd_full',
    current_stage   smallint NOT NULL DEFAULT 1 CHECK (current_stage BETWEEN 1 AND 5),
    status          text NOT NULL DEFAULT 'in_funnel'
                    CHECK (status IN ('in_funnel', 'advanced', 'hold', 'rejected', 'shortlisted')),
    final_score     numeric,
    entered_at      timestamptz NOT NULL DEFAULT now(),
    exited_at       timestamptz,
    exit_stage      smallint,
    exit_reason     text,
    PRIMARY KEY (run_id, compound_sk)
);
COMMENT ON TABLE ads.candidate_pool IS '候选池台账：一个 run 内每个分子的当前层级与存活状态，漏斗转化率的唯一口径';

CREATE INDEX IF NOT EXISTS ix_pool_status ON ads.candidate_pool (run_id, status, current_stage);
CREATE INDEX IF NOT EXISTS ix_pool_compound ON ads.candidate_pool (compound_sk);

-- ---------------------------------------------------------------------------
-- 6.3 五级快照表（每级一张，字段随该级判据演化）
-- ---------------------------------------------------------------------------

-- 一级：AI 虚拟初筛
CREATE TABLE IF NOT EXISTS ads.stage1_ai_screen (
    run_id             uuid NOT NULL,
    compound_sk        bigint NOT NULL,
    mw                 numeric,
    logp_pred          numeric,
    tpsa               numeric,
    hbd                smallint,
    hba                smallint,
    rot_bonds          smallint,
    qed                numeric,
    sa_score           numeric,
    solubility_logs    numeric,
    permeability_pred  numeric,
    herg_prob          numeric,
    ames_prob          numeric,
    hepatotox_prob     numeric,
    bioavailability_prob numeric,
    predictions        jsonb NOT NULL DEFAULT '{}'::jsonb,
    filter_results     jsonb NOT NULL DEFAULT '[]'::jsonb,
    filters_total      smallint NOT NULL DEFAULT 0,
    filters_passed     smallint NOT NULL DEFAULT 0,
    stage_score        numeric,
    stage_status       text NOT NULL DEFAULT 'pending'
                       CHECK (stage_status IN ('pending', 'pass', 'hold', 'fail')),
    rule_version       text,
    model_snapshot     jsonb NOT NULL DEFAULT '{}'::jsonb,
    decided_at         timestamptz,
    PRIMARY KEY (run_id, compound_sk),
    FOREIGN KEY (run_id, compound_sk) REFERENCES ads.candidate_pool (run_id, compound_sk) ON DELETE CASCADE
);
COMMENT ON TABLE ads.stage1_ai_screen IS '一级 AI 虚拟初筛结果：AI 模型对全量候选的零成本预判 + 规则命中明细';
COMMENT ON COLUMN ads.stage1_ai_screen.filter_results IS '每条规则的命中详情，例如 [{"rule":"logp<=5","value":4.2,"passed":true}]，用于向研发解释淘汰原因';

-- 二级：理化功能中筛
CREATE TABLE IF NOT EXISTS ads.stage2_physchem_screen (
    run_id                uuid NOT NULL,
    compound_sk           bigint NOT NULL,
    target_function_code  text REFERENCES ref.excipient_function(function_code),
    function_confidence   numeric,
    spec_results          jsonb NOT NULL DEFAULT '[]'::jsonb,
    specs_total           smallint NOT NULL DEFAULT 0,
    specs_passed          smallint NOT NULL DEFAULT 0,
    spec_match_rate       numeric,
    hlb                   numeric,
    melting_point_c       numeric,
    tg_c                  numeric,
    water_solubility      numeric,
    viscosity             numeric,
    particle_size_d50     numeric,
    carr_index            numeric,
    moisture_pct          numeric,
    function_fit_score    numeric,
    stage_score           numeric,
    stage_status          text NOT NULL DEFAULT 'pending'
                          CHECK (stage_status IN ('pending', 'pass', 'hold', 'fail')),
    rule_version          text,
    decided_at            timestamptz,
    PRIMARY KEY (run_id, compound_sk),
    FOREIGN KEY (run_id, compound_sk) REFERENCES ads.candidate_pool (run_id, compound_sk) ON DELETE CASCADE
);
COMMENT ON TABLE ads.stage2_physchem_screen IS '二级理化功能中筛：候选物性 vs 目标功能规格窗口的逐项匹配结果';
COMMENT ON COLUMN ads.stage2_physchem_screen.spec_results IS '逐项规格匹配，例如 [{"prop":"HLB","spec":[3,6],"value":4.3,"passed":true}]';

-- 三级：生物安全与配伍深筛
CREATE TABLE IF NOT EXISTS ads.stage3_safety_screen (
    run_id                  uuid NOT NULL,
    compound_sk             bigint NOT NULL,
    herg_prob               numeric,
    ames_prob               numeric,
    hepatotox_prob          numeric,
    cytotox_prob            numeric,
    irritation_prob         numeric,
    regulatory_limit_id     bigint REFERENCES ref.regulatory_limit(limit_id),
    regulatory_max_daily    numeric,
    planned_daily_dose      numeric,
    safety_margin           numeric,
    regulatory_block        boolean NOT NULL DEFAULT false,
    compatibility_score     numeric,
    worst_compat_api_sk     bigint REFERENCES dwd.dim_compound(compound_sk),
    admet_detail            jsonb NOT NULL DEFAULT '{}'::jsonb,
    compat_detail           jsonb NOT NULL DEFAULT '[]'::jsonb,
    stage_score             numeric,
    stage_status            text NOT NULL DEFAULT 'pending'
                            CHECK (stage_status IN ('pending', 'pass', 'hold', 'fail')),
    rule_version            text,
    model_snapshot          jsonb NOT NULL DEFAULT '{}'::jsonb,
    decided_at              timestamptz,
    PRIMARY KEY (run_id, compound_sk),
    FOREIGN KEY (run_id, compound_sk) REFERENCES ads.candidate_pool (run_id, compound_sk) ON DELETE CASCADE
);
COMMENT ON TABLE ads.stage3_safety_screen IS '三级生物安全与配伍深筛：ADMET 风险 + 法规限值安全边际 + API-辅料配伍稳定性';
COMMENT ON COLUMN ads.stage3_safety_screen.safety_margin IS '安全边际 = 法规最大日暴露量 / 拟用日剂量；< 1.5 视为高风险';
COMMENT ON COLUMN ads.stage3_safety_screen.regulatory_block IS '是否触及法规硬红线（如注射剂禁用辅料），一票否决';

-- 四级：建模分析
CREATE TABLE IF NOT EXISTS ads.stage4_modeling_screen (
    run_id             uuid NOT NULL,
    compound_sk        bigint NOT NULL,
    primary_target_sk  bigint REFERENCES dwd.dim_target(target_sk),
    docking_score_kcal numeric,
    binding_affinity   numeric,
    md_duration_ns     numeric,
    rmsd_nm            numeric,
    rmsf_nm            numeric,
    hbond_count        integer,
    aggregation_propensity numeric,
    crystal_interference   numeric,
    ensemble_score     numeric,
    artifacts          jsonb NOT NULL DEFAULT '{}'::jsonb,
    stage_score        numeric,
    stage_status       text NOT NULL DEFAULT 'pending'
                       CHECK (stage_status IN ('pending', 'pass', 'hold', 'fail')),
    rule_version       text,
    model_snapshot     jsonb NOT NULL DEFAULT '{}'::jsonb,
    decided_at         timestamptz,
    PRIMARY KEY (run_id, compound_sk),
    FOREIGN KEY (run_id, compound_sk) REFERENCES ads.candidate_pool (run_id, compound_sk) ON DELETE CASCADE
);
COMMENT ON TABLE ads.stage4_modeling_screen IS '四级建模分析：对接打分、MD 稳定性、聚集倾向与晶型干扰评估';
COMMENT ON COLUMN ads.stage4_modeling_screen.artifacts IS '轨迹/构象文件指针，例如 {"trajectory":"s3://...","pose":"s3://..."}，保证结论可复查';

-- 五级：生产放大评估
CREATE TABLE IF NOT EXISTS ads.stage5_scaleup_screen (
    run_id              uuid NOT NULL,
    compound_sk         bigint NOT NULL,
    grade_sk            bigint REFERENCES dwd.dim_excipient_grade(grade_sk),
    estimated_cost_per_kg numeric,
    supplier_count      integer,
    lead_time_days      integer,
    min_order_qty_kg    numeric,
    synthesis_steps     integer,
    gmp_available       boolean,
    compendial_status   text,
    process_compatibility jsonb NOT NULL DEFAULT '{}'::jsonb,
    scale_risk_score    numeric,
    stage_score         numeric,
    stage_status        text NOT NULL DEFAULT 'pending'
                        CHECK (stage_status IN ('pending', 'pass', 'hold', 'fail')),
    rule_version        text,
    model_snapshot      jsonb NOT NULL DEFAULT '{}'::jsonb,
    decided_at          timestamptz,
    PRIMARY KEY (run_id, compound_sk),
    FOREIGN KEY (run_id, compound_sk) REFERENCES ads.candidate_pool (run_id, compound_sk) ON DELETE CASCADE
);
COMMENT ON TABLE ads.stage5_scaleup_screen IS '五级生产放大评估：成本、供应、GMP/药典合规与工艺兼容性';
COMMENT ON COLUMN ads.stage5_scaleup_screen.process_compatibility IS '与现有产线工艺的匹配度，例如 {"hot_melt_extrusion":true,"spray_drying":false}';

-- ---------------------------------------------------------------------------
-- 6.4 分项评分（可解释）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ads.compound_score (
    run_id         uuid NOT NULL,
    compound_sk    bigint NOT NULL,
    stage_no       smallint NOT NULL CHECK (stage_no BETWEEN 1 AND 5),
    score_code     text NOT NULL,
    score_value    numeric NOT NULL CHECK (score_value BETWEEN 0 AND 100),
    weight         numeric NOT NULL DEFAULT 1 CHECK (weight >= 0),
    weighted_value numeric GENERATED ALWAYS AS (score_value * weight) STORED,
    model_code     text,
    model_version  text,
    rationale      text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, compound_sk, stage_no, score_code),
    FOREIGN KEY (run_id, compound_sk) REFERENCES ads.candidate_pool (run_id, compound_sk) ON DELETE CASCADE
);
COMMENT ON TABLE ads.compound_score IS '分项评分长表：每个分数都能回答"谁打的、按什么权重、依据是什么"，杜绝黑箱排名';
COMMENT ON COLUMN ads.compound_score.score_code IS '评分项编码，例如 LIPINSKI/TOX_RISK/FUNCTION_FIT/COST';

-- ---------------------------------------------------------------------------
-- 6.5 最终排名与结论
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ads.rank_result (
    run_id                uuid NOT NULL,
    compound_sk           bigint NOT NULL,
    final_score           numeric NOT NULL,
    rank_no               integer,
    percentile            numeric,
    verdict               text NOT NULL
                          CHECK (verdict IN ('recommend', 'conditional', 'hold', 'reject')),
    recommended_function  text REFERENCES ref.excipient_function(function_code),
    rejection_reason      text,
    evidence              jsonb NOT NULL DEFAULT '{}'::jsonb,
    reviewer              text,
    reviewed_at           timestamptz,
    created_at            timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, compound_sk),
    FOREIGN KEY (run_id, compound_sk) REFERENCES ads.candidate_pool (run_id, compound_sk) ON DELETE CASCADE
);
COMMENT ON TABLE ads.rank_result IS '最终排名与结论：进入湿实验的推荐清单，含人工复核痕迹';

CREATE INDEX IF NOT EXISTS ix_rank_run_score ON ads.rank_result (run_id, final_score DESC);

-- ---------------------------------------------------------------------------
-- 6.6 决策追溯
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ads.stage_trace (
    trace_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id          uuid NOT NULL REFERENCES ads.screen_run(run_id) ON DELETE CASCADE,
    compound_sk     bigint NOT NULL,
    stage_no        smallint NOT NULL CHECK (stage_no BETWEEN 1 AND 5),
    action          text NOT NULL
                    CHECK (action IN ('enter', 'score', 'pass', 'hold', 'reject', 'advance',
                                      'review', 'override', 'export')),
    input_snapshot  jsonb,
    output_snapshot jsonb,
    rule_version    text,
    model_code      text,
    model_version   text,
    input_hash      text,
    output_hash     text,
    decided_by      text DEFAULT current_user,
    decided_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ads.stage_trace IS '逐级决策追溯：任何一个分子为何在这一级被淘汰/晋级，都能定位到输入快照、规则版本与模型版本';

CREATE INDEX IF NOT EXISTS ix_trace_run ON ads.stage_trace (run_id, stage_no, action);
CREATE INDEX IF NOT EXISTS ix_trace_compound ON ads.stage_trace (compound_sk, decided_at DESC);

COMMIT;
