-- ============================================================================
-- 004_ods_layer.sql
-- ODS 贴源层：结构与源一致 + raw_payload JSONB + fetch_batch_id + 审计列
--
-- 统一审计列（所有 ODS 表都有）：
--   batch_id      uuid        所属抓取批次，外键 → meta.fetch_batch
--   ingested_at   timestamptz 入库时间
--   src_row_hash  text        源记录内容 sha256，用于增量比对 / 判重
--   raw_payload   jsonb       原始报文（API JSON / XML 转 JSON），便于回溯与重解析
--
-- 设计原则：
--   1) 只做"原样落地 + 最小必要拆列"，不做任何业务清洗（清洗在 DWD）。
--   2) 主键包含 batch_id，天然保留历史快照，可对比两次源发版的差异。
--   3) 所有自然键建索引，DWD 落地时按自然键回查最新批次。
-- ============================================================================

BEGIN;

-- ===========================================================================
-- 一、PubChem
-- ===========================================================================
CREATE TABLE IF NOT EXISTS ods.pubchem_compound (
    cid                        bigint NOT NULL,
    molecular_formula          text,
    molecular_weight           numeric,
    exact_mass                 numeric,
    canonical_smiles           text,
    isomeric_smiles            text,
    inchi                      text,
    inchikey                   text,
    iupac_name                 text,
    charge                     smallint,
    heavy_atom_count           integer,
    defined_atom_stereo_count  integer,
    undefined_atom_stereo_count integer,
    defined_bond_stereo_count  integer,
    undefined_bond_stereo_count integer,
    isotope_atom_count         integer,
    component_count            integer,
    covalent_unit_count        integer,
    -- 审计列
    batch_id                   uuid NOT NULL REFERENCES meta.fetch_batch(batch_id),
    ingested_at                timestamptz NOT NULL DEFAULT now(),
    src_row_hash               text NOT NULL,
    raw_payload                jsonb NOT NULL,
    PRIMARY KEY (batch_id, cid)
);
COMMENT ON TABLE ods.pubchem_compound IS 'ODS-PubChem 化合物主记录（PUG-View 结构区块），一行一个 CID';

CREATE INDEX IF NOT EXISTS ix_ods_pubchem_compound_cid ON ods.pubchem_compound (cid);
CREATE INDEX IF NOT EXISTS ix_ods_pubchem_compound_inchikey ON ods.pubchem_compound (inchikey);
CREATE INDEX IF NOT EXISTS ix_ods_pubchem_compound_iupac_trgm
    ON ods.pubchem_compound USING gin (iupac_name gin_trgm_ops);

CREATE TABLE IF NOT EXISTS ods.pubchem_property (
    record_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cid            bigint NOT NULL,
    property_name  text NOT NULL,
    value_text     text,
    value_num      numeric,
    unit           text,
    source_name    text,
    -- 审计列
    batch_id       uuid NOT NULL REFERENCES meta.fetch_batch(batch_id),
    ingested_at    timestamptz NOT NULL DEFAULT now(),
    src_row_hash   text NOT NULL,
    raw_payload    jsonb NOT NULL,
    CONSTRAINT uq_ods_pubchem_property UNIQUE NULLS NOT DISTINCT
        (batch_id, cid, property_name, source_name, value_text)
);
COMMENT ON TABLE ods.pubchem_property IS 'ODS-PubChem 属性长表（PUG-View 全部 section），保留每条属性的原始来源，不做单位换算';

CREATE INDEX IF NOT EXISTS ix_ods_pubchem_property_cid ON ods.pubchem_property (cid);
CREATE INDEX IF NOT EXISTS ix_ods_pubchem_property_name ON ods.pubchem_property (property_name);

CREATE TABLE IF NOT EXISTS ods.pubchem_synonym (
    record_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cid          bigint NOT NULL,
    synonym      text NOT NULL,
    synonym_lang text,
    synonym_type text,
    batch_id     uuid NOT NULL REFERENCES meta.fetch_batch(batch_id),
    ingested_at  timestamptz NOT NULL DEFAULT now(),
    src_row_hash text NOT NULL,
    raw_payload  jsonb NOT NULL,
    CONSTRAINT uq_ods_pubchem_synonym UNIQUE (batch_id, cid, synonym)
);
COMMENT ON TABLE ods.pubchem_synonym IS 'ODS-PubChem 别名表：辅料俗称/商品名与 CID 的映射来源';

