-- ============================================================================
-- 005_dwd_layer.sql
-- DWD 标准层：去盐去重后的分子主数据 + 活性/物性/配伍事实
--
-- 核心约定：
--   * dim_compound 以 InChIKey 为唯一键；盐/水合物/立体异构经 RDKit 标准化后
--     归并到 parent（is_desalted_parent = true），子体通过 parent_compound_sk 挂靠。
--   * 一切数值型性质都进 fact_property（长表），用 property_code + value_type +
--     model_version 三元定位来源，保证"同名不同法"的数值不会互相覆盖。
--   * fact_activity 里保留源行主键（source_system + source_record_id）唯一约束，
--     使 ETL 可幂等重跑。
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 5.0 领域类型
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname = 'dom_inchikey' AND n.nspname = 'dwd'
    ) THEN
        CREATE DOMAIN dwd.dom_inchikey AS text
            CONSTRAINT ck_inchikey_format CHECK (VALUE ~ '^[A-Z]{14}-[A-Z]{10}-[A-Z]$');
    END IF;
END $$;
COMMENT ON DOMAIN dwd.dom_inchikey IS 'InChIKey 标准格式校验：14-10-1 三段式，全大写字母';

-- ---------------------------------------------------------------------------
-- 5.1 分子主数据
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dwd.dim_compound (
    compound_sk        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    inchikey           dwd.dom_inchikey NOT NULL,
    inchikey_skeleton  text GENERATED ALWAYS AS (split_part(inchikey::text, '-', 1)) STORED,
    inchi              text,
    smiles_canonical   text,
    smiles_isomeric    text,
    molecular_formula  text,
    molecular_weight   numeric(12, 4),
    charge             smallint,
    heavy_atom_count   integer,
    ring_count         integer,
    compound_class     text NOT NULL DEFAULT 'small_molecule'
                       CHECK (compound_class IN ('small_molecule', 'polymer', 'oligomer',
                                                 'lipid', 'inorganic', 'peptide', 'other')),
    is_desalted_parent boolean NOT NULL DEFAULT true,
    parent_compound_sk bigint REFERENCES dwd.dim_compound(compound_sk),
    salt_form_note     text,
    structure_quality  text NOT NULL DEFAULT 'valid'
                       CHECK (structure_quality IN ('valid', 'suspect', 'invalid')),
    quality_flags      jsonb NOT NULL DEFAULT '{}'::jsonb,
    first_batch_id     uuid REFERENCES meta.fetch_batch(batch_id),
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_dim_compound_inchikey UNIQUE (inchikey),
    CONSTRAINT ck_parent_not_self CHECK (parent_compound_sk IS NULL OR parent_compound_sk <> compound_sk)
);
COMMENT ON TABLE dwd.dim_compound IS 'DWD 分子主数据：唯一键 InChIKey，去盐/去重后的标准结构单位（SCU）';
COMMENT ON COLUMN dwd.dim_compound.inchikey_skeleton IS 'InChIKey 前 14 位，标识骨架；用于同系物/盐型归并';
COMMENT ON COLUMN dwd.dim_compound.is_desalted_parent IS '是否为去盐后的母体分子；false 表示保留的盐型/水合物实体';
COMMENT ON COLUMN dwd.dim_compound.quality_flags IS '结构质量标记，例如 {"multi_component":true,"stereo_undefined":3}';

CREATE INDEX IF NOT EXISTS ix_dim_compound_skeleton ON dwd.dim_compound (inchikey_skeleton);
CREATE INDEX IF NOT EXISTS ix_dim_compound_class ON dwd.dim_compound (compound_class);
CREATE INDEX IF NOT EXISTS ix_dim_compound_parent ON dwd.dim_compound (parent_compound_sk);

DROP TRIGGER IF EXISTS trg_dim_compound_touch ON dwd.dim_compound;
CREATE TRIGGER trg_dim_compound_touch
    BEFORE UPDATE ON dwd.dim_compound
    FOR EACH ROW EXECUTE FUNCTION meta.fn_touch_updated_at();

