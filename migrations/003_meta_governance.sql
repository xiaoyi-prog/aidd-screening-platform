-- ============================================================================
-- 003_meta_governance.sql
-- META 治理层：源系统、抓取批次、ETL 作业与运行、数据质量、全链路血缘
-- 设计要点：
--   * 任何一条 ODS 记录都必须挂在某个 fetch_batch 上，实现"整批可回放"
--   * 任何一次转换/预测都必须写 lineage_event，实现"可复现、可追溯"
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 3.1 源系统
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS meta.source_system (
    source_code           text PRIMARY KEY,
    source_name           text NOT NULL,
    source_type           text NOT NULL
                          CHECK (source_type IN ('public_db', 'regulatory', 'literature', 'vendor', 'internal', 'computed')),
    homepage              text,
    license_note          text,
    refresh_cadence       text,
    default_snapshot_label text,
    is_active             boolean NOT NULL DEFAULT true,
    notes                 text
);
COMMENT ON TABLE meta.source_system IS '数据源登记：公开库/法规库/文献/供应商/内部实验，含许可与更新频率，便于合规审计';

INSERT INTO meta.source_system (source_code, source_name, source_type, homepage, license_note, refresh_cadence, default_snapshot_label, notes) VALUES
    ('PUBCHEM', 'PubChem',                'public_db',  'https://pubchem.ncbi.nlm.nih.gov', '公共领域（NCBI）',       '季度', 'pubchem_quarterly', '结构与基础物性、生物测定'),
    ('CHEMBL',  'ChEMBL',                 'public_db',  'https://www.ebi.ac.uk/chembl',     'CC BY-SA 4.0',          '季度', 'chembl_release',    '活性数据 gold standard'),
    ('DRUGBANK','DrugBank',               'public_db',  'https://go.drugbank.com',          '学术许可，商用需授权',    '半年', 'drugbank_release',  '药物-靶点-相互作用'),
    ('FDA_IID', 'FDA Inactive Ingredient Database', 'regulatory', 'https://www.fda.gov/drugs/drug-approvals-and-databases/inactive-ingredients-approved-drug-products-search-fda-database', '公开', '季度', 'fda_iid', '已批准制剂中辅料的用量与途径'),
    ('FDA_IIG', 'FDA Inactive Ingredient Guide',    'regulatory', 'https://www.fda.gov', '公开', '季度', 'fda_iig', '按途径-剂型的最大用量'),
    ('CHP',     '中国药典',               'regulatory', null, '内部订阅', '五年', 'chp_edition', '国内申报必备限度'),
    ('USP',     'USP-NF',                 'regulatory', null, '内部订阅', '年度', 'usp_edition', '辅料各论'),
    ('EP',      'Ph. Eur.',               'regulatory', null, '内部订阅', '三年', 'ep_edition', '欧盟申报'),
    ('VENDOR',  '供应商 COA / 规格书',    'vendor',     null, '商业保密', '按需', 'vendor_coa', '实测纯度、粒径、价格、交期'),
    ('INTERNAL','内部实验与历史项目',     'internal',   null, '商业保密', '持续', 'internal_lab', 'DSC/配伍/稳定性实验数据'),
    ('RDKIT',   'RDKit 计算管线',         'computed',   'https://www.rdkit.org', 'BSD-3', '随镜像', 'rdkit_2024_09', '标准化描述符计算'),
    ('MODEL',   'AI 模型推理服务',        'computed',   null, '内部', '随模型', 'model_inference', '预测值来源')
