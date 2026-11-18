#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh —— 一键拉起本地 PostgreSQL 实例并建库建表
#
# 用法：
#   ./bootstrap.sh              # 初始化（首次）/ 启动 / 建库 / 迁移
#   ./bootstrap.sh --migrate    # 只跑迁移
#   ./bootstrap.sh --status     # 查看实例状态
#   ./bootstrap.sh --stop       # 停止实例
#   ./bootstrap.sh --with-roles # 同时创建 aidd_etl / aidd_app / aidd_bi 角色
#   ./bootstrap.sh --reset      # 危险：删库重建
#
# 可用环境变量：
#   PG_BIN      PostgreSQL bin 目录（默认自动探测）
#   PGDATA      数据目录（默认 ~/.workbuddy/pgdata/<db>，不放进代码仓库）
#   PGPORT      端口（默认 55432）
#   PGDATABASE  库名（默认 aidd）
#   PGUSER      超级用户（默认 postgres）
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MIG_DIR="${DB_DIR}/migrations"
LOG_DIR="${DB_DIR}/reports"
BOOT_LOG="${LOG_DIR}/bootstrap.log"

export PGPORT="${PGPORT:-55432}"
export PGDATABASE="${PGDATABASE:-aidd}"
export PGUSER="${PGUSER:-postgres}"
export PGDATA="${PGDATA:-${HOME}/.workbuddy/pgdata/${PGDATABASE}}"
export PGCLIENTENCODING=UTF8
export PGHOST="${PGHOST:-127.0.0.1}"

WITH_ROLES=0
ACTION="up"

for arg in "$@"; do
  case "$arg" in
    --migrate)    ACTION="migrate" ;;
    --status)     ACTION="status" ;;
    --stop)       ACTION="stop" ;;
    --reset)      ACTION="reset" ;;
    --with-roles) WITH_ROLES=1 ;;
    -h|--help)    sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "${LOG_DIR}"

# 原生 Windows 可执行文件不认 MSYS 的 /c/... 路径，统一转成 C:/... 形式
winpath() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# ---------------------------------------------------------------------------
# 定位 PostgreSQL 可执行文件
# ---------------------------------------------------------------------------
have_exe() { [[ -x "$1" || -x "$1.exe" ]]; }

detect_pg_bin() {
  local cand="${PG_BIN:-}"
  if [[ -n "${cand}" ]] && have_exe "${cand}/pg_ctl"; then echo "${cand}"; return; fi
  for d in \
      "${HOME}/.workbuddy/binaries/postgresql/pgsql/bin" \
      "/c/Program Files/PostgreSQL/17/bin" \
      "/c/Program Files/PostgreSQL/16/bin" \
      "/usr/lib/postgresql/16/bin" \
      "/opt/homebrew/opt/postgresql@16/bin" \
      "/usr/local/opt/postgresql@16/bin"; do
    if have_exe "${d}/pg_ctl"; then echo "$d"; return; fi
  done
  if command -v pg_ctl >/dev/null 2>&1; then dirname "$(command -v pg_ctl)"; return; fi
  echo ""
}

find_exe() {  # $1 = 目录  $2 = 程序名
  if [[ -x "$1/$2" ]]; then echo "$1/$2"
  elif [[ -x "$1/$2.exe" ]]; then echo "$1/$2.exe"
  else echo ""; fi
}

PG_BIN="$(detect_pg_bin)"
[[ -n "${PG_BIN}" ]] || { echo "✗ 未找到 PostgreSQL，请设置 PG_BIN" >&2; exit 1; }

PG_CTL="$(find_exe "${PG_BIN}" pg_ctl)"
INITDB="$(find_exe "${PG_BIN}" initdb)"
PSQL="$(find_exe "${PG_BIN}" psql)"
[[ -n "${PG_CTL}" && -n "${INITDB}" && -n "${PSQL}" ]] || { echo "✗ PostgreSQL 二进制不完整" >&2; exit 1; }

