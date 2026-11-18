-- ============================================================================
-- 007_views_feature_store.sql
-- 应用视图 + 面向模型的宽表（特征矩阵）
-- 对应架构图中"面向筛选流水线的宽表/特征表"
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 7.1 漏斗总览：每级评估量/通过量/通过率
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW ads.v_funnel_summary AS
SELECT run_id, run_code, stage_no, stage_name, evaluated, passed, held, failed,
       round(100.0 * passed / NULLIF(evaluated, 0), 2) AS pass_rate_pct,
       round(avg_score, 2) AS avg_score
FROM (
    SELECT r.run_id, r.run_code, 1 AS stage_no, '1-AI虚拟初筛' AS stage_name,
           count(s.compound_sk) AS evaluated,
           count(*) FILTER (WHERE s.stage_status = 'pass') AS passed,
           count(*) FILTER (WHERE s.stage_status = 'hold') AS held,
           count(*) FILTER (WHERE s.stage_status = 'fail') AS failed,
           avg(s.stage_score) AS avg_score
      FROM ads.screen_run r LEFT JOIN ads.stage1_ai_screen s ON s.run_id = r.run_id
     GROUP BY r.run_id, r.run_code
    UNION ALL
    SELECT r.run_id, r.run_code, 2, '2-理化功能中筛',
           count(s.compound_sk),
           count(*) FILTER (WHERE s.stage_status = 'pass'),
           count(*) FILTER (WHERE s.stage_status = 'hold'),
           count(*) FILTER (WHERE s.stage_status = 'fail'),
           avg(s.stage_score)
      FROM ads.screen_run r LEFT JOIN ads.stage2_physchem_screen s ON s.run_id = r.run_id
     GROUP BY r.run_id, r.run_code
    UNION ALL
    SELECT r.run_id, r.run_code, 3, '3-生物安全与配伍深筛',
           count(s.compound_sk),
           count(*) FILTER (WHERE s.stage_status = 'pass'),
           count(*) FILTER (WHERE s.stage_status = 'hold'),
           count(*) FILTER (WHERE s.stage_status = 'fail'),
           avg(s.stage_score)
      FROM ads.screen_run r LEFT JOIN ads.stage3_safety_screen s ON s.run_id = r.run_id
     GROUP BY r.run_id, r.run_code
    UNION ALL
    SELECT r.run_id, r.run_code, 4, '4-建模分析',
           count(s.compound_sk),
           count(*) FILTER (WHERE s.stage_status = 'pass'),
           count(*) FILTER (WHERE s.stage_status = 'hold'),
           count(*) FILTER (WHERE s.stage_status = 'fail'),
           avg(s.stage_score)
      FROM ads.screen_run r LEFT JOIN ads.stage4_modeling_screen s ON s.run_id = r.run_id
     GROUP BY r.run_id, r.run_code
    UNION ALL
    SELECT r.run_id, r.run_code, 5, '5-生产放大评估',
           count(s.compound_sk),
           count(*) FILTER (WHERE s.stage_status = 'pass'),
           count(*) FILTER (WHERE s.stage_status = 'hold'),
           count(*) FILTER (WHERE s.stage_status = 'fail'),
           avg(s.stage_score)
      FROM ads.screen_run r LEFT JOIN ads.stage5_scaleup_screen s ON s.run_id = r.run_id
     GROUP BY r.run_id, r.run_code
) t;
COMMENT ON VIEW ads.v_funnel_summary IS '五级漏斗总览：各级评估量、通过量、通过率、均分，用于监控"计算层压缩"效果';

-- ---------------------------------------------------------------------------
-- 7.2 候选记分卡：一个分子在一条流水线上的完整状态
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW ads.v_candidate_scorecard AS
SELECT
    r.run_id,
    r.run_code,
    p.compound_sk,
    c.inchikey,
    c.molecular_formula,
    c.molecular_weight,
    p.current_stage,
    p.status,
    s1.stage_status AS st1_status,
    round(s1.stage_score, 2) AS st1_score,
    s2.stage_status AS st2_status,
    round(s2.stage_score, 2) AS st2_score,
    s3.stage_status AS st3_status,
    round(s3.stage_score, 2) AS st3_score,
    round(s3.safety_margin, 2) AS safety_margin,
    s4.stage_status AS st4_status,
    round(s4.stage_score, 2) AS st4_score,
    s5.stage_status AS st5_status,
    round(s5.stage_score, 2) AS st5_score,
    round(rr.final_score, 2) AS final_score,
    rr.rank_no,
    rr.verdict,
    p.exit_reason