CREATE INDEX IF NOT EXISTS ix_ods_pubchem_synonym_trgm
    ON ods.pubchem_synonym USING gin (synonym gin_trgm_ops);

CREATE TABLE IF NOT EXISTS ods.pubchem_classification (
    record_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cid         bigint NOT NULL,
    mesh_id     text,
    mesh_heading text,
    annotation  text,
    batch_id    uuid NOT NULL REFERENCES meta.fetch_batch(batch_id),
    ingested_at timestamptz NOT NULL DEFAULT now(),
    src_row_hash text NOT NULL,
    raw_payload jsonb NOT NULL,
    CONSTRAINT uq_ods_pubchem_classification UNIQUE NULLS NOT DISTINCT (batch_id, cid, mesh_id)
);
COMMENT ON TABLE ods.pubchem_classification IS 'ODS-PubChem MeSH 分类：判断"是否辅料/高分子/脂类"的候选来源';

-- ===========================================================================
-- 二、ChEMBL
-- ===========================================================================
CREATE TABLE IF NOT EXISTS ods.chembl_molecule (
    chembl_id          text NOT NULL,
    pref_name          text,
    molecule_type      text,
    max_phase          numeric,
    first_approval     integer,
    oral               boolean,
    parenteral         boolean,
    topical            boolean,
    natural_product    boolean,
    chirality          integer,
    structure_type     text,
    canonical_smiles   text,
    standard_inchi     text,
    standard_inchikey  text,
    molecular_formula  text,
    molecular_weight   numeric,
    black_box_warning  integer,
    withdrawn_flag     boolean,
    -- 审计列
    batch_id           uuid NOT NULL REFERENCES meta.fetch_batch(batch_id),
    ingested_at        timestamptz NOT NULL DEFAULT now(),
    src_row_hash       text NOT NULL,
    raw_payload        jsonb NOT NULL,
    PRIMARY KEY (batch_id, chembl_id)
);
COMMENT ON TABLE ods.chembl_molecule IS 'ODS-ChEMBL 分子主表（molecule_dictionary），字段与源逐列对应';

CREATE INDEX IF NOT EXISTS ix_ods_chembl_molecule_id ON ods.chembl_molecule (chembl_id);
CREATE INDEX IF NOT EXISTS ix_ods_chembl_molecule_inchikey ON ods.chembl_molecule (standard_inchikey);
CREATE INDEX IF NOT EXISTS ix_ods_chembl_molecule_name_trgm
    ON ods.chembl_molecule USING gin (pref_name gin_trgm_ops);

CREATE TABLE IF NOT EXISTS ods.chembl_activity (
    activity_id            bigint NOT NULL,
    assay_id               bigint,
    molecule_chembl_id     text,
    target_chembl_id       text,
    document_chembl_id     text,
    standard_type          text,
    standard_relation      text,
    standard_value         numeric,
    standard_units         text,
    pchembl_value          numeric,
    activity_comment       text,
    data_validity_comment  text,
    potential_duplicate    boolean,
    assay_organism         text,
    -- 审计列
    batch_id               uuid NOT NULL REFERENCES meta.fetch_batch(batch_id),
    ingested_at            timestamptz NOT NULL DEFAULT now(),
    src_row_hash           text NOT NULL,
    raw_payload            jsonb NOT NULL,
    PRIMARY KEY (batch_id, activity_id)
);
COMMENT ON TABLE ods.chembl_activity IS 'ODS-ChEMBL 活性数据（activities），含数据有效性注释与重复标记，清洗留到 DWD';

CREATE INDEX IF NOT EXISTS ix_ods_chembl_activity_mol ON ods.chembl_activity (molecule_chembl_id);
CREATE INDEX IF NOT EXISTS ix_ods_chembl_activity_target ON ods.chembl_activity (target_chembl_id);
CREATE INDEX IF NOT EXISTS ix_ods_chembl_activity_type ON ods.chembl_activity (standard_type);

CREATE TABLE IF NOT EXISTS ods.chembl_assay (
    assay_id          bigint NOT NULL,
    assay_type        text,
    assay_organism    text,
    description       text,
    doc_chembl_id     text,
    target_chembl_id  text,
    confidence_score  integer,
    relationship_type text,
    bao_endpoint      text,
    uo_units          text,
    batch_id          uuid NOT NULL REFERENCES meta.fetch_batch(batch_id),
    ingested_at       timestamptz NOT NULL DEFAULT now(),
    src_row_hash      text NOT NULL,
    raw_payload       jsonb NOT NULL,
    PRIMARY KEY (batch_id, assay_id)
);
COMMENT ON TABLE ods.chembl_assay IS 'ODS-ChEMBL 测定方法（assays），用于活性数据的可信度分级';

