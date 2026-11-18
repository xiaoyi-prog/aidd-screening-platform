-- ============================================================================
-- 009_roles_grants.sql
-- 最小权限角色划分（可选，失败不影响主线；由 bootstrap --with-roles 触发）
--   aidd_etl : ETL 账号，可写 ODS/DWD
--   aidd_app : 平台应用账号，可写 ADS、读 DWD/REF
--   aidd_bi  : 只读账号，供 BI / Notebook 查询
-- ============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aidd_etl') THEN
        CREATE ROLE aidd_etl LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aidd_app') THEN
        CREATE ROLE aidd_app LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aidd_bi') THEN
        CREATE ROLE aidd_bi LOGIN;
    END IF;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE '无创建角色权限，跳过角色划分（不影响表结构）';
END $$;

DO $$
BEGIN
    -- 通用 usage
    GRANT USAGE ON SCHEMA ods, dwd, ads, ref, meta TO aidd_etl, aidd_app, aidd_bi;

    -- ETL：写 ODS/DWD，读 REF/META
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ods TO aidd_etl;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA dwd TO aidd_etl;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ods, dwd TO aidd_etl;
    GRANT SELECT ON ALL TABLES IN SCHEMA ref TO aidd_etl;
    GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA meta TO aidd_etl;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA meta TO aidd_etl;

    -- APP：写 ADS，读 DWD/REF
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ads TO aidd_app;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ads, meta TO aidd_app;
    GRANT SELECT ON ALL TABLES IN SCHEMA dwd, ref TO aidd_app;
    GRANT SELECT, INSERT ON meta.lineage_event TO aidd_app;

    -- BI：只读
    GRANT SELECT ON ALL TABLES IN SCHEMA dwd, ads, ref, meta TO aidd_bi;

    -- 未来新建表沿用权限
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA ods, dwd GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO aidd_etl';
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA ads GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO aidd_app';
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA dwd, ads, ref, meta GRANT SELECT ON TABLES TO aidd_bi';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE '授权跳过：当前账号权限不足';
END $$;
