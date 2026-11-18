-- ============================================================================
-- 010_ods_external_sources.sql
-- 扩展外部生物数据库 ODS：ChEBI / LIPID MAPS / KEGG COMPOUND
--   1) meta.source_system 注册新数据源
--   2) 新增三张 ODS 表（统一审计列：batch_id/ingested_at/src_row_hash/raw_payload）
--   3) 重建 ods.v_ingest_summary，把三张新表纳入批次完整性核对
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. 数据源注册（幂等）
-- ---------------------------------------------------------------------------
INSERT INTO meta.source_system
    (source_code, source_name, source_type, homepage, license_note,
     refresh_cadence, default_snapshot_label, is_active, notes)
VALUES
    ('CHEBI',     'ChEBI（EBI 化学实体本体）', 'public_db',
     'https://www.ebi.ac.uk/chebi/', 'CC BY 4.0',
     'monthly', 'chebi_triterpene_{YYYYMM}', true,
     '2.0 REST：/backend/api/public/compound/{id}，本体 BFS 由 CHEBI:35191(triterpene) 收集'),
    ('LIPIDMAPS', 'LIPID MAPS 结构数据库', 'public_db',
     'https://www.lipidmaps.org/', 'CC BY 4.0',
     'monthly', 'lipidmaps_LMPR0106_{YYYYMM}', true,
     'REST download 表：/rest/compound/lm_id/LMPR0106/all/download（C30 类异戊二烯=三萜）'),
    ('KEGG',      'KEGG COMPOUND', 'public_db',
     'https://www.kegg.jp/kegg/compound/', '学术免费（John Wiley 商用收费）',
     'biweekly', 'kegg_triterpene_{YYYYMM}', true,
     'rest.kegg.jp（注意 rest.kegg.ws 在国内网络不可达）；结构缺失时靠 DBLINKS 交叉映射')
ON CONFLICT (source_code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. ChEBI 实体表
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ods.chebi_entity (
    chebi_id           text NOT NULL,            -- 形如 CHEBI:15414
    name               text,
    definition         text,
    stars              smallint,
    formula            text,
    mass               numeric,
    monoisotopic_mass  numeric,
    charge             integer,
    smiles             text,
    standard_inchi     text,
    standard_inchikey  text,
    parent_class_id    text,                     -- BFS 时直接父类（triterpene 子树内）
    parent_class_name  text,
    cross_refs         jsonb,                    -- database_accessions（KEGG/PubChem/CAS...）
    -- 审计列
    batch_id           uuid NOT NULL REFERENCES meta.fetch_batch(batch_id),
    ingested_at        timestamptz NOT NULL DEFAULT now(),
    src_row_hash       text NOT NULL,
    raw_payload        jsonb NOT NULL,
    PRIMARY KEY (batch_id, chebi_id)
);
COMMENT ON TABLE ods.chebi_entity IS 'ODS-ChEBI 化学实体（triterpene 子树本体闭包），含本体父子关系与跨库引用';

CREATE INDEX IF NOT EXISTS ix_ods_chebi_entity_inchikey ON ods.chebi_entity (standard_inchikey);
CREATE INDEX IF NOT EXISTS ix_ods_chebi_entity_name_trgm
    ON ods.chebi_entity USING gin (name gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- 3. LIPID MAPS 化合物表
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ods.lipidmaps_compound (
    lm_id          text NOT NULL,                -- 形如 LMPR0106010001
    regno          text,
    name           text,
    sys_name       text,
    synonyms       text,
    abbrev         text,
    core           text,                         -- Prenol Lipids [PR]
    main_class     text,                         -- Isoprenoids [PR01]
    sub_class      text,                         -- C30 isoprenoids (triterpenes) [PR0106]
    class_level4   text,
    formula        text,
    exact_mass     numeric,
    inchi          text,
    inchikey       text,
    smiles         text,
    kegg_id        text,
    hmdb_id        text,
    chebi_id       text,
    pubchem_cid    text,
    -- 审计列
    batch_id       uuid NOT NULL REFERENCES meta.fetch_batch(batch_id),
    ingested_at    timestamptz NOT NULL DEFAULT now(),
    src_row_hash   text NOT NULL,
    raw_payload    jsonb NOT NULL,
    PRIMARY KEY (batch_id, lm_id)
);
COMMENT ON TABLE ods.lipidmaps_compound IS 'ODS-LIPID MAPS C30 类异戊二烯（三萜）全类表，LMPR0106 批量 download';

CREATE INDEX IF NOT EXISTS ix_ods_lipidmaps_inchikey ON ods.lipidmaps_compound (inchikey);
CREATE INDEX IF NOT EXISTS ix_ods_lipidmaps_name_trgm
    ON ods.lipidmaps_compound USING gin (name gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- 4. KEGG COMPOUND 表
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ods.kegg_compound (
    entry         text NOT NULL,                 -- 形如 C00751
    name          text,
    formula       text,
    exact_mass    numeric,
    mol_weight    numeric,
    smiles        text,
    inchi         text,
    inchikey      text,
    reactions     text[],
    pathways      text[],
    dblinks       jsonb,                         -- {CAS:[...], PubChem:[...], ChEBI:[...]}
    -- 审计列
    batch_id      uuid NOT NULL REFERENCES meta.fetch_batch(batch_id),
    ingested_at   timestamptz NOT NULL DEFAULT now(),
    src_row_hash  text NOT NULL,
    raw_payload   jsonb NOT NULL,
    PRIMARY KEY (batch_id, entry)
);
COMMENT ON TABLE ods.kegg_compound IS 'ODS-KEGG COMPOUND（squalene/triterpene/hopane 族检索），无结构条目靠 DBLINKS 交叉映射';

CREATE INDEX IF NOT EXISTS ix_ods_kegg_compound_inchikey ON ods.kegg_compound (inchikey);
CREATE INDEX IF NOT EXISTS ix_ods_kegg_compound_name_trgm
    ON ods.kegg_compound USING gin (name gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- 4.5 放宽 xref match_rule 约束：允许跨库引用匹配
-- ---------------------------------------------------------------------------
ALTER TABLE dwd.dim_compound_xref DROP CONSTRAINT IF EXISTS dim_compound_xref_match_rule_check;
ALTER TABLE dwd.dim_compound_xref ADD CONSTRAINT dim_compound_xref_match_rule_check
    CHECK (match_rule = ANY (ARRAY['inchikey_exact', 'inchikey_skeleton', 'inchikey_full',
                                   'cas', 'unii', 'name_fuzzy', 'manual', 'crossref']));

-- ---------------------------------------------------------------------------
-- 5. 重建 ods.v_ingest_summary（追加三张新表）
-- ---------------------------------------------------------------------------
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
SELECT 'ods.internal_excipient_spec', batch_id, count(*), max(ingested_at) FROM ods.internal_excipient_spec GROUP BY batch_id
UNION ALL
SELECT 'ods.chebi_entity', batch_id, count(*), max(ingested_at) FROM ods.chebi_entity GROUP BY batch_id
UNION ALL
SELECT 'ods.lipidmaps_compound', batch_id, count(*), max(ingested_at) FROM ods.lipidmaps_compound GROUP BY batch_id
UNION ALL
SELECT 'ods.kegg_compound', batch_id, count(*), max(ingested_at) FROM ods.kegg_compound GROUP BY batch_id;

COMMIT;