ON CONFLICT (source_code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3.2 抓取批次（ODS 的锚点）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS meta.fetch_batch (
    batch_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_code        text NOT NULL REFERENCES meta.source_system(source_code),
    snapshot_label     text NOT NULL,
    source_release     text,
    request_params     jsonb NOT NULL DEFAULT '{}'::jsonb,
    fetch_started_at   timestamptz NOT NULL DEFAULT now(),
    fetch_finished_at  timestamptz,
    record_count       bigint,
    checksum_sha256    text,
    status             text NOT NULL DEFAULT 'running'
                       CHECK (status IN ('running', 'success', 'partial', 'failed')),
    operator           text DEFAULT current_user,
    notes              text,
    CONSTRAINT ck_batch_time CHECK (fetch_finished_at IS NULL OR fetch_finished_at >= fetch_started_at)
);
COMMENT ON TABLE meta.fetch_batch IS '抓取批次：ODS 每行的 batch_id 指向此处，记录快照标签、源版本、请求参数与校验和，支持任意批次回放';

CREATE INDEX IF NOT EXISTS ix_fetch_batch_source_time
    ON meta.fetch_batch (source_code, fetch_started_at DESC);
CREATE INDEX IF NOT EXISTS ix_fetch_batch_params
    ON meta.fetch_batch USING gin (request_params);

-- ---------------------------------------------------------------------------
-- 3.3 ETL 作业与运行
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS meta.etl_job (
    job_code       text PRIMARY KEY,
    job_name       text NOT NULL,
    layer          text NOT NULL CHECK (layer IN ('ods', 'dwd', 'ads', 'ref', 'meta')),
    source_code    text REFERENCES meta.source_system(source_code),
    target_table   text,
    depends_on     text[] NOT NULL DEFAULT '{}',
    schedule_cron  text,
    entrypoint     text,
    owner          text,
    is_active      boolean NOT NULL DEFAULT true,
    description    text
);
COMMENT ON TABLE meta.etl_job IS 'ETL 作业注册：声明依赖、调度表达式与入口，供编排器（Airflow/Dagster/自研）读取';

CREATE TABLE IF NOT EXISTS meta.etl_run (
    run_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    job_code         text NOT NULL REFERENCES meta.etl_job(job_code),
    batch_id         uuid REFERENCES meta.fetch_batch(batch_id),
    parent_run_id    uuid REFERENCES meta.etl_run(run_id),
    started_at       timestamptz NOT NULL DEFAULT now(),
    finished_at      timestamptz,
    status           text NOT NULL DEFAULT 'running'
                     CHECK (status IN ('running', 'success', 'partial', 'failed', 'skipped')),
    rows_read        bigint DEFAULT 0,
    rows_written     bigint DEFAULT 0,
    rows_rejected    bigint DEFAULT 0,
    params           jsonb NOT NULL DEFAULT '{}'::jsonb,
    code_version     text,
    container_image  text,
    error_message    text
);
COMMENT ON TABLE meta.etl_run IS 'ETL 运行实例：记录代码版本、镜像、参数与读写行数，是"同参数同代码可复现"的凭证';

CREATE INDEX IF NOT EXISTS ix_etl_run_job_time ON meta.etl_run (job_code, started_at DESC);
CREATE INDEX IF NOT EXISTS ix_etl_run_batch ON meta.etl_run (batch_id);

-- ---------------------------------------------------------------------------
-- 3.4 数据质量规则与结果
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS meta.data_quality_rule (
    rule_code    text PRIMARY KEY,
    target_table text NOT NULL,
    rule_type    text NOT NULL
                 CHECK (rule_type IN ('not_null', 'unique', 'regex', 'range', 'referential',
                                      'freshness', 'rowcount', 'coverage', 'custom')),
    severity     text NOT NULL CHECK (severity IN ('error', 'warn', 'info')),
    expression   text NOT NULL,
    description  text,
    is_active    boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE meta.data_quality_rule IS '数据质量规则：expression 返回违规行数，0 表示通过';
COMMENT ON COLUMN meta.data_quality_rule.expression IS '一段返回 bigint 的 SQL，例如 SELECT count(*) FROM dwd.dim_compound WHERE inchikey IS NULL';

CREATE TABLE IF NOT EXISTS meta.data_quality_result (
    result_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_code       text NOT NULL REFERENCES meta.data_quality_rule(rule_code),
    run_id          uuid REFERENCES meta.etl_run(run_id),
    checked_at      timestamptz NOT NULL DEFAULT now(),
    passed          boolean NOT NULL,
    violation_count bigint NOT NULL DEFAULT 0,
    sample_payload  jsonb
);
COMMENT ON TABLE meta.data_quality_result IS '数据质量检查结果：每次 ETL 后按规则跑一遍，作为发布门禁';

CREATE INDEX IF NOT EXISTS ix_dq_result_time ON meta.data_quality_result (checked_at DESC);
CREATE INDEX IF NOT EXISTS ix_dq_result_rule ON meta.data_quality_result (rule_code, checked_at DESC);

-- ---------------------------------------------------------------------------
-- 3.5 全链路血缘（按月分区）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS meta.lineage_event (
    event_id      bigint GENERATED ALWAYS AS IDENTITY,
    occurred_at   timestamptz NOT NULL DEFAULT now(),
    run_id        uuid,
    layer         text,
    entity_type   text NOT NULL,
    entity_key    text NOT NULL,
    action        text NOT NULL,
    stage_no      smallint,
    model_code    text,
    model_version text,
    params        jsonb NOT NULL DEFAULT '{}'::jsonb,
    input_hash    text,
    output_hash   text,
    actor         text DEFAULT current_user,
    PRIMARY KEY (event_id, occurred_at)
) PARTITION BY RANGE (occurred_at);
COMMENT ON TABLE meta.lineage_event IS '血缘事件流：ingest→transform→predict→screen→export 全链路，按月分区，用于回答"这个结论是怎么来的"';
COMMENT ON COLUMN meta.lineage_event.entity_key IS '被操作实体主键，分子统一用 InChIKey，候选统一用 run_id:compound_sk';
COMMENT ON COLUMN meta.lineage_event.input_hash IS '输入端内容 sha256，配合 output_hash 可判断重算是否产生差异';

-- 分区自动创建函数
CREATE OR REPLACE FUNCTION meta.fn_ensure_lineage_partition(p_ts timestamptz)
RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    v_start date := date_trunc('month', p_ts)::date;
    v_end   date := (v_start + interval '1 month')::date;
    v_name  text := format('lineage_event_%s', to_char(v_start, 'YYYYMM'));
BEGIN
    IF to_regclass(format('meta.%I', v_name)) IS NOT NULL THEN
        RETURN v_name;
    END IF;
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS meta.%I PARTITION OF meta.lineage_event FOR VALUES FROM (%L) TO (%L)',
        v_name, v_start, v_end);
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS %I ON meta.%I (entity_type, entity_key, occurred_at DESC)',
        v_name || '_entity_ix', v_name);
    RETURN v_name;
