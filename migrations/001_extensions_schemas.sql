-- ============================================================================
-- 001_extensions_schemas.sql
-- AIDD 活性分子筛选平台 —— 基础对象：扩展、Schema、通用函数、迁移登记表
-- 目标库：PostgreSQL 16+
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. 分层 Schema
--    ods : 贴源层，结构与源系统一致，只追加审计列与原始报文
--    dwd : 标准层，唯一键去重、标准化后的分子主数据与事实
--    ads : 应用层，五级筛选流水线的候选池、评分、追溯
--    ref : 参考字典层，受控词表 / 阈值 / 模型注册
--    meta: 治理层，批次、作业、质量、血缘
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS ods;
CREATE SCHEMA IF NOT EXISTS dwd;
CREATE SCHEMA IF NOT EXISTS ads;
CREATE SCHEMA IF NOT EXISTS ref;
CREATE SCHEMA IF NOT EXISTS meta;

COMMENT ON SCHEMA ods  IS 'ODS 贴源层：与源库结构一致，仅追加 batch_id / ingested_at / raw_payload 等审计列，不做业务加工，可整批重放';
COMMENT ON SCHEMA dwd  IS 'DWD 标准层：以 InChIKey 为唯一键的分子主数据，以及标准化后的事实表（活性、性质、配伍）';
COMMENT ON SCHEMA ads  IS 'ADS 应用层：五级筛选（AI初筛→理化功能→生物安全配伍→建模分析→放大评估）的候选池、评分与决策追溯';
COMMENT ON SCHEMA ref  IS 'REF 参考层：受控词表、物性字典、辅料功能分类、法规限值、AI 模型注册表';
COMMENT ON SCHEMA meta IS 'META 治理层：抓取批次、ETL 作业、数据质量规则与结果、全链路血缘';

-- ---------------------------------------------------------------------------
-- 2. 扩展
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- 名称模糊检索（原料名/别名纠错）
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()

DO $$
BEGIN
  -- RDKit cartridge：分子指纹 / 子结构 / 相似度检索。官方 Windows 包未自带则跳过。
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'rdkit') THEN
    EXECUTE 'CREATE EXTENSION IF NOT EXISTS rdkit';
    RAISE NOTICE 'rdkit extension enabled';
  ELSE
    RAISE NOTICE 'rdkit extension not available, skipped (InChIKey 唯一键与结构文本仍然有效)';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3. 迁移登记表
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS meta.schema_migration (
    version       text        PRIMARY KEY,
    filename      text        NOT NULL,
    checksum      text        NOT NULL,
    applied_at    timestamptz NOT NULL DEFAULT now(),
    applied_by    text        NOT NULL DEFAULT current_user,
    execution_ms  integer,
    note          text
);
COMMENT ON TABLE meta.schema_migration IS '数据库迁移登记表：记录每个迁移脚本的版本号、文件校验和与执行耗时，保证环境可复现';

-- ---------------------------------------------------------------------------
-- 4. 通用函数
-- ---------------------------------------------------------------------------

-- 4.1 自动维护 updated_at
CREATE OR REPLACE FUNCTION meta.fn_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;
COMMENT ON FUNCTION meta.fn_touch_updated_at() IS '触发器函数：写入时自动刷新 updated_at';

-- 4.2 计算行哈希，用于增量比对与幂等重放
CREATE OR REPLACE FUNCTION meta.fn_row_hash(v jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT encode(digest(v::text, 'sha256'), 'hex');
$$;
COMMENT ON FUNCTION meta.fn_row_hash(jsonb) IS '对 JSONB 内容取 sha256，用于判断源记录是否发生变化';

-- 4.3 视图便捷函数：判断某表是否为分区表（供运维脚本使用）
CREATE OR REPLACE FUNCTION meta.fn_table_rows(p_table regclass)
RETURNS bigint
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_rows bigint;
BEGIN
    EXECUTE format('SELECT count(*) FROM %s', p_table) INTO v_rows;
    RETURN v_rows;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;
COMMENT ON FUNCTION meta.fn_table_rows(regclass) IS '运维辅助：安全返回表的当前行数（表不存在时返回 NULL）';

COMMIT;