CREATE TABLE IF NOT EXISTS ods.chembl_target (
    target_chembl_id  text NOT NULL,
    pref_name         text,
    target_type       text,
    organism          text,
    tax_id            bigint,
    species_group_flag boolean,
    batch_id          uuid NOT NULL REFERENCES meta.fetch_batch(batch_id),
    ingested_at       timestamptz NOT NULL DEFAULT now(),
    src_row_hash      text NOT NULL,
    raw_payload       jsonb NOT NULL,
    PRIMARY KEY (batch_id, target_chembl_id)
);
COMMENT ON TABLE ods.chembl_target IS 'ODS-ChEMBL 靶点（target_dictionary）';

-- ===========================================================================
-- 三、DrugBank
-- ===========================================================================
CREATE TABLE IF NOT EXISTS ods.drugbank_drug (
    drugbank_id        text NOT NULL,
    name               text,
    cas_number         text,
    unii               text,
    inchikey           text,
    smiles             text,
    molecular_formula  text,
    molecular_weight   numeric,
    groups             text[],
    indication         text,
    mechanism_of_action text,
    toxicity           text,
    protein_binding    text,
    half_life          text,
    route_of_elimination text,
    fda_label          boolean,
    batch_id           uuid NOT NULL REFERENCES meta.fetch_batch(batch_id),
    ingested_at        timestamptz NOT NULL DEFAULT now(),
    src_row_hash       text NOT NULL,
    raw_payload        jsonb NOT NULL,
    PRIMARY KEY (batch_id, drugbank_id)
);
COMMENT ON TABLE ods.drugbank_drug IS 'ODS-DrugBank 药物条目（XML drug 节点展平），raw_payload 保留完整节点';