FROM ads.candidate_pool p
JOIN ads.screen_run r ON r.run_id = p.run_id
JOIN dwd.dim_compound c ON c.compound_sk = p.compound_sk
LEFT JOIN ads.stage1_ai_screen s1 ON s1.run_id = p.run_id AND s1.compound_sk = p.compound_sk
LEFT JOIN ads.stage2_physchem_screen s2 ON s2.run_id = p.run_id AND s2.compound_sk = p.compound_sk
LEFT JOIN ads.stage3_safety_screen s3 ON s3.run_id = p.run_id AND s3.compound_sk = p.compound_sk
LEFT JOIN ads.stage4_modeling_screen s4 ON s4.run_id = p.run_id AND s4.compound_sk = p.compound_sk
LEFT JOIN ads.stage5_scaleup_screen s5 ON s5.run_id = p.run_id AND s5.compound_sk = p.compound_sk
LEFT JOIN ads.rank_result rr ON rr.run_id = p.run_id AND rr.compound_sk = p.compound_sk;
COMMENT ON VIEW ads.v_candidate_scorecard IS '候选记分卡：单个分子在五级流水线中的逐级状态、分数与最终结论';

-- ---------------------------------------------------------------------------
-- 7.3 特征宽表（物化视图）：给模型训练与批量打分用
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS ads.mv_compound_feature_matrix;

CREATE MATERIALIZED VIEW ads.mv_compound_feature_matrix AS
SELECT
    c.compound_sk,
    c.inchikey,
    c.inchikey_skeleton,
    c.compound_class,
    c.molecular_formula,
    c.molecular_weight,
    c.smiles_isomeric,
    -- 计算描述符
    max(p.value_num) FILTER (WHERE p.property_code = 'LOGP'        AND p.value_type = 'computed')  AS logp,
    max(p.value_num) FILTER (WHERE p.property_code = 'TPSA'        AND p.value_type = 'computed')  AS tpsa,
    max(p.value_num) FILTER (WHERE p.property_code = 'HBD'         AND p.value_type = 'computed')  AS hbd,
    max(p.value_num) FILTER (WHERE p.property_code = 'HBA'         AND p.value_type = 'computed')  AS hba,
    max(p.value_num) FILTER (WHERE p.property_code = 'ROT_BONDS'   AND p.value_type = 'computed')  AS rot_bonds,
    max(p.value_num) FILTER (WHERE p.property_code = 'RING_COUNT'  AND p.value_type = 'computed')  AS ring_count,
    max(p.value_num) FILTER (WHERE p.property_code = 'LOGS'        AND p.value_type = 'computed')  AS logs,
    -- 实测/文献值优先，缺则取预测值
    coalesce(
        max(p.value_num) FILTER (WHERE p.property_code = 'MELTING_POINT' AND p.value_type IN ('measured', 'curated')),
        max(p.value_num) FILTER (WHERE p.property_code = 'MELTING_POINT' AND p.value_type = 'predicted')
    ) AS melting_point_c,
    max(p.value_num) FILTER (WHERE p.property_code = 'TG_TEMP')          AS tg_c,
    max(p.value_num) FILTER (WHERE p.property_code = 'WATER_SOLUBILITY') AS water_solubility,
    max(p.value_num) FILTER (WHERE p.property_code = 'HLB')              AS hlb,
    max(p.value_num) FILTER (WHERE p.property_code = 'CMC')              AS cmc,
    max(p.value_num) FILTER (WHERE p.property_code = 'VISCOSITY')        AS viscosity,
    max(p.value_num) FILTER (WHERE p.property_code = 'PARTICLE_SIZE_D50') AS psd_d50,
    max(p.value_num) FILTER (WHERE p.property_code = 'BULK_DENSITY')     AS bulk_density,
    max(p.value_num) FILTER (WHERE p.property_code = 'CARR_INDEX')       AS carr_index,
    max(p.value_num) FILTER (WHERE p.property_code = 'MOISTURE_CONTENT') AS moisture_pct,
    -- 安全相关预测
    max(p.value_num) FILTER (WHERE p.property_code = 'HERG_PROB')        AS herg_prob,
    max(p.value_num) FILTER (WHERE p.property_code = 'AMES_PROB')        AS ames_prob,
    max(p.value_num) FILTER (WHERE p.property_code = 'HEPATOTOX_PROB')   AS hepatotox_prob,
    max(p.value_num) FILTER (WHERE p.property_code = 'CYTOTOX_PROB')     AS cytotox_prob,
    max(p.value_num) FILTER (WHERE p.property_code = 'BIOAVAIL_PROB')    AS bioavail_prob,
    -- 覆盖度与功能标签
    count(*) FILTER (WHERE p.value_type = 'measured')  AS measured_prop_cnt,
    count(*) FILTER (WHERE p.value_type = 'predicted') AS predicted_prop_cnt,
    count(*) FILTER (WHERE p.value_type = 'computed')  AS computed_prop_cnt,
    coalesce(array_agg(DISTINCT f.function_code) FILTER (WHERE f.function_code IS NOT NULL), '{}') AS function_codes,
    max(c.updated_at) AS compound_updated_at