END;
$$;
COMMENT ON FUNCTION meta.fn_ensure_lineage_partition(timestamptz) IS '按需创建当月血缘分区（幂等）';

-- 滚动预建 n 个月分区，建议每次 ETL 启动时调用
CREATE OR REPLACE FUNCTION meta.fn_roll_lineage_partitions(p_months integer DEFAULT 3)
RETURNS text[]
LANGUAGE plpgsql AS $$
DECLARE
    v_i    integer;
    v_out  text[] := '{}';
BEGIN
    FOR v_i IN 0 .. (p_months - 1) LOOP
        v_out := v_out || meta.fn_ensure_lineage_partition(now() + (v_i || ' month')::interval);
    END LOOP;
    RETURN v_out;
END;
$$;
COMMENT ON FUNCTION meta.fn_roll_lineage_partitions(integer) IS '滚动预建未来 n 个月的血缘分区，默认 3 个月';

-- 插入时自动兜底建分区（PK 落在 13+ 才支持分区表行级 BEFORE 触发器）
CREATE OR REPLACE FUNCTION meta.fn_lineage_autopart()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM meta.fn_ensure_lineage_partition(NEW.occurred_at);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_lineage_autopart ON meta.lineage_event;
CREATE TRIGGER trg_lineage_autopart
    BEFORE INSERT ON meta.lineage_event
    FOR EACH ROW EXECUTE FUNCTION meta.fn_lineage_autopart();

SELECT meta.fn_roll_lineage_partitions(3);

COMMIT;