log()  { printf '%s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }

server_running() { "${PG_CTL}" -D "$(winpath "${PGDATA}")" status >/dev/null 2>&1; }

# 关键：启动时把守护进程的标准流全部重定向到文件。
# Windows 下 pg_ctl 拉起的 postgres 会继承调用方的 stdout，若上层是管道（如 | tail），
# 管道写端永不关闭，tail 会一直等待 —— 这是最容易踩的坑。
start_server() {
  if server_running; then ok "实例已在运行 (port ${PGPORT})"; return; fi
  log "→ 启动 PostgreSQL ..."
  ( "${PG_CTL}" -D "$(winpath "${PGDATA}")" -l "$(winpath "${BOOT_LOG}")" \
      -o "-p ${PGPORT} -c listen_addresses=127.0.0.1" -w start ) </dev/null >>"${BOOT_LOG}" 2>&1 || true
  server_running || die "启动失败，详见 ${BOOT_LOG}"
  ok "已启动，端口 ${PGPORT}"
}

init_cluster() {
  if [[ -f "${PGDATA}/PG_VERSION" ]]; then ok "数据目录已初始化"; return; fi
  log "→ 初始化数据目录 ${PGDATA} ..."
  mkdir -p "${PGDATA}"
  "${INITDB}" -D "$(winpath "${PGDATA}")" -U "${PGUSER}" --encoding=UTF8 --locale=C \
      --auth-local=trust --auth-host=trust </dev/null >>"${BOOT_LOG}" 2>&1 \
      || die "initdb 失败，详见 ${BOOT_LOG}"
  ok "初始化完成"
}

ensure_database() {
  local exists
  exists="$("${PSQL}" -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d postgres -tAc \
      "SELECT 1 FROM pg_database WHERE datname='${PGDATABASE}'" 2>/dev/null || true)"
  if [[ "${exists}" == "1" ]]; then
    ok "数据库 ${PGDATABASE} 已存在"; return
  fi
  log "→ 创建数据库 ${PGDATABASE} ..."
  "${PSQL}" -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d postgres -v ON_ERROR_STOP=1 \
      -c "CREATE DATABASE ${PGDATABASE} ENCODING 'UTF8' TEMPLATE template0" >/dev/null
  ok "数据库已创建"
}

# ---------------------------------------------------------------------------
# 迁移执行器：按文件名顺序执行，用 meta.schema_migration 记录校验和
# ---------------------------------------------------------------------------
run_migrations() {
  log "→ 执行迁移（checksum 校验）..."
  shopt -s nullglob
  local files=("${MIG_DIR}"/*.sql)
  [[ ${#files[@]} -gt 0 ]] || die "未找到迁移脚本：${MIG_DIR}"

  local file fname version checksum recorded t0 t1 ms tmplog rc
  for file in "${files[@]}"; do
    fname="$(basename "$file")"
    version="${fname}"
    checksum="$(sha256sum "$file" | awk '{print $1}')"
    tmplog="${LOG_DIR}/.mig.log"

    if [[ "$fname" == 009_* && ${WITH_ROLES} -ne 1 ]]; then
      warn "跳过 ${fname}（加 --with-roles 启用）"; continue
    fi

    recorded="$("${PSQL}" -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
        -tAq -c "SELECT checksum FROM meta.schema_migration WHERE version='${version}'" 2>/dev/null || true)"

    if [[ "${recorded}" == "${checksum}" ]]; then ok "${fname} 已应用，跳过"; continue; fi
    if [[ -n "${recorded}" && "${recorded}" != "${checksum}" ]]; then
      die "${fname} 校验和不一致：脚本被改过但没新增迁移版本。请新建迁移文件或手工处理。"
    fi

    t0=$(date +%s%N)
    set +e
    "${PSQL}" -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
        -v ON_ERROR_STOP=1 -q -f "$(winpath "$file")" >"${tmplog}" 2>&1
    rc=$?
    set -e
    if [[ ${rc} -ne 0 ]]; then
      echo "----- ${fname} 执行失败 -----"; cat "${tmplog}"; rm -f "${tmplog}"
      die "迁移中断"
    fi
    t1=$(date +%s%N); ms=$(( (t1 - t0) / 1000000 ))
    grep -i "notice" "${tmplog}" | sed 's/^/    /' || true
    rm -f "${tmplog}"

    "${PSQL}" -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 -q -c \
      "INSERT INTO meta.schema_migration (version, filename, checksum, execution_ms)
       VALUES ('${version}', '${fname}', '${checksum}', ${ms})
       ON CONFLICT (version) DO UPDATE SET checksum = EXCLUDED.checksum,
           applied_at = now(), execution_ms = EXCLUDED.execution_ms" >/dev/null
    ok "${fname}  (${ms} ms)"
  done
  shopt -u nullglob
}

# ---------------------------------------------------------------------------
case "${ACTION}" in
  status)
    if server_running; then
      log "运行中  ${PGHOST}:${PGPORT}  db=${PGDATABASE}  user=${PGUSER}"
      "${PSQL}" -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -tAc "SELECT version()"
    else
      log "未运行  PGDATA=${PGDATA}"; exit 1
    fi
    exit 0 ;;
  stop)
    if server_running; then
      ( "${PG_CTL}" -D "$(winpath "${PGDATA}")" -m fast -w stop ) </dev/null >>"${BOOT_LOG}" 2>&1
      ok "已停止"
    else warn "实例未运行"; fi
    exit 0 ;;
  reset)
    log "!! 危险操作：删除数据目录 ${PGDATA}"
    if server_running; then
      ( "${PG_CTL}" -D "$(winpath "${PGDATA}")" -m fast -w stop ) </dev/null >>"${BOOT_LOG}" 2>&1
    fi
    rm -rf "${PGDATA}"
    ok "已删除，开始重建"; ACTION="up" ;;
esac

log "=== AIDD 数据库引导 ==="
log "PG_BIN = ${PG_BIN}"
log "PGDATA = ${PGDATA}"
init_cluster
start_server

if [[ "${ACTION}" == "up" ]]; then
  ensure_database
fi
run_migrations

log ""
log "=== 完成 ==="
log "连接串: postgresql://${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}"
log "健康检查: python ${DB_DIR}/scripts/healthcheck.py"