-- ---------------------------------------------------------------------------
-- 5.2 外部标识映射（追溯"这个分子来自哪几条源记录"）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dwd.dim_compound_xref (
    xref_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    compound_sk      bigint NOT NULL REFERENCES dwd.dim_compound(compound_sk) ON DELETE CASCADE,
    source_system    text NOT NULL REFERENCES meta.source_system(source_code),
    source_record_id text NOT NULL,
    match_rule       text NOT NULL DEFAULT 'inchikey_exact'
                     CHECK (match_rule IN ('inchikey_exact', 'inchikey_skeleton',
                                           'inchikey_full', 'cas', 'unii', 'name_fuzzy', 'manual')),
    match_confidence numeric(4, 3) NOT NULL DEFAULT 1.000
                     CHECK (match_confidence BETWEEN 0 AND 1),
    batch_id         uuid REFERENCES meta.fetch_batch(batch_id),
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_xref_source_record UNIQUE (source_system, source_record_id)
);
COMMENT ON TABLE dwd.dim_compound_xref IS '分子-源记录映射：同一 InChIKey 可能来自 PubChem CID、ChEMBL ID、DrugBank ID，全部登记以支持回溯';
COMMENT ON COLUMN dwd.dim_compound_xref.match_confidence IS '匹配置信度；名字模糊匹配会低于 1，安全深筛时可按阈值过滤';

CREATE INDEX IF NOT EXISTS ix_xref_compound ON dwd.dim_compound_xref (compound_sk);

-- ---------------------------------------------------------------------------
-- 5.3 靶点 / 测定方法
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dwd.dim_target (
    target_sk     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    target_code   text NOT NULL,
    source_system text NOT NULL REFERENCES meta.source_system(source_code),
    pref_name     text NOT NULL,
    target_type   text,
    organism      text,
    uniprot_id    text,
    gene_symbol   text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_dim_target UNIQUE (source_system, target_code)
);
COMMENT ON TABLE dwd.dim_target IS 'DWD 靶点维表（含蛋白、转运体、离子通道；辅料相互作用同样需要）';

CREATE TABLE IF NOT EXISTS dwd.dim_assay (
    assay_sk         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    assay_code       text NOT NULL,
    source_system    text NOT NULL REFERENCES meta.source_system(source_code),
    target_sk        bigint REFERENCES dwd.dim_target(target_sk),
    assay_type       text,
    description      text,
    organism         text,
    confidence_score integer,
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_dim_assay UNIQUE (source_system, assay_code)
);
COMMENT ON TABLE dwd.dim_assay IS 'DWD 测定方法维表：承载可信度分级，用于活性数据加权';

-- ---------------------------------------------------------------------------
-- 5.4 性质事实（长表）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dwd.fact_property (
    property_fact_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    compound_sk      bigint NOT NULL REFERENCES dwd.dim_compound(compound_sk) ON DELETE CASCADE,
    property_code    text NOT NULL REFERENCES ref.property_def(property_code),
    value_type       text NOT NULL
                     CHECK (value_type IN ('computed', 'measured', 'predicted', 'curated')),
    value_num        numeric,
    value_text       text,
    unit             text REFERENCES ref.unit(unit_code),
    qualifier        text NOT NULL DEFAULT '='
                     CHECK (qualifier IN ('=', '<', '>', '<=', '>=', '~')),
    temperature_c    numeric,
    ph               numeric,
    method           text,
    model_code       text,
    model_version    text,
    source_system    text REFERENCES meta.source_system(source_code),
    source_record_id text,
    confidence       numeric(4, 3) CHECK (confidence BETWEEN 0 AND 1),
    batch_id         uuid REFERENCES meta.fetch_batch(batch_id),
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_property_has_value CHECK (value_num IS NOT NULL OR value_text IS NOT NULL),
    CONSTRAINT fk_property_model FOREIGN KEY (model_code, model_version)
        REFERENCES ref.model_registry (model_code, model_version)
);
COMMENT ON TABLE dwd.fact_property IS 'DWD 性质事实长表：计算值/实测值/预测值统一存放，用 value_type + model_version 区分来源';
COMMENT ON COLUMN dwd.fact_property.qualifier IS '数值限定符，处理 "> 300 °C 分解" 这类无法精确测量的记录';