FROM dwd.dim_compound c
LEFT JOIN dwd.fact_property p ON p.compound_sk = c.compound_sk AND p.property_code IN (
    'LOGP', 'TPSA', 'HBD', 'HBA', 'ROT_BONDS', 'RING_COUNT', 'LOGS', 'MELTING_POINT', 'TG_TEMP',
    'WATER_SOLUBILITY', 'HLB', 'CMC', 'VISCOSITY', 'PARTICLE_SIZE_D50', 'BULK_DENSITY',
    'CARR_INDEX', 'MOISTURE_CONTENT', 'HERG_PROB', 'AMES_PROB', 'HEPATOTOX_PROB',
    'CYTOTOX_PROB', 'BIOAVAIL_PROB')
LEFT JOIN dwd.bridge_compound_function f ON f.compound_sk = c.compound_sk
GROUP BY c.compound_sk, c.inchikey, c.inchikey_skeleton, c.compound_class,
         c.molecular_formula, c.molecular_weight, c.smiles_isomeric, c.updated_at;

CREATE UNIQUE INDEX IF NOT EXISTS uq_mv_feature_matrix_sk
    ON ads.mv_compound_feature_matrix (compound_sk);
CREATE INDEX IF NOT EXISTS ix_mv_feature_matrix_logp
    ON ads.mv_compound_feature_matrix (logp);

COMMENT ON MATERIALIZED VIEW ads.mv_compound_feature_matrix IS '分子特征宽表：把长表物性透视成一行一分子，供模型训练与批量打分；刷新用 REFRESH MATERIALIZED VIEW CONCURRENTLY ads.mv_compound_feature_matrix';

-- ---------------------------------------------------------------------------
-- 7.4 数据新鲜度（治理看板）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW meta.v_batch_freshness AS
SELECT
    b.source_code,
    s.source_name,
    b.batch_id,
    b.snapshot_label,
    b.status,
    b.record_count,
    b.fetch_finished_at,
    round(extract(epoch FROM (now() - b.fetch_finished_at)) / 86400.0, 1) AS age_days,
    CASE
        WHEN b.fetch_finished_at IS NULL THEN 'in_progress'
        WHEN now() - b.fetch_finished_at > interval '180 days' THEN 'stale'
        WHEN now() - b.fetch_finished_at > interval '90 days'  THEN 'aging'
        ELSE 'fresh'
    END AS freshness
FROM meta.fetch_batch b
JOIN meta.source_system s ON s.source_code = b.source_code;
COMMENT ON VIEW meta.v_batch_freshness IS '数据新鲜度：各源最近批次距今多久，超过 90/180 天标记 aging/stale';

-- ---------------------------------------------------------------------------
-- 7.5 数据完整性总览
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW meta.v_data_completeness AS
SELECT 'dwd.dim_compound' AS object_name, count(*) AS row_cnt FROM dwd.dim_compound
UNION ALL SELECT 'dwd.dim_compound_xref',   count(*) FROM dwd.dim_compound_xref
UNION ALL SELECT 'dwd.fact_property',       count(*) FROM dwd.fact_property
UNION ALL SELECT 'dwd.fact_activity',       count(*) FROM dwd.fact_activity
UNION ALL SELECT 'dwd.fact_compatibility',  count(*) FROM dwd.fact_compatibility
UNION ALL SELECT 'dwd.bridge_compound_function', count(*) FROM dwd.bridge_compound_function
UNION ALL SELECT 'dwd.dim_excipient_grade', count(*) FROM dwd.dim_excipient_grade
UNION ALL SELECT 'ads.screen_run',          count(*) FROM ads.screen_run
UNION ALL SELECT 'ads.candidate_pool',      count(*) FROM ads.candidate_pool
UNION ALL SELECT 'ads.compound_score',      count(*) FROM ads.compound_score
UNION ALL SELECT 'ads.rank_result',         count(*) FROM ads.rank_result
UNION ALL SELECT 'ads.stage_trace',         count(*) FROM ads.stage_trace
UNION ALL SELECT 'meta.lineage_event',      count(*) FROM meta.lineage_event;
COMMENT ON VIEW meta.v_data_completeness IS '各层核心表当前行数，用于交付验收与日常巡检';

COMMIT;
