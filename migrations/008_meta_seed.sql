-- ============================================================================
-- 008_meta_seed.sql
-- 治理层初始数据：ETL 作业清单 + 数据质量规则（交付即可运行的门禁）
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 8.1 ETL 作业清单（与三层架构逐段对应）
-- ---------------------------------------------------------------------------
INSERT INTO meta.etl_job (job_code, job_name, layer, source_code, target_table, depends_on, schedule_cron, entrypoint, owner, description) VALUES
    ('ods_pubchem_fetch',   'PubChem 抓取',       'ods', 'PUBCHEM', 'ods.pubchem_compound',        '{}',
        '0 3 1 */3 *', 'jobs/ods/fetch_pubchem.py',   '数据组', '按季度拉取 PubChem 化合物与属性，落 ODS 原始报文'),
    ('ods_chembl_fetch',    'ChEMBL 抓取',        'ods', 'CHEMBL',  'ods.chembl_molecule',         '{}',
        '0 4 1 */3 *', 'jobs/ods/fetch_chembl.py',    '数据组', '拉取 ChEMBL 分子/活性/assay/target'),
    ('ods_drugbank_fetch',  'DrugBank 抓取',      'ods', 'DRUGBANK','ods.drugbank_drug',           '{}',
        '0 5 1 1,7 *', 'jobs/ods/fetch_drugbank.py',  '数据组', '半年一次，解析 XML 全量'),
    ('ods_regulatory_fetch','法规限值抓取',       'ods', 'FDA_IIG', 'ods.fda_iig_limit',           '{}',
        '0 6 1 */3 *', 'jobs/ods/fetch_regulatory.py','数据组', 'FDA IID/IIG 最大用量，安全边际的分母'),
    ('dwd_chem_standardize','化学结构标准化',     'dwd', 'RDKIT',   'dwd.dim_compound',            '{ods_pubchem_fetch,ods_chembl_fetch,ods_drugbank_fetch}',
        '30 6 * * *', 'jobs/dwd/standardize_compounds.py', '数据组', 'RDKit 解析→canonical SMILES/InChIKey→去盐去重→生成 dim_compound'),
    ('dwd_property_compute','物性计算落库',       'dwd', 'RDKIT',   'dwd.fact_property',           '{dwd_chem_standardize}',
        '0 7 * * *',  'jobs/dwd/compute_properties.py',    '数据组', '描述符计算 + 文献值抽取 + 质量过滤'),
    ('dwd_activity_load',   '活性数据归一',       'dwd', 'CHEMBL',  'dwd.fact_activity',           '{dwd_chem_standardize}',
        '10 7 * * *', 'jobs/dwd/load_activity.py',         '数据组', '单位归一、pchembl 换算、重复标记'),
    ('dwd_feature_refresh', '特征宽表刷新',       'dwd', 'INTERNAL','ads.mv_compound_feature_matrix','{dwd_property_compute,dwd_activity_load}',
        '0 8 * * *',  'jobs/dwd/refresh_features.py',      '数据组', 'REFRESH MATERIALIZED VIEW CONCURRENTLY'),
    ('ads_stage1_run',      '一级 AI 虚拟初筛',   'ads', 'MODEL',   'ads.stage1_ai_screen',        '{dwd_feature_refresh}',
        null,         'jobs/ads/stage1_virtual_screen.py', '算法组', '批量推理 + 硬阈值过滤'),
    ('ads_stage2_run',      '二级理化功能中筛',   'ads', 'INTERNAL','ads.stage2_physchem_screen',  '{ads_stage1_run}',
        null,         'jobs/ads/stage2_physchem_screen.py','制剂组', '功能规格窗口匹配'),
    ('ads_stage3_run',      '三级安全配伍深筛',   'ads', 'MODEL',   'ads.stage3_safety_screen',    '{ads_stage2_run}',
        null,         'jobs/ads/stage3_safety_screen.py',  '安全组', 'ADMET + 法规限值 + 配伍'),
    ('ads_stage4_run',      '四级建模分析',       'ads', 'MODEL',   'ads.stage4_modeling_screen',  '{ads_stage3_run}',
        null,         'jobs/ads/stage4_modeling_screen.py','计算组', '对接/MD，产出构象与轨迹指针'),
    ('ads_stage5_run',      '五级放大评估',       'ads', 'VENDOR',  'ads.stage5_scaleup_screen',   '{ads_stage4_run}',
        null,         'jobs/ads/stage5_scaleup_screen.py', '工艺组', '成本/供应/合规评估'),
    ('ads_ranking',         '综合排名定稿',       'ads', 'INTERNAL','ads.rank_result',             '{ads_stage5_run}',
        null,         'jobs/ads/rank_and_review.py',       '项目组', '加权汇总 + 人工复核')