CREATE INDEX IF NOT EXISTS ix_ods_drugbank_drug_inchikey ON ods.drugbank_drug (inchikey);
CREATE INDEX IF NOT EXISTS ix_ods_drugbank_drug_name_trgm
    ON ods.drugbank_drug USING gin (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS ix_ods_drugbank_drug_payload
    ON ods.drugbank_drug USING gin (raw_payload jsonb_path_ops);

CREATE TABLE IF NOT EXISTS ods.drugbank_target (
    record_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    drugbank_id    text NOT NULL,
    target_id      text,
    target_name    text,
    organism       text,
    actions        text[],
    known_action   text,
    batch_id       uuid NOT NULL REFERENCES meta.fetch_batch(batch_id),
    ingested_at    timestamptz NOT NULL DEFAULT now(),
    src_row_hash   text NOT NULL,
    raw_payload    jsonb NOT NULL,
    CONSTRAINT uq_ods_drugbank_target UNIQUE NULLS NOT DISTINCT (batch_id, drugbank_id, target_id)
);
COMMENT ON TABLE ods.drugbank_target IS 'ODS-DrugBank 药物-靶点关系（targets 节点）';

-- ===========================================================================
-- 四、法规类（辅料专属，安全深筛的限值来源）
-- ===========================================================================
CREATE TABLE IF NOT EXISTS ods.fda_iid_entry (
    iid_id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ingredient_name      text NOT NULL,
    unii                 text,
    cas_number           text,
    route_code           text,
    dosage_form_code     text,
    route_text_raw       text,
    dosage_form_text_raw text,
    is_multi_ingredient  boolean,
    batch_id             uuid NOT NULL REFERENCES meta.fetch_batch(batch_id),
    ingested_at          timestamptz NOT NULL DEFAULT now(),
    src_row_hash         text NOT NULL,
    raw_payload          jsonb NOT NULL,
    CONSTRAINT uq_ods_fda_iid UNIQUE NULLS NOT DISTINCT
        (batch_id, ingredient_name, route_code, dosage_form_code)
);
COMMENT ON TABLE ods.fda_iid_entry IS 'ODS-FDA 非活性成分数据库（IID）：某辅料出现在哪些已批准制剂/途径中，用于"已上市可接受性"证据';

CREATE TABLE IF NOT EXISTS ods.fda_iig_limit (
    iig_id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ingredient_name         text NOT NULL,
    unii                    text,
    cas_number              text,
    route_code              text,
    dosage_form_code        text,
    max_potency_per_unit    numeric,
    potency_unit_raw        text,
    max_daily_exposure      numeric,
    exposure_unit_raw       text,
    batch_id                uuid NOT NULL REFERENCES meta.fetch_batch(batch_id),
    ingested_at             timestamptz NOT NULL DEFAULT now(),
    src_row_hash            text NOT NULL,
    raw_payload             jsonb NOT NULL,
    CONSTRAINT uq_ods_fda_iig UNIQUE NULLS NOT DISTINCT
        (batch_id, ingredient_name, route_code, dosage_form_code)
);
COMMENT ON TABLE ods.fda_iig_limit IS 'ODS-FDA 非活性成分指南（IIG）最大用量：按途径-剂型给出用量上限，是安全边际计算的原始依据';

CREATE TABLE IF NOT EXISTS ods.internal_excipient_spec (
    spec_id             text NOT NULL,
    ingredient_name     text NOT NULL,
    cas_number          text,
    inchikey            text,
    grade_code          text,
    compendial_status   text,
    supplier            text,
    function_code       text,
    specification       jsonb,
    coa_payload         jsonb,
    price_cny_per_kg    numeric,
    lead_time_days      integer,
    batch_id            uuid NOT NULL REFERENCES meta.fetch_batch(batch_id),
    ingested_at         timestamptz NOT NULL DEFAULT now(),
    src_row_hash        text NOT NULL,
    raw_payload         jsonb NOT NULL,
    PRIMARY KEY (batch_id, spec_id)
);
COMMENT ON TABLE ods.internal_excipient_spec IS 'ODS-内部辅料规格库：供应商 COA、级别、价格与交期，服务第五级"生产放大评估"';

-- ===========================================================================
-- 五、运维视图
-- ===========================================================================
CREATE OR REPLACE VIEW ods.v_ingest_summary AS
SELECT 'ods.pubchem_compound' AS ods_table, batch_id, count(*) AS rows, max(ingested_at) AS last_ingested_at
  FROM ods.pubchem_compound GROUP BY batch_id
UNION ALL
SELECT 'ods.pubchem_property', batch_id, count(*), max(ingested_at) FROM ods.pubchem_property GROUP BY batch_id
UNION ALL
SELECT 'ods.pubchem_synonym', batch_id, count(*), max(ingested_at) FROM ods.pubchem_synonym GROUP BY batch_id
UNION ALL
SELECT 'ods.pubchem_classification', batch_id, count(*), max(ingested_at) FROM ods.pubchem_classification GROUP BY batch_id
UNION ALL
SELECT 'ods.chembl_molecule', batch_id, count(*), max(ingested_at) FROM ods.chembl_molecule GROUP BY batch_id
UNION ALL
SELECT 'ods.chembl_activity', batch_id, count(*), max(ingested_at) FROM ods.chembl_activity GROUP BY batch_id
UNION ALL
SELECT 'ods.chembl_assay', batch_id, count(*), max(ingested_at) FROM ods.chembl_assay GROUP BY batch_id
UNION ALL
SELECT 'ods.chembl_target', batch_id, count(*), max(ingested_at) FROM ods.chembl_target GROUP BY batch_id
UNION ALL
SELECT 'ods.drugbank_drug', batch_id, count(*), max(ingested_at) FROM ods.drugbank_drug GROUP BY batch_id
UNION ALL
SELECT 'ods.drugbank_target', batch_id, count(*), max(ingested_at) FROM ods.drugbank_target GROUP BY batch_id
UNION ALL
SELECT 'ods.fda_iid_entry', batch_id, count(*), max(ingested_at) FROM ods.fda_iid_entry GROUP BY batch_id
UNION ALL
SELECT 'ods.fda_iig_limit', batch_id, count(*), max(ingested_at) FROM ods.fda_iig_limit GROUP BY batch_id
UNION ALL
SELECT 'ods.internal_excipient_spec', batch_id, count(*), max(ingested_at) FROM ods.internal_excipient_spec GROUP BY batch_id;

COMMENT ON VIEW ods.v_ingest_summary IS 'ODS 各表按批次的落地行数与最后入库时间，用于核对抓取完整性';

COMMIT;
