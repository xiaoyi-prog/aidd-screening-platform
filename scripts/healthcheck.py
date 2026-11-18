#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
healthcheck.py —— AIDD 数据库巡检

做的事情：
  1. 打印实例/库/扩展基本信息
  2. 统计各 schema 的对象清单（表、视图、物化视图、外键、索引、分区）
  3. 逐条执行 meta.data_quality_rule 的规则，把结果写回 meta.data_quality_result
  4. 输出 Markdown 报告到 db/reports/db_health.md

用法：
    python db/scripts/healthcheck.py
环境变量：
    PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD
"""
from __future__ import annotations

import os
import sys
from datetime import datetime
from pathlib import Path

import psycopg
from psycopg.types.json import Jsonb

DB_DIR = Path(__file__).resolve().parent.parent
REPORT = DB_DIR / "reports" / "db_health.md"


def conninfo() -> str:
    return (
        f"host={os.getenv('PGHOST', '127.0.0.1')} "
        f"port={os.getenv('PGPORT', '55432')} "
        f"dbname={os.getenv('PGDATABASE', 'aidd')} "
        f"user={os.getenv('PGUSER', 'postgres')} "
        f"password={os.getenv('PGPASSWORD', '')}"
    )


def q(cur, sql, params=None):
    cur.execute(sql, params)
    return cur.fetchall()


def main() -> int:
    lines: list[str] = []
    add = lines.append

    with psycopg.connect(conninfo(), autocommit=True) as conn:
        with conn.cursor() as cur:
            server_ver = q(cur, "SELECT version()")[0][0]
            db_size = q(cur, "SELECT pg_size_pretty(pg_database_size(current_database()))")[0][0]
            encoding = q(cur, "SHOW server_encoding")[0][0]

            add("# AIDD 数据库健康检查报告")
            add("")
            add(f"- 生成时间：{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
            add(f"- 数据库：`{os.getenv('PGDATABASE', 'aidd')}` @ "
                f"{os.getenv('PGHOST', '127.0.0.1')}:{os.getenv('PGPORT', '55432')}")
            add(f"- 服务器版本：{server_ver.split(',')[0]}")
            add(f"- 服务端编码：{encoding}　库大小：{db_size}")
            add("")

            # ---------------- 扩展 ----------------
            add("## 1. 已安装扩展")
            add("")
            add("| 扩展 | 版本 | 说明 |")
            add("|---|---|---|")
            for name, ver, comment in q(cur, """
                SELECT e.extname, e.extversion, coalesce(obj_description(e.oid, 'pg_extension'), '')
                  FROM pg_extension e ORDER BY e.extname
            """):
                add(f"| {name} | {ver} | {comment or '-'} |")
            add("")

            # ---------------- 对象清单 ----------------
            add("## 2. 对象清单")
            add("")
            add("| Schema | 普通表 | 分区表 | 视图 | 物化视图 | 独立索引 | 外键 |")
            add("|---|---:|---:|---:|---:|---:|---:|")
            rows = q(cur, """
                WITH objs AS (
                    SELECT n.nspname AS sch, c.relname, c.relkind
                      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                     WHERE n.nspname IN ('ods','dwd','ads','ref','meta')
                       AND c.relkind IN ('r','p','v','m')
                )
                SELECT sch,
                       count(*) FILTER (WHERE relkind = 'r')                            AS tables,
                       count(*) FILTER (WHERE relkind = 'p')                            AS parts,
                       count(*) FILTER (WHERE relkind = 'v')                            AS views,
                       count(*) FILTER (WHERE relkind = 'm')                            AS matviews,
                       (SELECT count(*) FROM pg_index i
                          JOIN pg_class ic ON ic.oid = i.indexrelid
                          JOIN pg_namespace ni ON ni.oid = ic.relnamespace
                         WHERE ni.nspname = objs.sch
                           AND NOT EXISTS (SELECT 1 FROM pg_constraint pc WHERE pc.conindid = i.indexrelid)) AS indexes,
                       (SELECT count(*) FROM pg_constraint pc
                          JOIN pg_class cc ON cc.oid = pc.conrelid
                          JOIN pg_namespace nc ON nc.oid = cc.relnamespace
                         WHERE nc.nspname = objs.sch AND pc.contype = 'f')               AS fkeys
                  FROM objs
                 GROUP BY sch ORDER BY sch
            """)
            total = [0] * 6
            for r in rows:
                add("| {} | {} | {} | {} | {} | {} | {} |".format(*r))
                for i, v in enumerate(r[1:]):
                    total[i] += v
            add("| **合计** | {} | {} | {} | {} | {} | {} |".format(*total))
            add("")

            # ---------------- 表级明细 ----------------
            add("## 3. 表级明细（行数 / 大小 / 注释）")
            add("")
            add("| 表 | 行数(估算) | 大小 | 注释 |")
            add("|---|---:|---:|---|")
            for sch, tbl, relkind, comment in q(cur, """
                SELECT n.nspname, c.relname, c.relkind::text,
                       coalesce(obj_description(c.oid, 'pg_class'), '')
                  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname IN ('ods','dwd','ads','ref','meta')
                   AND c.relkind IN ('r','p','m')
                 ORDER BY n.nspname, c.relname
            """):
                cnt = q(cur, f'SELECT count(*) FROM "{sch}"."{tbl}"')[0][0]
                size = q(cur, "SELECT pg_size_pretty(pg_total_relation_size(%s::regclass))",
                         (f'"{sch}"."{tbl}"',))[0][0]
                kind = " (物化)" if relkind == "m" else ""
                add(f"| {sch}.{tbl}{kind} | {cnt} | {size} | {comment or '-'} |")
            add("")

            # ---------------- 数据质量门禁 ----------------
            add("## 4. 数据质量门禁")
            add("")
            rules = q(cur, """
                SELECT rule_code, target_table, rule_type, severity, expression, description
                  FROM meta.data_quality_rule WHERE is_active ORDER BY severity, rule_code
            """)
            if not rules:
                add("_未配置质量规则_")
            else:
                add("| 规则 | 对象 | 级别 | 违规数 | 结果 | 说明 |")
                add("|---|---|---|---:|---|---|")
                passed_cnt = 0
                for code, target, rtype, sev, expr, desc in rules:
                    try:
                        viol = q(cur, f"SELECT ({expr.rstrip(';')})::bigint")[0][0]
                        passed = (viol == 0)
                        err = None
                    except Exception as e:  # noqa: BLE001
                        viol, passed, err = -1, False, str(e).splitlines()[0][:120]
                    if passed:
                        passed_cnt += 1
                    cur.execute("""
                        INSERT INTO meta.data_quality_result
                            (rule_code, passed, violation_count, sample_payload)
                        VALUES (%s, %s, %s, %s)
                    """, (code, passed, max(viol, 0),
                          None if err is None else Jsonb({"error": err})))
                    icon = "PASS" if passed else "FAIL"
                    note = desc or f"({rtype})"
                    if err:
                        note += f"；执行错误: {err}"
                    add(f"| {code} | {target} | {sev} | {max(viol, 0)} | {icon} | {note} |")
                add("")
                add(f"**通过 {passed_cnt} / {len(rules)} 条规则**")
            add("")

            # ---------------- 分层数据量 ----------------
            add("## 5. 分层数据量")
            add("")
            try:
                for name, cnt in q(cur, "SELECT object_name, row_cnt FROM meta.v_data_completeness"):
                    add(f"- {name}: **{cnt}**")
            except Exception as e:  # noqa: BLE001
                add(f"_视图不可用: {e}_")
            add("")

            # ---------------- 迁移记录 ----------------
            add("## 6. 迁移记录")
            add("")
            add("| 版本 | 校验和(前12位) | 耗时(ms) | 应用时间 |")
            add("|---|---|---:|---|")
            for ver, cks, ms, at in q(cur, """
                SELECT version, checksum, coalesce(execution_ms, 0), applied_at
                  FROM meta.schema_migration ORDER BY version
            """):
                add(f"| {ver} | `{cks[:12]}` | {ms} | {at:%Y-%m-%d %H:%M:%S} |")
            add("")

            # ---------------- 血缘分区 ----------------
            add("## 7. 血缘分区")
            add("")
            for child, bound in q(cur, """
                SELECT c.relname, pg_get_expr(c.relpartbound, c.oid)
                  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = 'meta' AND c.relname LIKE 'lineage_event\_%'
                 ORDER BY c.relname
            """):
                add(f"- `meta.{child}` → {bound}")
            add("")

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text("\n".join(lines), encoding="utf-8")
    print("\n".join(lines[:60]))
    print(f"\n... 完整报告已写入 {REPORT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