ON CONFLICT (job_code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 8.2 数据质量门禁规则
--    expression 返回违规行数，0 即通过
-- ---------------------------------------------------------------------------
INSERT INTO meta.data_quality_rule (rule_code, target_table, rule_type, severity, expression, description) VALUES
    ('DQ_COMPOUND_INCHIKEY_NN', 'dwd.dim_compound', 'not_null', 'error',
     'SELECT count(*) FROM dwd.dim_compound WHERE inchikey IS NULL',
     'InChIKey 为空：主键失效，禁止发布'),
    ('DQ_COMPOUND_INCHIKEY_FMT', 'dwd.dim_compound', 'regex', 'error',
     'SELECT count(*) FROM dwd.dim_compound WHERE inchikey !~ ''^[A-Z]{14}-[A-Z]{10}-[A-Z]$''',
     'InChIKey 格式不合规：RDKit 标准化可能被绕过'),
    ('DQ_COMPOUND_NO_SMILES', 'dwd.dim_compound', 'not_null', 'warn',
     'SELECT count(*) FROM dwd.dim_compound WHERE smiles_isomeric IS NULL',
     '缺少异构 SMILES：三级之后的建模无法进行'),
    ('DQ_COMPOUND_DUP_KEY', 'dwd.dim_compound', 'unique', 'error',
     'SELECT count(*) - count(DISTINCT inchikey) FROM dwd.dim_compound',
     'InChIKey 重复：去重逻辑异常'),
    ('DQ_PROPERTY_NEED_VALUE', 'dwd.fact_property', 'not_null', 'error',
     'SELECT count(*) FROM dwd.fact_property WHERE value_num IS NULL AND value_text IS NULL',
     '性质事实无值'),
    ('DQ_PROPERTY_MODEL_TRACE', 'dwd.fact_property', 'referential', 'warn',
     'SELECT count(*) FROM dwd.fact_property WHERE value_type = ''predicted'' AND model_version IS NULL',
     '预测值未记录模型版本：不可复现'),
    ('DQ_ACTIVITY_UNIT', 'dwd.fact_activity', 'not_null', 'warn',
     'SELECT count(*) FROM dwd.fact_activity WHERE value_num IS NOT NULL AND unit IS NULL',
     '活性数值缺单位'),
    ('DQ_SETP1_MODEL_SNAPSHOT', 'ads.screen_run', 'coverage', 'warn',
     'SELECT count(*) FROM ads.screen_run WHERE status = ''completed'' AND model_snapshot = ''{}''::jsonb',
     '已完成的 run 缺少模型快照：结果无法复算'),
    ('DQ_S3_MARGIN_DIRTY', 'ads.stage3_safety_screen', 'range', 'warn',
     'SELECT count(*) FROM ads.stage3_safety_screen WHERE safety_margin IS NOT NULL AND safety_margin < 0',
     '安全边际出现负值：分子数或单位换算错误'),
    ('DQ_RANK_SCORE_RANGE', 'ads.rank_result', 'range', 'error',
     'SELECT count(*) FROM ads.rank_result WHERE final_score < 0 OR final_score > 100',
     '综合得分越界（应 0-100）'),
    ('DQ_LINEAGE_FRESH', 'meta.lineage_event', 'freshness', 'info',
     'SELECT CASE WHEN max(occurred_at) IS NULL OR max(occurred_at) < now() - interval ''7 days'' THEN 1 ELSE 0 END FROM meta.lineage_event',
     '血缘事件超过 7 天未更新：检查流水线是否停摆')
ON CONFLICT (rule_code) DO NOTHING;

COMMIT;