-- 同一分子 + 同一性质 + 同一来源 + 同一条件 只保留一条，保证 ETL 幂等
CREATE UNIQUE INDEX IF NOT EXISTS uq_fact_property_business_key ON dwd.fact_property (
    compound_sk,
    property_code,
    value_type,
    COALESCE(source_system, ''),
    COALESCE(model_code, ''),
    COALESCE(model_version, ''),
    COALESCE(temperature_c, -9999),
    COALESCE(ph, -9999)
);
CREATE INDEX IF NOT EXISTS ix_fact_property_lookup ON dwd.fact_property (property_code, value_num);
CREATE INDEX IF NOT EXISTS ix_fact_property_compound_type ON dwd.fact_property (compound_sk, value_type);

-- ---------------------------------------------------------------------------
-- 5.5 活性事实
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dwd.fact_activity (
    activity_fact_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    compound_sk        bigint NOT NULL REFERENCES dwd.dim_compound(compound_sk) ON DELETE CASCADE,
    target_sk          bigint REFERENCES dwd.dim_target(target_sk),
    assay_sk           bigint REFERENCES dwd.dim_assay(assay_sk),
    activity_type      text NOT NULL,
    relation           text NOT NULL DEFAULT '='
                       CHECK (relation IN ('=', '<', '>', '<=', '>=', '~')),
    value_num          numeric,
    unit               text REFERENCES ref.unit(unit_code),
    p_value            numeric,
    is_potential_duplicate boolean NOT NULL DEFAULT false,
    data_validity      text,
    quality_score      numeric(4, 3) CHECK (quality_score BETWEEN 0 AND 1),
    source_system      text NOT NULL REFERENCES meta.source_system(source_code),
    source_record_id   text NOT NULL,
    batch_id           uuid REFERENCES meta.fetch_batch(batch_id),
    created_at         timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE dwd.fact_activity IS 'DWD 活性事实：IC50/EC50/Ki/Kd/Tm 等，保留原始限定符与有效性注释';
COMMENT ON COLUMN dwd.fact_activity.p_value IS '-log10(摩尔浓度)，跨单位可比，用于活性排序';

CREATE UNIQUE INDEX IF NOT EXISTS uq_fact_activity_source ON dwd.fact_activity (source_system, source_record_id);
CREATE INDEX IF NOT EXISTS ix_fact_activity_compound ON dwd.fact_activity (compound_sk, activity_type);
CREATE INDEX IF NOT EXISTS ix_fact_activity_target ON dwd.fact_activity (target_sk, activity_type);

-- ---------------------------------------------------------------------------
-- 5.6 配伍事实（API × 辅料）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dwd.fact_compatibility (
    compat_fact_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    api_compound_sk  bigint NOT NULL REFERENCES dwd.dim_compound(compound_sk),
    excipient_compound_sk bigint NOT NULL REFERENCES dwd.dim_compound(compound_sk),
    test_method      text NOT NULL,
    ratio_text       text,
    temperature_c    numeric,
    humidity_pct     numeric,
    duration_days    numeric,
    result_summary   jsonb NOT NULL DEFAULT '{}'::jsonb,
    stability_score  numeric,
    is_compatible    boolean,
    source_system    text NOT NULL REFERENCES meta.source_system(source_code),
    source_record_id text,
    batch_id         uuid REFERENCES meta.fetch_batch(batch_id),
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_compat_not_self CHECK (api_compound_sk <> excipient_compound_sk)
);
COMMENT ON TABLE dwd.fact_compatibility IS 'DWD 配伍事实：API-辅料在不同温湿度/时长下的稳定性结果（DSC、HPLC 含量、有关物质）';
COMMENT ON COLUMN dwd.fact_compatibility.stability_score IS '归一化配伍得分，越高越稳定；由 result_summary 派生，便于排序';

CREATE UNIQUE INDEX IF NOT EXISTS uq_fact_compat_business_key ON dwd.fact_compatibility (
    api_compound_sk, excipient_compound_sk, test_method,
    COALESCE(ratio_text, ''), COALESCE(temperature_c, -9999), COALESCE(duration_days, -1)
);
CREATE INDEX IF NOT EXISTS ix_fact_compat_api ON dwd.fact_compatibility (api_compound_sk);

-- ---------------------------------------------------------------------------
-- 5.7 辅料功能桥表（分子 ↔ 功能角色）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dwd.bridge_compound_function (
    compound_sk   bigint NOT NULL REFERENCES dwd.dim_compound(compound_sk) ON DELETE CASCADE,
    function_code text NOT NULL REFERENCES ref.excipient_function(function_code),
    is_primary    boolean NOT NULL DEFAULT false,
    evidence      text,
    source_system text REFERENCES meta.source_system(source_code),
    confidence    numeric(4, 3) DEFAULT 1.0 CHECK (confidence BETWEEN 0 AND 1),
    created_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (compound_sk, function_code)
);
COMMENT ON TABLE dwd.bridge_compound_function IS '辅料功能桥表：一个分子可承担多种功能（如 PVP 既是黏合剂又是增溶剂），二级筛选用它找候选集合';
COMMENT ON COLUMN dwd.bridge_compound_function.is_primary IS '主功能标记，功能匹配打分时权重更高';

CREATE INDEX IF NOT EXISTS ix_bridge_function ON dwd.bridge_compound_function (function_code);

-- ---------------------------------------------------------------------------
-- 5.8 辅料规格/级别（供应侧，第五级放大评估的输入）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dwd.dim_excipient_grade (
    grade_sk          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    compound_sk       bigint NOT NULL REFERENCES dwd.dim_compound(compound_sk) ON DELETE CASCADE,
    grade_code        text NOT NULL,
    compendial_status text,
    supplier          text,
    is_gmp            boolean,
    particle_size_d50_um numeric,
    bulk_density_g_ml numeric,
    moisture_pct      numeric,
    purity_pct        numeric,
    price_cny_per_kg  numeric,
    lead_time_days    integer,
    min_order_qty_kg  numeric,
    source_system     text REFERENCES meta.source_system(source_code),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_excipient_grade UNIQUE NULLS NOT DISTINCT (compound_sk, grade_code, supplier)
);
COMMENT ON TABLE dwd.dim_excipient_grade IS '辅料级别与供应信息：同一化合物不同级别（如 HPMC E5/E15）性能差异显著，必须分级别管理';

DROP TRIGGER IF EXISTS trg_excipient_grade_touch ON dwd.dim_excipient_grade;
CREATE TRIGGER trg_excipient_grade_touch
    BEFORE UPDATE ON dwd.dim_excipient_grade
    FOR EACH ROW EXECUTE FUNCTION meta.fn_touch_updated_at();

-- ---------------------------------------------------------------------------
-- 5.9 DWD 便捷视图
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW dwd.v_compound_master AS
SELECT
    c.compound_sk,
    c.inchikey,
    c.inchikey_skeleton,
    c.molecular_formula,
    c.molecular_weight,
    c.compound_class,
    max(p.value_num) FILTER (WHERE p.property_code = 'LOGP'  AND p.value_type = 'computed') AS logp,
    max(p.value_num) FILTER (WHERE p.property_code = 'TPSA'  AND p.value_type = 'computed') AS tpsa,
    max(p.value_num) FILTER (WHERE p.property_code = 'HBD'   AND p.value_type = 'computed') AS hbd,
    max(p.value_num) FILTER (WHERE p.property_code = 'HBA'   AND p.value_type = 'computed') AS hba,
    max(p.value_num) FILTER (WHERE p.property_code = 'ROT_BONDS' AND p.value_type = 'computed') AS rot_bonds,
    max(p.value_num) FILTER (WHERE p.property_code = 'MELTING_POINT' AND p.value_type IN ('measured','curated')) AS melting_point_c,
    max(p.value_num) FILTER (WHERE p.property_code = 'WATER_SOLUBILITY') AS water_solubility_mg_ml,
    count(DISTINCT f.function_code) AS function_cnt,
    count(DISTINCT x.source_system) AS source_cnt
FROM dwd.dim_compound c
LEFT JOIN dwd.fact_property p ON p.compound_sk = c.compound_sk
LEFT JOIN dwd.bridge_compound_function f ON f.compound_sk = c.compound_sk
LEFT JOIN dwd.dim_compound_xref x ON x.compound_sk = c.compound_sk
GROUP BY c.compound_sk, c.inchikey, c.inchikey_skeleton, c.molecular_formula,
         c.molecular_weight, c.compound_class;
COMMENT ON VIEW dwd.v_compound_master IS '分子主数据宽视图：主键 + 核心物性 + 功能数 + 数据源数，供快速浏览与二级筛选取数';

COMMIT;
