#!/bin/bash
# =============================================================================
# feasy_upload.sh - 模组测试镜像自动化上传脚本 (v2.3.1)
# 功能：自动解析镜像名、生成 Release Notes、打包 .zip、上传、追加 CHANGELOG
# 安全机制：禁止覆盖已有文件、限制操作路径、镜像名合法性检查、CHANGELOG 审核门禁
# FTP：自动检测本地挂载或 lftp 连接 ${FTP_HOST:-192.168.0.71}:${FTP_PORT:-20249}
# 持久章节：产线/测试部注意事项位于各版本 ## [Vx.y.z] 之下，每次上传从上一次 CHANGELOG 继承
# =============================================================================

set -euo pipefail

# ===================== 配置区域 =====================
# FTP 服务器配置（使用 lftp 连接）
FTP_HOST="192.168.0.71"
FTP_PORT="20249"
# 用户名包含空格（"system develop.share"），lftp -u 参数整体引号包裹可保留空格
FTP_USER="${FTP_USER:-system develop.share}"
FTP_PASS="${FTP_PASS:-}"  # 优先从环境变量读取，为空则交互式输入
# FTP 本地挂载路径（如果 FTP 已挂载到本地，可绕开 lftp 直接 cp）
FTP_BASE_PATH="/srv/ftp/firmware"
# 脚本可操作的路径前缀（安全限制）
ALLOWED_PATH_PREFIX="10_系统开发版本"
# SDK 根目录（脚本所在目录的上一级，用于访问 git 和存放临时文件）
SDK_ROOT_DIR="$(cd "$(dirname "$0")" && pwd 2>/dev/null || echo ".")"
# CHANGELOG 文件名
CHANGELOG_FILE="CHANGELOG.md"
# 临时 CHANGELOG 文件名（位于 SDK 根目录）
CHANGELOG_TEMP="CHANGELOG_TEMP.md"
# 持久章节：位于各版本 ## [Vx.y.z] 之下，每次上传从上一次全局 CHANGELOG 继承，无需重复填写
PERSISTENT_SECTION_1="产线自动化测试注意事项说明"
PERSISTENT_SECTION_2="测试部使用镜像注意事项说明"
# 审核标记
CHECKED_MARKER="CHECKED: yes"
UNCHECKED_MARKER="CHECKED: no"
# 日志文件（基于 SDK 根目录，避免 CWD 变化导致路径失效）
LOG_FILE="${SDK_ROOT_DIR}/feasy_upload.log"
# 上一次全局 CHANGELOG 本地缓存（模板生成与打包共用）
PREVIOUS_CHANGELOG_CACHE="${SDK_ROOT_DIR}/.feasy_prev_changelog.md"

# ===================== 全局变量 =====================
DRY_RUN=false
FORCE=false
VERBOSE=false
SKIP_CHANGELOG=false
YES=false
LOCAL_MODE=false
LOCAL_TARGET_DIR=""
RELEASE_NOTES_PATH=""
IMG_NAME=""
IMG_SOURCE_DIR=""
TEMP_DIR=""
ZIP_FILE=""
# FTP 连接模式（自动判定：true=lftp, false=本地挂载）
FTP_USE_LFTP=false
# 仅在实际上传成功后由 cleanup 删除 CHANGELOG_TEMP.md。
# 不能用 exit 0 判断：-h、用户取消路径确认、版本冲突取消都是 0，否则会误删已填写的发行说明。
UPLOAD_SUCCEEDED=false
# 是否已成功拉取到上一次全局 CHANGELOG
HAS_PREVIOUS_CHANGELOG=false

# ===================== 颜色输出 =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ===================== 日志函数 =====================
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" >> "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "$LOG_FILE"
}

log_debug() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1" >> "$LOG_FILE"
}

log_step() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    echo ""
}

# ===================== 使用说明 =====================
usage() {
    cat << USAGE_EOF
用法: $0 [选项] <镜像文件>

选项:
    -h, --help                  显示此帮助信息
    -d, --dry-run               仅模拟运行，不实际执行
    -f, --force                 强制覆盖已有文件（谨慎使用）
    -v, --verbose               详细输出模式
    -l, --local <目录>          本地模式：上传到指定本地目录（不传FTP，用于测试）
    -n, --note <文件>           指定 CHANGELOG.md 文件路径（跳过自动生成）
    -s, --skip-changelog        跳过 CHANGELOG 审核流程（CI 自动化使用）
    -y, --yes                   跳过所有交互确认（版本冲突检查、CHANGELOG 审核等）

示例:
    FTP_PASS=your_passwd $0 RK3568_A11_ATBM6165_BW8205_V1.0.0_Release_20260625_ab012388e4.img
    $0 -d RK356X_A11_ATBM6165_BW8205_V1.0.0_Debug_20260625.1343.img
    $0 -n /path/to/CHANGELOG.md RK3568_A11_ATBM6165_BW8205_V1.0.0_Release_20260625_ab012388e4.img
    $0 -l /tmp/test_upload RK3568_A11_ATBM6165_BW8205_V1.0.0_Debug_20260625.1343.img
    $0 -y RK3568_A11_ATBM6165_BW8205_V1.0.0_Debug_20260625.1343.img

FTP 服务器:
    ${FTP_HOST}:${FTP_PORT} (用户: "${FTP_USER}", lftp)
    (当路径 ${FTP_BASE_PATH} 不存在时自动使用 lftp，使用lftp时需要提供密码，可以通过设置环境变量FTP_PASS指定，否则用本地挂载)

工作流程:
    1. 镜像名解析与校验              4. 审核发行说明 (CHECKED: yes)
    2. 路径安全检查                  5. 打包 .zip (内含镜像 + CHANGELOG.md)
    3. 基于 git 提交自动生成 CHANGELOG  6. lftp/cp 上传到 FTP、更新全局 CHANGELOG

CHANGELOG 持久章节（位于 ## [版本] 之下，自动继承上一次内容）:
    ### ${PERSISTENT_SECTION_1}
    ### ${PERSISTENT_SECTION_2}

镜像命名规范:
    Debug:   [主控_芯片组]_[系统平台]_[模组芯片]_[模组型号]_[版本号]_Debug_[年月日].[时分].img
    Release: [主控_芯片组]_[系统平台]_[模组芯片]_[模组型号]_[版本号]_Release_[年月日]_[Git哈希].img

上传路径规则:
    /${ALLOWED_PATH_PREFIX}/[主控_芯片组]_[系统平台]/[模组芯片]_Series/[模组型号]/[Debug|Release]/[版本号]_[日期]/
USAGE_EOF
    exit 0
}

# ===================== 参数解析 =====================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -l|--local)
                if [[ -z "$2" || "$2" =~ ^- ]]; then
                    log_error "选项 $1 需要一个参数"
                    exit 1
                fi
                LOCAL_MODE=true
                LOCAL_TARGET_DIR="$(cd "$2" 2>/dev/null && pwd || echo "$2")"
                shift 2
                ;;
            -s|--skip-changelog)
                SKIP_CHANGELOG=true
                shift
                ;;
            -y|--yes)
                YES=true
                shift
                ;;
            -n|--note)
                if [[ -z "$2" || "$2" =~ ^- ]]; then
                    log_error "选项 $1 需要一个参数"
                    exit 1
                fi
                RELEASE_NOTES_PATH="$2"
                shift 2
                ;;
            -*)
                log_error "未知选项: $1"
                usage
                exit 1
                ;;
            *)
                if [[ -z "$IMG_NAME" ]]; then
                    IMG_NAME="$1"
                else
                    log_error "多余参数: $1"
                    usage
                    exit 1
                fi
                shift
                ;;
        esac
    done
}

# ===================== 前置检查 =====================
pre_checks() {
    log_step "前置检查"

    # 1. 检查镜像文件参数
    if [[ -z "$IMG_NAME" ]]; then
        log_error "未指定镜像文件"
        usage
        exit 1
    fi

    if [[ ! -f "$IMG_NAME" ]]; then
        log_error "镜像文件不存在: $IMG_NAME"
        exit 1
    fi

    if [[ ! "$IMG_NAME" =~ \.img$ ]]; then
        log_error "文件不是有效的 .img 格式: $IMG_NAME"
        exit 1
    fi

    # 2. 检查 FTP 连接（仅非本地模式）
    if [[ "$LOCAL_MODE" == false ]]; then
        if [[ -d "$FTP_BASE_PATH" ]]; then
            # FTP 已挂载本地，直接使用文件系统操作
            FTP_USE_LFTP=false
            log_info "FTP 已挂载到本地: ${FTP_BASE_PATH}"
            if [[ ! -w "$FTP_BASE_PATH" ]]; then
                log_error "没有 FTP 基础路径的写入权限: $FTP_BASE_PATH"
                exit 1
            fi
        else
            # FTP 未挂载本地，使用 lftp 远程连接
            if ! command -v lftp &>/dev/null; then
                log_error "FTP 未挂载到本地 ${FTP_BASE_PATH}，且 lftp 未安装"
                log_error "请安装 lftp 或将 FTP 挂载到本地路径"
                log_error "  # apt install lftp    (Debian/Ubuntu)"
                log_error "  # yum install lftp    (CentOS/RHEL)"
                exit 1
            fi
            # 检查 FTP 密码
            if [[ -z "$FTP_PASS" ]]; then
                echo ""
                read -r -s -p "请输入 FTP 密码（${FTP_USER}@${FTP_HOST}:${FTP_PORT}）: " FTP_PASS_INPUT
                echo ""
                if [[ -z "$FTP_PASS_INPUT" ]]; then
                    log_error "FTP 密码不能为空"
                    exit 1
                fi
                FTP_PASS="$FTP_PASS_INPUT"
            fi
            FTP_USE_LFTP=true
            log_info "使用 lftp 连接: \"${FTP_USER}\"@${FTP_HOST}:${FTP_PORT}"
        fi
    else
        # 本地模式：检查目标目录（上级目录存在即可，目标目录随后创建）
        local local_parent
        local_parent=$(dirname "$LOCAL_TARGET_DIR" 2>/dev/null)
        if [[ -n "$local_parent" && ! -d "$local_parent" ]]; then
            log_error "本地目标路径的父目录不存在: $local_parent"
            exit 1
        fi
        log_info "本地模式，跳过 FTP 路径检查"
    fi

    # 3. 如果指定了外部 Release Notes，检查其是否存在
    if [[ -n "$RELEASE_NOTES_PATH" && ! -f "$RELEASE_NOTES_PATH" ]]; then
        log_error "指定的 Release Notes 文件不存在: $RELEASE_NOTES_PATH"
        exit 1
    fi

    # 4. 检查 git 可用性（用于自动生成 CHANGELOG）
    if [[ "$SKIP_CHANGELOG" == false && -z "$RELEASE_NOTES_PATH" ]]; then
        if ! command -v git &>/dev/null; then
            log_error "git 不可用，无法自动生成 CHANGELOG"
            log_error "请使用 -n 指定 CHANGELOG 文件，或使用 -s 跳过审核"
            exit 1
        fi
        if [[ ! -d "${SDK_ROOT_DIR}/.git" ]]; then
            log_warn "SDK 根目录不是 git 仓库，CHANGELOG 模板将不包含提交历史"
            log_warn "路径: ${SDK_ROOT_DIR}"
        fi
    fi

    # 5. 检查必要工具
    local required_tools=("zip")
    if [[ "$SKIP_CHANGELOG" == false && -z "$RELEASE_NOTES_PATH" ]]; then
        required_tools+=("git")
    fi
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            log_error "必要工具未安装: $tool"
            exit 1
        fi
    done

    log_info "前置检查通过"
}

# ===================== 镜像名解析 =====================
parse_image_name() {
    local img_name="$1"
    log_debug "解析镜像名: $img_name"

    local basename_img
    basename_img=$(basename "$img_name")
    local name_without_ext="${basename_img%.img}"

    # 合法性检查：下划线分隔字段，包含 Debug/Release，以 .img 结尾
    # 注意：模组型号可以是单字段（BW8205）或双字段（BW8205_V2），使用动态方式定位
    if ! echo "$basename_img" | grep -qE '^[^_]+_[^_]+_[^_]+_.*_(Debug|Release)_.+\.img$'; then
        log_error "镜像名格式不正确！当前为：${basename_img}"
        log_error "正确格式: [主控_芯片组]_[系统平台]_[模组芯片]_[模组型号]_[版本号]_Debug/Release_[日期].img"
        log_error "注意: 模组型号支持单字段（BW8205）或下划线分隔双字段（BW8205_V2）"
        return 1
    fi

    # ===== 动态字段解析 =====
    # 将镜像名按 _ 拆分为数组，通过定位版本号（V*.*.*）和类型（Debug/Release）
    # 来确定模组型号的范围（字段索引 3 到 version_idx-1）
    IFS='_' read -ra FIELDS <<< "$name_without_ext"
    local field_count=${#FIELDS[@]}

    # 最少需要 7 个字段: SoC + OS + Chipset + Model(≥1) + Version + Type + DateTime(≥1)
    if [[ $field_count -lt 7 ]]; then
        log_error "镜像名字段数不足 (${field_count})，无法解析"
        log_error "正确格式: [主控_芯片组]_[系统平台]_[模组芯片]_[模组型号]_[版本号]_Debug/Release_[日期].img"
        return 1
    fi

    # 前 3 个字段位置固定：主控芯片、系统平台、模组芯片
    SOC_PLATFORM="${FIELDS[0]}"
    OS_VER="${FIELDS[1]}"
    CHIPSET="${FIELDS[2]}"

    # 从第 4 个字段开始扫描，查找版本号和类型字段
    local version_idx=-1
    local type_idx=-1
    local i
    for ((i=3; i<field_count; i++)); do
        local f="${FIELDS[$i]}"
        # 版本号格式: V 开头 + 数字.数字.数字（如 V1.0.0）
        if [[ "$f" =~ ^V[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            version_idx=$i
        fi
        # 类型字段: Debug 或 Release
        if [[ "$f" == "Debug" || "$f" == "Release" ]]; then
            type_idx=$i
        fi
    done

    # 校验版本号
    if [[ $version_idx -eq -1 ]]; then
        log_error "镜像名中未找到版本号字段（格式如 V1.0.0）"
        return 1
    fi

    # 校验类型字段
    if [[ $type_idx -eq -1 ]]; then
        log_error "镜像名中未找到版本类型字段（Debug/Release）"
        return 1
    fi

    # 类型必须在版本号之后且紧邻
    if [[ $type_idx -ne $((version_idx + 1)) ]]; then
        log_error "版本号和类型字段顺序不正确"
        return 1
    fi

    # 模组型号 = 字段索引 3 到 (version_idx - 1) 之间所有字段用 _ 拼接
    local module_parts=()
    for ((i=3; i<version_idx; i++)); do
        module_parts+=("${FIELDS[$i]}")
    done
    if [[ ${#module_parts[@]} -eq 0 ]]; then
        log_error "模组型号字段为空，镜像名格式不正确"
        return 1
    fi
    MODULE_MODEL=$(IFS='_'; echo "${module_parts[*]}")

    VERSION="${FIELDS[$version_idx]}"
    BUILD_TYPE="${FIELDS[$type_idx]}"

    if [[ "$BUILD_TYPE" != "Debug" && "$BUILD_TYPE" != "Release" ]]; then
        log_error "版本类型不合法: ${BUILD_TYPE} (应为 Debug 或 Release)"
        return 1
    fi

    if [[ "$BUILD_TYPE" == "Debug" ]]; then
        # Debug: ..._Debug_[年月日.时分].img — 日期时间在最后一个字段
        local last_idx=$((field_count - 1))
        local date_time_field="${FIELDS[$last_idx]}"
        DATE_TIME="${date_time_field//./_}"
        DATE=$(echo "$DATE_TIME" | cut -d'_' -f1)
        TIME=$(echo "$DATE_TIME" | cut -d'_' -f2)
        FOLDER_DATE="${DATE}_${TIME}"
    else
        # Release: ..._Release_[年月日]_[Git哈希].img — 日期和哈希分开
        local date_idx=$((type_idx + 1))
        local hash_idx=$((type_idx + 2))
        DATE="${FIELDS[$date_idx]}"
        GIT_HASH="${FIELDS[$hash_idx]}"
        FOLDER_DATE="${DATE}_${GIT_HASH}"
    fi

    if ! echo "$DATE" | grep -qE '^[0-9]{8}$'; then
        log_error "日期格式不正确: ${DATE} (应为 YYYYMMDD)"
        return 1
    fi

    # 转为 YYYY-MM-DD 格式供 CHANGELOG 使用
    DATE_FORMATTED="${DATE:0:4}-${DATE:4:2}-${DATE:6:2}"

    # 计算编译时间（Build Time），精确到分钟
    if [[ "$BUILD_TYPE" == "Debug" && -n "${TIME:-}" ]]; then
        # Debug: 从文件名解析精确时间 YYYYMMDD.HHMM
        BUILD_TIME="${DATE_FORMATTED} ${TIME:0:2}:${TIME:2:2}"
    else
        # Release: 文件名无精确时间，取镜像文件 mtime
        BUILD_TIME=$(date -d "@$(stat -c '%Y' "$img_name" 2>/dev/null)" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "${DATE_FORMATTED}")
    fi

    log_debug "解析结果: SOC=${SOC_PLATFORM} OS=${OS_VER} CHIPSET=${CHIPSET} MODULE=${MODULE_MODEL} VER=${VERSION} TYPE=${BUILD_TYPE} DATE=${DATE} BUILD_TIME=${BUILD_TIME}"
    return 0
}

# ===================== 目标路径生成 =====================
generate_target_path() {
    if [[ "$LOCAL_MODE" == true ]]; then
        # 本地模式：以用户指定的目录为根，保持相同的子目录结构
        echo "${LOCAL_TARGET_DIR}/${SOC_PLATFORM}_${OS_VER}/${CHIPSET}_Series/${MODULE_MODEL}/${BUILD_TYPE}/${VERSION}_${FOLDER_DATE}/"
    elif [[ "$FTP_USE_LFTP" == true ]]; then
        # lftp 模式：远程路径（相对于 FTP 根目录）
        echo "/${ALLOWED_PATH_PREFIX}/${SOC_PLATFORM}_${OS_VER}/${CHIPSET}_Series/${MODULE_MODEL}/${BUILD_TYPE}/${VERSION}_${FOLDER_DATE}/"
    else
        # 本地挂载模式：从挂载点开始
        echo "${FTP_BASE_PATH}/${ALLOWED_PATH_PREFIX}/${SOC_PLATFORM}_${OS_VER}/${CHIPSET}_Series/${MODULE_MODEL}/${BUILD_TYPE}/${VERSION}_${FOLDER_DATE}/"
    fi
}

# ===================== 目标路径确认 =====================
confirm_target_path() {
    local target_path="$1"

    log_step "目标路径确认"

    echo ""
    echo -e "  目标路径: ${CYAN}${target_path}${NC}"
    echo ""

    # -y 模式自动跳过
    if [[ "$YES" == true ]]; then
        log_info "已指定 -y 选项，跳过目标路径确认"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        log_info "非交互模式，跳过目标路径确认"
        return 0
    fi

    echo -e -n "以上目标路径是否正确？(Y/n): "
    read -r confirm
    if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
        log_error "用户取消操作"
        exit 0
    fi
    log_info "目标路径确认通过"
}

# ===================== 路径安全检查 =====================
check_path_security() {
    local target_path="$1"
    log_debug "执行路径安全检查..."

    # 本地模式：不检查 ALLOWED_PATH_PREFIX，但需做安全过滤
    if [[ "$LOCAL_MODE" == true ]]; then
        log_debug "本地模式，跳过 FTP 路径前缀检查"
    else
        # 1. 检查路径是否在允许范围内（仅 FTP 模式）
        local allowed_prefix
        if [[ "$FTP_USE_LFTP" == true ]]; then
            allowed_prefix="/${ALLOWED_PATH_PREFIX}"
        else
            allowed_prefix="${FTP_BASE_PATH}/${ALLOWED_PATH_PREFIX}"
        fi
        if [[ ! "$target_path" == "${allowed_prefix}"* ]]; then
            log_error "路径不在允许的操作范围内！"
            log_error "允许前缀: ${allowed_prefix}"
            log_error "目标路径: $target_path"
            return 1
        fi
    fi

    # 2. 检查路径遍历攻击
    if echo "$target_path" | grep -qE '\.\.|//|~|\$|`|;|\||&|<|>'; then
        log_error "路径包含非法字符！"
        return 1
    fi

    # 3. 检查路径深度
    local depth
    depth=$(echo "$target_path" | tr '/' '\n' | grep -c '^')
    if [[ $depth -gt 20 ]]; then
        log_error "路径深度超过限制 (20)"
        return 1
    fi

    log_debug "路径安全检查通过"
    return 0
}

# ===================== FTP 远程操作（lftp 模式） =====================
# 以下函数仅在 FTP_USE_LFTP=true 时使用
#
# 用户名包含空格（如 "system develop.share"），使用 -u "${FTP_USER},${FTP_PASS}"
# 整体包裹的单参数形式，双引号内的空格被保留为 -u 参数的一部分。
# lftp 按第一个逗号分隔 user 和 pass，详见：https://lftp.yar.ru/lftp-man.html
#
# 此前曾用 heredoc + set ftp:user/password 方案，但部分环境因用户名空格
# 导致连接失败，故改用 -u 方案。

lftp_exec() {
    local cmd="$1"
    # 用户名包含空格，如 "system develop.share"，-u 整体引号包裹可保留空格。
    # 不使用 2>/dev/null 以便用户能看到 lftp 原始错误信息排障。
    # 设置超时与重试参数，支持大文件上传（~700MB+）。
    lftp -p "${FTP_PORT}" -u "${FTP_USER},${FTP_PASS}" "${FTP_HOST}" <<- EOF
		set net:timeout 60
		set net:max-retries 3
		set net:reconnect-interval-base 10
		set net:reconnect-interval-multiplier 2
		${cmd}
		quit
	EOF
    return $?
}

lftp_remote_file_exists() {
    local remote_path="$1"
    local dir
    dir=$(dirname "$remote_path")
    local file
    file=$(basename "$remote_path")
    # cd 到所在目录后用 ls -l 检查文件是否存在（cls 在此 FTP 服务器上对中文路径有 CWD 问题）
    local result
    result=$(lftp_exec "cd ${dir} && ls -l ${file}" 2>/dev/null) || true
    if echo "$result" | grep -q "^-[^ ]"; then
        return 0
    fi
    return 1
}

lftp_remote_dir_exists() {
    local remote_path="$1"
    # cd 到目录，成功即存在（比 du/ls 更可靠，避免中文路径误判）
    if lftp_exec "cd ${remote_path}" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

lftp_list_remote_dirs() {
    local parent="$1"
    local pattern="$2"
    # 列出远程目录下匹配 pattern 的目录名
    lftp_exec "cls -1 ${parent}/${pattern}" || true
}

lftp_mkdir_remote() {
    local remote_dir="$1"
    local output
    # mkdir -p 在目录已存在时部分 FTP 服务器返回 550（"already exists"），视为成功
    output=$(lftp_exec "mkdir -p ${remote_dir}" 2>&1) || true
    if [[ -n "$output" && "$output" != *"already exists"* ]]; then
        echo "$output" >&2
        return 1
    fi
    return 0
}

lftp_put_remote() {
    local local_file="$1"
    local remote_dir="$2"
    lftp_exec "put -O ${remote_dir} ${local_file}" || return 1
}

lftp_get_remote_file_size() {
    local remote_file="$1"
    local dir
    dir=$(dirname "$remote_file")
    local file
    file=$(basename "$remote_file")
    # cd 到目录后 ls -l 单独文件，解析第 5 字段（字节大小），避免 cls 的 CWD 问题
    lftp_exec "cd ${dir} && ls -l ${file}" 2>/dev/null | awk '/^-/{print $5}' || echo 0
}

# ===================== 文件存在性检查 =====================
check_file_exists() {
    local target_path="$1"
    local filename="$2"
    local target_file="${target_path}${filename}"

    if [[ "$FTP_USE_LFTP" == true ]]; then
        # 远程检查
        if lftp_remote_file_exists "${target_file}"; then
            if [[ "$FORCE" == true ]]; then
                log_warn "远程目标文件已存在，将强制覆盖: ${target_file}"
                return 0
            else
                log_error "远程目标文件已存在，禁止覆盖: ${target_file}"
                log_error "如需强制覆盖，请使用 -f 选项"
                return 1
            fi
        fi
    else
        # 本地检查
        if [[ -f "$target_file" ]]; then
            if [[ "$FORCE" == true ]]; then
                log_warn "目标文件已存在，将强制覆盖: $target_file"
                return 0
            else
                log_error "目标文件已存在，禁止覆盖: $target_file"
                log_error "如需强制覆盖，请使用 -f 选项"
                return 1
            fi
        fi
    fi
    return 0
}

# ===================== 镜像版本冲突检查 =====================
check_version_conflict() {
    local target_path="$1"

    # 仅对 Release 版本做冲突检查，Debug 版本可直接跳过
    if [[ "$BUILD_TYPE" != "Release" ]]; then
        log_info "Debug 版本，跳过镜像版本冲突检查"
        return 0
    fi

    log_step "镜像版本检查"

    # 从 target_path 反推版本目录的父目录（Debug/Release 所在层级）
    local version_parent
    version_parent=$(dirname "${target_path%/*}")

    # 查找同版本前缀的已有目录
    local existing_dirs=""

    if [[ "$FTP_USE_LFTP" == true ]]; then
        # 远程检查：先 cd 到 Release/Debug 目录，再用 cls -d 匹配同版本号的子目录
        existing_dirs=$(lftp_exec "cd ${version_parent} && cls -d ${VERSION}_*") || true
        # cls -d 输出已经是 basename，直接使用
    else
        # 本地检查
        if [[ -d "$version_parent" ]]; then
            existing_dirs=$(find "$version_parent" -maxdepth 1 -type d -name "${VERSION}_*" 2>/dev/null | sort || true)
        fi
    fi

    if [[ -z "$existing_dirs" ]]; then
        log_info "未发现同版本的已有镜像，继续"
        return 0
    fi

    # 发现有同版本目录
    echo ""
    log_warn "检测到 FTP 上已有版本 ${VERSION} 的镜像目录："
    echo ""
    local count=0
    while IFS= read -r dir; do
        # 跳过当前正在上传的目标目录本身
        if [[ "$dir" == "${VERSION}_${FOLDER_DATE}" ]]; then
            continue
        fi
        echo "  ${YELLOW}▶${NC} ${dir}"
        count=$((count + 1))
    done <<< "$existing_dirs"

    if [[ $count -eq 0 ]]; then
        log_info "无冲突（仅当前目标目录存在），继续"
        return 0
    fi

    echo ""
    echo -e "  ${version_parent}/"
    echo ""

    # -y 模式或非交互：自动放行
    if [[ "$YES" == true ]]; then
        log_info "检测到 -y 选项，跳过版本冲突确认"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        log_warn "非交互模式，版本冲突无法确认，请使用 -y 自动跳过或手动确认"
        log_error "中止上传"
        exit 1
    fi

    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  ⚠️  版本 ${VERSION} 已在 FTP 上存在以上镜像                 ${NC}"
    echo -e "${YELLOW}  继续上传将产生同版本下的多个镜像目录                        ${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    read -r -p "是否继续上传？(y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "用户取消上传"
        exit 0
    fi
    log_info "用户确认继续上传"
}

# ===================== 全局 CHANGELOG 路径 =====================
# 全局 CHANGELOG.md 位于版本目录的上一级（Debug/ 或 Release/）
resolve_global_changelog_path() {
    local target_path="$1"
    local global_parent
    global_parent=$(dirname "${target_path%/}")
    echo "${global_parent}/${CHANGELOG_FILE}"
}

# 拉取上一次全局 CHANGELOG 到本地缓存，供模板继承与打包合并共用
fetch_previous_changelog() {
    local target_path="$1"
    local global_changelog_path
    global_changelog_path=$(resolve_global_changelog_path "$target_path")

    HAS_PREVIOUS_CHANGELOG=false
    rm -f "$PREVIOUS_CHANGELOG_CACHE"

    log_step "拉取上一次 CHANGELOG（持久章节继承）"

    if [[ "$FTP_USE_LFTP" == true ]]; then
        local changelog_dir
        changelog_dir=$(dirname "$global_changelog_path")
        local changelog_file
        changelog_file=$(basename "$global_changelog_path")
        if lftp_exec "cd ${changelog_dir} && get ${changelog_file} -o ${PREVIOUS_CHANGELOG_CACHE}" \
            && [[ -s "$PREVIOUS_CHANGELOG_CACHE" ]]; then
            HAS_PREVIOUS_CHANGELOG=true
            log_info "已拉取远程全局 CHANGELOG.md，将继承持久章节"
        else
            rm -f "$PREVIOUS_CHANGELOG_CACHE"
            log_info "远程无全局 CHANGELOG.md（首次发行）"
        fi
    else
        if [[ -f "$global_changelog_path" && -s "$global_changelog_path" ]]; then
            cp "$global_changelog_path" "$PREVIOUS_CHANGELOG_CACHE"
            HAS_PREVIOUS_CHANGELOG=true
            log_info "已读取本地全局 CHANGELOG.md，将继承持久章节"
        else
            log_info "本地无全局 CHANGELOG.md（首次发行）"
        fi
    fi
}

# 提取一节持久注意事项；优先 ###（版本内），兼容旧的顶层 ##；输出统一为 ###
extract_persistent_section() {
    local file="$1"
    local title="$2"
    [[ -f "$file" ]] || return 1
    awk -v title="$title" '
        BEGIN { found = 0; level = "" }
        $0 ~ ("^###[[:space:]]+" title "[[:space:]]*$") {
            found = 1
            level = "###"
            print "### " title
            next
        }
        $0 ~ ("^##[[:space:]]+" title "[[:space:]]*$") {
            found = 1
            level = "##"
            print "### " title
            next
        }
        found && level == "###" && (/^###[[:space:]]/ || /^##[[:space:]]/ || /^---[[:space:]]*$/) { exit }
        found && level == "##" && (/^##[[:space:]]/ || /^---[[:space:]]*$/) { exit }
        found { print }
    ' "$file"
}

# 从文件提取两个持久章节（含 ### 标题）；若某节缺失则跳过该节
extract_persistent_sections() {
    local file="$1"
    local s1="" s2=""
    [[ -f "$file" ]] || return 1
    s1=$(extract_persistent_section "$file" "$PERSISTENT_SECTION_1") || true
    s2=$(extract_persistent_section "$file" "$PERSISTENT_SECTION_2") || true
    if [[ -z "$s1" && -z "$s2" ]]; then
        return 1
    fi
    {
        [[ -n "$s1" ]] && printf '%s\n' "$s1"
        [[ -n "$s1" && -n "$s2" ]] && echo ""
        [[ -n "$s2" ]] && printf '%s\n' "$s2"
    }
    return 0
}

# 持久章节预设条目（开发者将 xx 换成实际说明；未改则审核后变为「无特殊说明」）
PERSISTENT_PRESET_LINE_1="1. 模组上电下电说明：xx"
PERSISTENT_PRESET_LINE_2="2. 驱动加载说明：xx"
PERSISTENT_PRESET_LINE_3="3. WiFI测试说明：xx"
PERSISTENT_PRESET_LINE_4="4. 蓝牙测试说明：xx"

# 单个持久章节的预设正文（不含标题）
persistent_section_preset_body() {
    printf '%s\n' \
        "$PERSISTENT_PRESET_LINE_1" \
        "$PERSISTENT_PRESET_LINE_2" \
        "$PERSISTENT_PRESET_LINE_3" \
        "$PERSISTENT_PRESET_LINE_4"
}

# 带标题的完整持久章节块
format_persistent_section() {
    local title="$1"
    printf '### %s\n\n' "$title"
    persistent_section_preset_body
    printf '\n'
}

# 占位模板（首次发行或旧 CHANGELOG 尚无这两节时使用）
default_persistent_sections() {
    format_persistent_section "$PERSISTENT_SECTION_1"
    format_persistent_section "$PERSISTENT_SECTION_2"
}

# 判断持久章节正文是否「无实际说明」（仅 xx / 无特殊说明 / 空）
persistent_section_is_empty_content() {
    local section="$1"
    local tmp
    tmp=$(mktemp)
    printf '%s\n' "$section" > "$tmp"
    # 去掉标题与空行后，若没有任何「已填写」的预设行/额外正文，则视为空
    if awk '
        /^### / || /^## / { next }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*[0-9]+\.[[:space:]]+(模组上电下电说明|驱动加载说明|WiFI测试说明|蓝牙测试说明)[：:][[:space:]]*xx[[:space:]]*$/ { next }
        /^[[:space:]]*[0-9]+\.[[:space:]]+(模组上电下电说明|驱动加载说明|WiFI测试说明|蓝牙测试说明)[：:][[:space:]]*无特殊说明[[:space:]]*$/ { next }
        /^[[:space:]]*[0-9]+\.[[:space:]]+(模组上电下电说明|驱动加载说明|WiFI测试说明|蓝牙测试说明)[：:][[:space:]]*$/ { next }
        /^[[:space:]]*无特殊说明[[:space:]]*$/ { next }
        /^[[:space:]]*-[[:space:]]*(（请完善）|\(请完善\))[[:space:]]*$/ { next }
        { found = 1; exit }
        END { exit found ? 1 : 0 }
    ' "$tmp"; then
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Added / Changed / Fixed / Known Issues 分类是否无实际内容（- 无 / 请完善占位）
category_section_is_empty_content() {
    local section="$1"
    local tmp
    tmp=$(mktemp)
    printf '%s\n' "$section" > "$tmp"
    if awk '
        /^### / || /^## / { next }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*-[[:space:]]*无[[:space:]]*$/ { next }
        /^[[:space:]]*-.*(新功能描述|功能变更描述|问题修复描述|已知问题描述)[[:space:]]*(（请完善）|\(请完善\))[[:space:]]*$/ { next }
        /^[[:space:]]*-[[:space:]]*(（请完善）|\(请完善\))[[:space:]]*$/ { next }
        { found = 1; exit }
        END { exit found ? 1 : 0 }
    ' "$tmp"; then
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# 分类占位模板（首次或上一次无实质内容时）
default_category_section() {
    local title="$1"
    local placeholder="$2"
    printf '### %s\n\n- %s\n' "$title" "$placeholder"
}

default_category_sections() {
    default_category_section "Added" "${CHIPSET} ${MODULE_MODEL} 新功能描述（请完善）"
    echo ""
    default_category_section "Changed" "功能变更描述（请完善）"
    echo ""
    default_category_section "Fixed" "问题修复描述（请完善）"
    echo ""
    default_category_section "Known Issues" "已知问题描述（请完善）"
}

# 解析 Added/Changed/Fixed/Known Issues：
# 每一节独立回退 当前草稿 → 上一次全局 CHANGELOG → 占位模板
# 上一次若仅为「- 无」/占位，则改回（请完善）预设，便于本次编辑
resolve_category_sections() {
    local preferred_file="${1:-}"
    local titles=("Added" "Changed" "Fixed" "Known Issues")
    local placeholders=(
        "${CHIPSET} ${MODULE_MODEL} 新功能描述（请完善）"
        "功能变更描述（请完善）"
        "问题修复描述（请完善）"
        "已知问题描述（请完善）"
    )
    local out_parts=()
    local i title sec
    local used_placeholder=false
    local inherited_any=false

    for i in "${!titles[@]}"; do
        title="${titles[$i]}"
        sec=""

        if [[ -n "$preferred_file" && -f "$preferred_file" ]]; then
            sec=$(extract_persistent_section "$preferred_file" "$title") || true
        fi
        if [[ -z "$sec" && "$HAS_PREVIOUS_CHANGELOG" == true && -f "$PREVIOUS_CHANGELOG_CACHE" ]]; then
            sec=$(extract_persistent_section "$PREVIOUS_CHANGELOG_CACHE" "$title") || true
            if [[ -n "$sec" ]] && ! category_section_is_empty_content "$sec"; then
                inherited_any=true
            fi
        fi

        if [[ -n "$sec" ]] && category_section_is_empty_content "$sec"; then
            sec=""
        fi

        if [[ -z "$sec" ]]; then
            sec=$(default_category_section "$title" "${placeholders[$i]}")
            used_placeholder=true
        fi
        out_parts+=("$sec")
    done

    if [[ "$inherited_any" == true ]]; then
        log_debug "已从上一次 CHANGELOG 继承 Added/Changed/Fixed/Known Issues 实质内容"
    fi
    if [[ "$used_placeholder" == true ]]; then
        log_debug "部分分类无历史可继承，已写入（请完善）占位"
    fi

    local first=true
    for sec in "${out_parts[@]}"; do
        if [[ "$first" == true ]]; then
            first=false
        else
            printf '\n'
        fi
        printf '%s\n' "$sec"
    done
}

# 解析持久章节：每一节独立回退 当前草稿 → 上一次全局 CHANGELOG → 预设占位
# 输出始终为 ### 标题（挂在 ## [版本] 之下）
# 若继承到的内容全是「无特殊说明」/xx，则改回 xx 预设，便于本次编辑
resolve_persistent_sections() {
    local preferred_file="${1:-}"
    local s1="" s2=""
    local used_placeholder=false

    if [[ -n "$preferred_file" && -f "$preferred_file" ]]; then
        s1=$(extract_persistent_section "$preferred_file" "$PERSISTENT_SECTION_1") || true
        s2=$(extract_persistent_section "$preferred_file" "$PERSISTENT_SECTION_2") || true
    fi

    if [[ -z "$s1" && "$HAS_PREVIOUS_CHANGELOG" == true && -f "$PREVIOUS_CHANGELOG_CACHE" ]]; then
        s1=$(extract_persistent_section "$PREVIOUS_CHANGELOG_CACHE" "$PERSISTENT_SECTION_1") || true
        [[ -n "$s1" ]] && log_debug "已从上一次 CHANGELOG 继承「${PERSISTENT_SECTION_1}」"
    fi
    if [[ -z "$s2" && "$HAS_PREVIOUS_CHANGELOG" == true && -f "$PREVIOUS_CHANGELOG_CACHE" ]]; then
        s2=$(extract_persistent_section "$PREVIOUS_CHANGELOG_CACHE" "$PERSISTENT_SECTION_2") || true
        [[ -n "$s2" ]] && log_debug "已从上一次 CHANGELOG 继承「${PERSISTENT_SECTION_2}」"
    fi

    # 空内容不继承「无特殊说明」三行，改回 xx 预设模板
    if [[ -n "$s1" ]] && persistent_section_is_empty_content "$s1"; then
        s1=""
    fi
    if [[ -n "$s2" ]] && persistent_section_is_empty_content "$s2"; then
        s2=""
    fi

    if [[ -z "$s1" ]]; then
        s1=$(format_persistent_section "$PERSISTENT_SECTION_1")
        used_placeholder=true
    fi
    if [[ -z "$s2" ]]; then
        s2=$(format_persistent_section "$PERSISTENT_SECTION_2")
        used_placeholder=true
    fi

    if [[ "$used_placeholder" == true ]]; then
        log_debug "持久章节无历史可继承，已写入预设（将 xx 换成实际说明）"
    fi

    # 命令替换会吃掉尾部换行，必须显式插入空行分隔两节
    if [[ -n "$s1" && -n "$s2" ]]; then
        printf '%s\n\n%s\n' "$s1" "$s2"
    elif [[ -n "$s1" ]]; then
        printf '%s\n' "$s1"
    elif [[ -n "$s2" ]]; then
        printf '%s\n' "$s2"
    fi
}

# 去掉文档标题与旧版顶层 ## 持久章节；保留各版本内的 ### 持久章节
strip_toplevel_noise() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    awk -v s1="$PERSISTENT_SECTION_1" -v s2="$PERSISTENT_SECTION_2" '
        BEGIN { skip = 0 }
        /^#[[:space:]]/ && !/^##/ { next }
        /^##[[:space:]]/ {
            title = $0
            sub(/^##[[:space:]]+/, "", title)
            sub(/[[:space:]]+$/, "", title)
            if (title == s1 || title == s2) {
                skip = 1
                next
            }
            skip = 0
            print
            next
        }
        skip { next }
        { print }
    ' "$file"
}

# 判断正文是否已包含持久章节（### 或旧 ##）
text_has_persistent_sections() {
    local text="$1"
    local tmp
    tmp=$(mktemp)
    printf '%s\n' "$text" > "$tmp"
    extract_persistent_sections "$tmp" >/dev/null 2>&1
    local rc=$?
    rm -f "$tmp"
    return $rc
}

# 在 ## [版本] 的 Build/Upload 元数据之后插入持久章节
inject_persistent_under_version() {
    local text="$1"
    local persistent="$2"
    local tmp_text tmp_persist out
    tmp_text=$(mktemp)
    tmp_persist=$(mktemp)
    out=$(mktemp)
    printf '%s\n' "$text" > "$tmp_text"
    printf '%s\n' "$persistent" > "$tmp_persist"
    awk -v pfile="$tmp_persist" '
        BEGIN {
            injected = 0
            after_ver = 0
        }
        function dump_persistent(    line) {
            while ((getline line < pfile) > 0) print line
            close(pfile)
        }
        /^##[[:space:]]+\[/ {
            print
            after_ver = 1
            next
        }
        after_ver && /^>/ {
            print
            next
        }
        after_ver && !injected {
            print ""
            dump_persistent()
            injected = 1
            after_ver = 0
            if ($0 ~ /^[[:space:]]*$/) next
            print
            next
        }
        { print }
        END {
            if (!injected) {
                print ""
                dump_persistent()
            }
        }
    ' "$tmp_text" > "$out"
    cat "$out"
    rm -f "$tmp_text" "$tmp_persist" "$out"
}

# 识别 CHECKED: yes（允许空白、大小写、Windows CRLF）
changelog_is_checked() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    tr -d '\r' < "$file" | grep -qiE '^[[:space:]]*CHECKED:[[:space:]]*yes[[:space:]]*$'
}

# 交互或提示用户完成 CHECKED 审核；通过后清理占位符
review_existing_changelog() {
    local temp_file="$1"

    echo "────────────────────────────────────────"
    cat "$temp_file"
    echo "────────────────────────────────────────"

    if changelog_is_checked "$temp_file"; then
        sanitize_changelog_placeholders "$temp_file"
        log_info "✅ 发行说明审核通过，已清理占位符"
        return 0
    fi

    if [[ -t 0 ]]; then
        log_info "按 Enter 键打开编辑器进行编辑，或按 Ctrl+C 取消..."
        read -r
        ${EDITOR:-vi} "$temp_file"

        if changelog_is_checked "$temp_file"; then
            sanitize_changelog_placeholders "$temp_file"
            log_info "✅ 发行说明审核通过，已清理占位符"
            return 0
        fi
        log_error "发行说明仍未审核确认"
        log_error "请编辑 ${temp_file} 将 CHECKED: no 改为 CHECKED: yes 后重新执行"
        exit 1
    fi

    log_error "非交互模式，无法自动打开编辑器审核 CHANGELOG"
    log_error "请使用以下任一方式解决："
    log_error "  1. 添加 -s 选项跳过审核：$0 -s <镜像文件>"
    log_error "  2. 设置环境变量：export FEASY_FORCE_SKIP=1"
    log_error "  3. 外部编辑后重新执行：编辑 ${temp_file} 后重新运行"
    exit 1
}

# ===================== 生成 CHANGELOG 模板 =====================
generate_changelog_template() {
    log_step "生成发行说明模板 (CHANGELOG_TEMP.md)"

    cd "$SDK_ROOT_DIR"

    local temp_file="${SDK_ROOT_DIR}/${CHANGELOG_TEMP}"
    local today_date
    today_date="$DATE_FORMATTED"
    local persistent_block=""

    # 已有草稿一律保留：未勾选 CHECKED 时不得重建，否则会清掉已填写的发行内容
    if [[ -f "$temp_file" ]]; then
        if changelog_is_checked "$temp_file"; then
            sanitize_changelog_placeholders "$temp_file"
            log_info "发现已审核通过的 CHANGELOG_TEMP.md，已清理占位符后使用"
            echo "────────────────────────────────────────"
            cat "$temp_file"
            echo "────────────────────────────────────────"
            return 0
        fi
        log_warn "发现未审核的 CHANGELOG_TEMP.md，保留已有内容（不会覆盖）"
        if ! grep -q "\[${VERSION}\]" "$temp_file" 2>/dev/null; then
            log_warn "草稿中的版本号与当前镜像 ${VERSION} 可能不一致，请在编辑器中确认"
        fi
        # 旧草稿若缺少持久章节，插入到 ## [版本] 元数据之后
        if ! extract_persistent_sections "$temp_file" >/dev/null 2>&1; then
            persistent_block=$(resolve_persistent_sections "")
            local patched body
            body=$(cat "$temp_file")
            patched=$(inject_persistent_under_version "$body" "$persistent_block")
            printf '%s\n' "$patched" > "$temp_file"
            log_info "已为旧草稿在版本标题下补上持久章节（从上一次 CHANGELOG 继承或占位）"
        fi
        review_existing_changelog "$temp_file"
        return 0
    fi

    # 仅新建模板时才解析持久章节与分类（避免无历史时多余刷屏）
    persistent_block=$(resolve_persistent_sections "")
    local category_block
    category_block=$(resolve_category_sections "")

    log_info "基于最近的 git 提交记录生成模板..."

    # 持久章节 + 分类挂在 ## [版本] 之下；单独写入避免 heredoc 展开 $ 等字符
    {
        echo "# Release Notes"
        echo ""
        cat << TEMPLATE_EOF
## [${VERSION}] $(date '+%Y-%m-%d %H:%M')

> **Build:** ${BUILD_TIME:-${DATE_FORMATTED}}
> **Upload:** $(date '+%Y-%m-%d %H:%M')

TEMPLATE_EOF
        printf '%s\n' "$persistent_block"
        echo ""
        printf '%s\n' "$category_block"
        echo ""
        echo "---"
        echo ""
    } > "$temp_file"

    # 追加 Git Commit History（如果可用）
    if git log --oneline -10 &>/dev/null; then
        {
            echo ""
            echo "### Git Commit History"
            echo ""
            git log --oneline -10 --pretty=format:"- %h %s"
            echo ""
        } >> "$temp_file"
    fi

    # 追加审核标记（CHECKED 行前的 > 仅用于提示说明，标记行本身无前缀）
    {
        echo ""
        echo "---"
        echo ""
        echo "> ⚠️ 请开发者人工审核以上 CHANGELOG 内容并完善，确认无误后将下方标记改为 yes"
        echo "> 确认后、上传前将自动删除「（请完善）」；未填写任何内容的分类会自动补上「- 无」"
        echo "> 「${PERSISTENT_SECTION_1}」「${PERSISTENT_SECTION_2}」中请将预设「xx」换成实际说明；全部未填时整节只保留「无特殊说明」"
        echo "> Added/Changed/Fixed/Known Issues 已从上一次 CHANGELOG 继承（若有实质内容）；无内容时为（请完善）占位"
        echo "> 注意事项与变更分类通常只需改有变化的部分"
        echo "${UNCHECKED_MARKER}"
        echo "> 编辑完成后保存文件，重新执行本脚本即可继续。"
    } >> "$temp_file"

    log_info "模板已生成: ${temp_file}"
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  请完善发行说明内容，并将 CHECKED 标记改为 yes 后重试        ║${NC}"
    echo -e "${YELLOW}║  确认后将自动去掉「（请完善）」；空分类会补上「- 无」        ║${NC}"
    echo -e "${YELLOW}║  产线/测试部/变更分类均可继承上一次；只改有变化的部分        ║${NC}"
    echo -e "${YELLOW}║                                                              ║${NC}"
    echo -e "${YELLOW}║  文件: ${temp_file}${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # 检查 FEASY_FORCE_SKIP 环境变量（CI 自动化使用）
    if [[ "${FEASY_FORCE_SKIP:-}" == "1" ]]; then
        log_info "检测到 FEASY_FORCE_SKIP=1，跳过 CHANGELOG 审核流程"
        {
            echo "# Release Notes"
            echo ""
            cat << CHG_EOF
## [${VERSION}] $(date '+%Y-%m-%d %H:%M')

> **Build:** ${BUILD_TIME:-${DATE_FORMATTED}}
> **Upload:** $(date '+%Y-%m-%d %H:%M')

CHG_EOF
            printf '%s\n' "$persistent_block"
            echo ""
            printf '%s\n' "$category_block"
            echo ""
            echo "---"
            echo ""
            echo "${CHECKED_MARKER}"
        } > "${SDK_ROOT_DIR}/${CHANGELOG_TEMP}"
        log_info "自动生成默认 CHANGELOG_TEMP.md"
        return 0
    fi

    # 交互式终端 —— 自动打开编辑器
    if [[ -t 0 ]]; then
        review_existing_changelog "$temp_file"
        return 0
    else
        log_error "非交互模式，无法自动打开编辑器审核 CHANGELOG"
        log_error "请使用以下任一方式解决："
        log_error "  1. 添加 -s 选项跳过审核：$0 -s <镜像文件>"
        log_error "  2. 设置环境变量：export FEASY_FORCE_SKIP=1"
        log_error "  3. 外部编辑后重新执行：编辑 ${temp_file} 后重新运行"
        exit 1
    fi
}

# ===================== CHANGELOG 占位符清理 =====================
# CHECKED: yes 之后、上传之前：
#   - Added/Changed/Fixed/Known Issues：删除「（请完善）」占位行；整节为空时补「- 无」
#   - 产线/测试部持久章节：
#       · 已填写的预设行保留实际内容
#       · 仍为「：xx」或冒号后为空的行不保留
#       · 若三行均未填写，整节只写一行「无特殊说明」
sanitize_changelog_placeholders() {
    local file="$1"
    local tmp

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    tmp=$(mktemp)
    awk '
    function rtrim(s) {
        sub(/[[:space:]]+$/, "", s)
        return s
    }
    function strip_placeholder(s) {
        gsub(/（请完善）/, "", s)
        gsub(/\(请完善\)/, "", s)
        return rtrim(s)
    }
    function is_blank(s) {
        return s ~ /^[[:space:]]*$/
    }
    function is_persistent_heading(s) {
        return (s ~ /^### 产线自动化测试注意事项说明[[:space:]]*$/ ||
                s ~ /^### 测试部使用镜像注意事项说明[[:space:]]*$/ ||
                s ~ /^## 产线自动化测试注意事项说明[[:space:]]*$/ ||
                s ~ /^## 测试部使用镜像注意事项说明[[:space:]]*$/)
    }
    function is_tracked_heading(s) {
        return (s ~ /^### Added[[:space:]]*$/ ||
                s ~ /^### Changed[[:space:]]*$/ ||
                s ~ /^### Fixed[[:space:]]*$/ ||
                s ~ /^### Known Issues[[:space:]]*$/ ||
                is_persistent_heading(s))
    }
    # 仅未经编辑的模板原句算占位符：必须带「（请完善）」后缀
    function is_placeholder_item(s) {
        return s ~ /^[[:space:]]*-.*(新功能描述|功能变更描述|问题修复描述|已知问题描述)[[:space:]]*(（请完善）|\(请完善\))[[:space:]]*$/ ||
               s ~ /^[[:space:]]*-[[:space:]]*(（请完善）|\(请完善\))[[:space:]]*$/
    }
    # 预设条目：1. 模组上电下电说明 / 2. 驱动加载说明 / 3. WiFI测试说明 / 4. 蓝牙测试说明
    function is_preset_line(s) {
        return s ~ /^[[:space:]]*[0-9]+\.[[:space:]]+(模组上电下电说明|驱动加载说明|WiFI测试说明|蓝牙测试说明)[：:]/
    }
    # 未填写：冒号后仍是 xx、无特殊说明，或冒号后为空
    function preset_unfilled(s) {
        return s ~ /[：:][[:space:]]*xx[[:space:]]*$/ ||
               s ~ /[：:][[:space:]]*无特殊说明[[:space:]]*$/ ||
               s ~ /[：:][[:space:]]*$/
    }
    function fill_preset_default(s) {
        sub(/[：:].*$/, "：无特殊说明", s)
        return s
    }
    function flush_persistent_section(    i, line, nfilled) {
        print section_name
        print ""
        # 先统计是否有实际填写内容
        nfilled = 0
        for (i = 1; i <= nbody; i++) {
            line = body[i]
            if (is_blank(line)) continue
            if (is_placeholder_item(line)) continue
            if (line ~ /^[[:space:]]*无特殊说明[[:space:]]*$/) continue
            if (is_preset_line(line)) {
                if (!preset_unfilled(line)) nfilled++
                continue
            }
            nfilled++
        }
        if (nfilled == 0) {
            # 全部未填写：只显示「无特殊说明」，不展开三行「：无特殊说明」
            print "无特殊说明"
        } else {
            # 有实际说明：按原顺序输出；未填预设行才写成「：无特殊说明」
            for (i = 1; i <= nbody; i++) {
                line = body[i]
                if (is_blank(line)) continue
                if (is_placeholder_item(line)) continue
                if (line ~ /^[[:space:]]*无特殊说明[[:space:]]*$/) continue
                if (is_preset_line(line)) {
                    if (preset_unfilled(line)) line = fill_preset_default(line)
                    print line
                    continue
                }
                if (line ~ /（请完善）/ || line ~ /\(请完善\)/) line = strip_placeholder(line)
                print line
            }
        }
        print ""
        section_name = ""
        nbody = 0
        delete body
    }
    function flush_section(    i, has, line) {
        if (section_name == "") return
        if (is_persistent_heading(section_name)) {
            flush_persistent_section()
            return
        }
        print section_name
        has = 0
        for (i = 1; i <= nbody; i++) {
            if (!is_blank(body[i]) && !is_placeholder_item(body[i])) has = 1
        }
        if (!has) {
            print ""
            print "- 无"
            print ""
        } else {
            for (i = 1; i <= nbody; i++) {
                if (is_placeholder_item(body[i])) continue
                line = body[i]
                if (line ~ /（请完善）/ || line ~ /\(请完善\)/) line = strip_placeholder(line)
                print line
            }
        }
        section_name = ""
        nbody = 0
        delete body
    }
    {
        if (is_tracked_heading($0)) {
            flush_section()
            section_name = $0
            nbody = 0
            next
        }
        if (section_name != "" && ($0 ~ /^### / || $0 ~ /^## / || $0 ~ /^---[[:space:]]*$/)) {
            flush_section()
        }
        if (section_name != "") {
            nbody++
            body[nbody] = $0
            next
        }
        print $0
    }
    END { flush_section() }
    ' "$file" > "$tmp"

    # 审核通过后去掉 CHECKED 行与审核提示语（保留 > **Build:** / > **Upload:**）
    local tmp2
    tmp2=$(mktemp)
    tr -d '\r' < "$tmp" \
        | awk '
            /^[[:space:]]*CHECKED:/ { next }
            /^>[[:space:]]*\*\*/ { print; next }
            /^>/ { next }
            { print }
          ' > "$tmp2"
    mv "$tmp2" "$tmp"

    mv "$tmp" "$file"
    log_info "已清理 CHANGELOG 占位符与审核提示；未填写的产线/测试部说明已收为「无特殊说明」，空白分类已填入「- 无」"
}

# ===================== CHANGELOG 提取函数 =====================
# 从 CHANGELOG_TEMP.md 中提取发行说明正文（去掉 CHECKED 标记和审核提示）
# 保留元数据行 > **Build:** / > **Upload:**，删除其余 > 提示语
extract_current_version_entry() {
    local source_file="$1"

    if [[ ! -f "$source_file" ]]; then
        echo ""
        return
    fi

    tr -d '\r' < "$source_file" \
        | awk '
            /^[[:space:]]*CHECKED:/ { next }
            # 保留 Build/Upload 元数据
            /^>[[:space:]]*\*\*/ { print; next }
            # 删除其余审核提示（> 开头的说明行）
            /^>/ { next }
            { print }
          ' \
        | awk '
            NF { empty = 0; print; next }
            { if (empty == 0) print; empty = 1 }
            END { }
          '
}

# 组装最终 CHANGELOG.md：
#   # Release Notes
#   ## [本次版本]
#   ### 产线自动化测试注意事项说明   ← 在版本标题之下；优先本次草稿，否则上一次
#   ### 测试部使用镜像注意事项说明
#   ### Added / Changed / ...
#   ---
#   （历史版本条目；去掉旧版顶层 ## 持久章节与重复标题）
assemble_full_changelog() {
    local current_entry="$1"
    local output_file="$2"

    local preferred_source=""
    if [[ -n "$RELEASE_NOTES_PATH" && -f "$RELEASE_NOTES_PATH" ]]; then
        preferred_source="$RELEASE_NOTES_PATH"
    elif [[ -f "${SDK_ROOT_DIR}/${CHANGELOG_TEMP}" ]]; then
        preferred_source="${SDK_ROOT_DIR}/${CHANGELOG_TEMP}"
    fi

    # 去掉 # Release Notes 与旧版顶层 ## 持久章节
    local version_body
    local tmp_cur
    tmp_cur=$(mktemp)
    printf '%s\n' "$current_entry" > "$tmp_cur"
    version_body=$(strip_toplevel_noise "$tmp_cur")
    rm -f "$tmp_cur"
    version_body=$(printf '%s\n' "$version_body" | sed -e '/./,$!d')

    # 若版本条目内尚无持久章节，再解析并插入（已有则不解析，避免占位日志）
    if ! text_has_persistent_sections "$version_body"; then
        local persistent_block
        persistent_block=$(resolve_persistent_sections "$preferred_source")
        version_body=$(inject_persistent_under_version "$version_body" "$persistent_block")
    fi

    local history=""
    if [[ "$HAS_PREVIOUS_CHANGELOG" == true && -f "$PREVIOUS_CHANGELOG_CACHE" ]]; then
        history=$(strip_toplevel_noise "$PREVIOUS_CHANGELOG_CACHE")
        history=$(printf '%s\n' "$history" | sed -e '/./,$!d')
    fi

    {
        echo "# Release Notes"
        echo ""
        if [[ -n "$version_body" ]]; then
            printf '%s\n' "$version_body"
        fi
        if [[ -n "$history" ]]; then
            echo ""
            echo "---"
            echo ""
            printf '%s\n' "$history"
        fi
    } > "$output_file"
}

# ===================== 打包镜像 =====================
package_image() {
    local target_path="$1"
    log_step "打包镜像 (.zip)"

    TEMP_DIR=$(mktemp -d)

    local img_basename
    img_basename=$(basename "$IMG_NAME")
    local zip_name="${img_basename%.img}.zip"
    ZIP_FILE="${TEMP_DIR}/${zip_name}"

    # 1. 获取当前版本的发行说明（可能含持久章节；组装时会拆分）
    local current_entry=""
    if [[ -n "$RELEASE_NOTES_PATH" ]]; then
        log_info "使用外部 Release Notes: ${RELEASE_NOTES_PATH}"
        current_entry=$(cat "$RELEASE_NOTES_PATH")
    elif [[ -f "${SDK_ROOT_DIR}/${CHANGELOG_TEMP}" ]]; then
        log_info "从 CHANGELOG_TEMP.md 提取发行说明..."
        current_entry=$(extract_current_version_entry "${SDK_ROOT_DIR}/${CHANGELOG_TEMP}")

        # 确保提取结果非空
        if [[ -z "$current_entry" ]]; then
            log_warn "提取的 CHANGELOG 内容为空，使用原始模板"
            current_entry=$(sed -n '1,/^---/p' "${SDK_ROOT_DIR}/${CHANGELOG_TEMP}" | sed '$d')
        fi
    else
        # 生成最小版本（持久章节由 assemble_full_changelog 插入到版本标题下）
        log_warn "未找到任何 CHANGELOG 来源，生成默认版本条目"
        current_entry=$(
            printf '## [%s] %s\n\n> **Build:** %s\n> **Upload:** %s\n\n### Added\n- %s %s 驱动支持\n\n---\n' \
                "$VERSION" "$(date '+%Y-%m-%d %H:%M')" \
                "${BUILD_TIME:-$DATE_FORMATTED}" "$(date '+%Y-%m-%d %H:%M')" \
                "$CHIPSET" "$MODULE_MODEL"
        )
    fi

    # 2. 生成完整的 CHANGELOG.md（本次版本含持久章节 + 历史版本）
    local full_changelog="${TEMP_DIR}/${CHANGELOG_FILE}"
    if [[ "$HAS_PREVIOUS_CHANGELOG" == true ]]; then
        log_info "合并 CHANGELOG：版本内继承持久章节 + 追加本次版本到历史上方"
    else
        log_info "首次发行，创建带持久章节的 CHANGELOG.md"
    fi
    assemble_full_changelog "$current_entry" "$full_changelog"

    # 3. 复制镜像到临时目录
    cp "$IMG_NAME" "${TEMP_DIR}/"

    # 4. 打包 zip
    log_info "创建压缩包: ${zip_name}"
    log_info "  包含: ${img_basename}"
    log_info "  包含: ${CHANGELOG_FILE}（版本内持久章节 + 完整历史）"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[模拟] zip -r ${ZIP_FILE} ${img_basename} ${CHANGELOG_FILE}"
        return 0
    fi

    cd "$TEMP_DIR"
    if zip -r "$ZIP_FILE" "$img_basename" "$CHANGELOG_FILE" >/dev/null 2>&1; then
        local size
        size=$(stat -c%s "$ZIP_FILE" 2>/dev/null | awk '{printf "%.1f MB", $1/1024/1024}')
        log_info "✅ 压缩包创建成功 (${size})"
    else
        log_error "压缩包创建失败"
        return 1
    fi

    return 0
}

# ===================== 上传文件 =====================
upload_file() {
    local target_path="$1"
    local zip_basename
    zip_basename=$(basename "$ZIP_FILE")
    local target_file="${target_path}${zip_basename}"

    log_info "上传固件..."
    log_info "  源文件: ${ZIP_FILE}"
    log_info "  目标:   ${target_file}"

    if [[ "$DRY_RUN" == true ]]; then
        if [[ "$FTP_USE_LFTP" == true ]]; then
            log_info "[模拟] lftp put ${ZIP_FILE} -> ${target_path}"
        else
            log_info "[模拟] cp ${ZIP_FILE} -> ${target_file}"
        fi
        return 0
    fi

    # 上传文件
    local upload_ok=false
    if [[ "$FTP_USE_LFTP" == true ]]; then
        # 通过 lftp 上传
        log_debug "执行 lftp put..."
        if lftp_put_remote "$ZIP_FILE" "$target_path"; then
            upload_ok=true
            log_info "✅ lftp 上传成功"
        else
            log_error "lftp 上传失败"
            return 1
        fi
    else
        # 本地文件系统复制
        if cp "$ZIP_FILE" "$target_file"; then
            chmod 644 "$target_file"
            upload_ok=true
        else
            log_error "上传失败"
            return 1
        fi
    fi

    # 完整性校验：比较文件大小
    local src_size
    src_size=$(stat -c%s "$ZIP_FILE" 2>/dev/null || stat -f%z "$ZIP_FILE" 2>/dev/null)
    local tgt_size=0

    if [[ "$FTP_USE_LFTP" == true ]]; then
        tgt_size=$(lftp_get_remote_file_size "${target_file}" 2>/dev/null)
    else
        tgt_size=$(stat -c%s "$target_file" 2>/dev/null || stat -f%z "$target_file" 2>/dev/null)
    fi

    if [[ "$src_size" -eq "$tgt_size" ]]; then
        log_info "✅ 上传成功，完整性验证通过"
    elif [[ "$tgt_size" -eq 0 ]]; then
        log_warn "无法获取远程文件大小，跳过完整性验证"
    else
        log_warn "文件大小不匹配: src=${src_size} dst=${tgt_size}"
        return 1
    fi

    return 0
}

# ===================== 更新全局 CHANGELOG =====================
update_global_changelog() {
    local target_path="$1"
    # 全局 CHANGELOG.md 位于版本目录的上一级（如 Release/ 或 Debug/ 目录）
    local global_parent
    global_parent=$(dirname "$target_path")
    local global_changelog="${global_parent}/${CHANGELOG_FILE}"

    log_info "更新全局 CHANGELOG.md (${global_changelog}) ..."

    # 打包时已生成完整的 CHANGELOG.md（当前条目 + 历史）
    local full_source="${TEMP_DIR}/${CHANGELOG_FILE}"
    if [[ ! -f "$full_source" ]]; then
        log_warn "CHANGELOG 源文件不存在，跳过全局更新"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        if [[ "$FTP_USE_LFTP" == true ]]; then
            log_info "[模拟] lftp put ${full_source} → ${global_parent}/"
        else
            log_info "[模拟] cp ${full_source} → ${global_changelog}"
        fi
        return 0
    fi

    if [[ "$FTP_USE_LFTP" == true ]]; then
        # 通过 lftp 上传全局 CHANGELOG
        if lftp_put_remote "$full_source" "$global_parent"; then
            log_info "✅ 全局 CHANGELOG.md 已更新（lftp）"
        else
            log_warn "全局 CHANGELOG.md 远程上传失败"
        fi
        # 同时在版本目录也上传一份副本
        if [[ "$target_path" != "$global_parent" ]]; then
            lftp_mkdir_remote "$target_path"
            if lftp_put_remote "$full_source" "$target_path"; then
                log_info "✅ 版本目录副本已上传: ${target_path}${CHANGELOG_FILE}"
            fi
        fi
    else
        cp "$full_source" "$global_changelog"
        chmod 644 "$global_changelog"
        log_info "✅ 全局 CHANGELOG.md 已更新"

        # 同时在版本目录中也拷贝一份副本
        local version_copy="${target_path}${CHANGELOG_FILE}"
        if [[ "$target_path" != "$global_parent" ]]; then
            cp "$full_source" "$version_copy"
            chmod 644 "$version_copy"
            log_info "✅ 版本目录副本已保存: ${version_copy}"
        fi
    fi
}

# ===================== 生成上传报告 =====================
generate_upload_report() {
    local target_path="$1"
    local report_file="upload_report.txt"

    log_info "生成上传报告..."
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[模拟] 生成报告: ${target_path}${report_file}"
        return 0
    fi

    local zip_basename
    zip_basename=$(basename "$ZIP_FILE")
    local zip_size="未知"

    if [[ "$FTP_USE_LFTP" == true ]]; then
        local rmt_bytes
        rmt_bytes=$(lftp_get_remote_file_size "${target_path}${zip_basename}" 2>/dev/null)
        if [[ "$rmt_bytes" -gt 0 ]]; then
            zip_size=$(echo "$rmt_bytes" | awk '{printf "%.1f MB", $1/1024/1024}')
        fi
    else
        if [[ -f "${target_path}${zip_basename}" ]]; then
            zip_size=$(stat -c%s "${target_path}${zip_basename}" 2>/dev/null | awk '{printf "%.1f MB", $1/1024/1024}')
        fi
    fi

    # 生成本地临时报告文件
    local temp_report
    temp_report=$(mktemp)
    cat > "$temp_report" << REPORT_EOF
========================================
  模组测试镜像上传报告
========================================

上传时间: $(date '+%Y-%m-%d %H:%M:%S')
上传用户: $(whoami)
上传主机: $(hostname)
${FTP_HOST:+FTP 服务器: ${FTP_HOST}:${FTP_PORT}}

镜像信息:
  镜像文件:   $(basename "$IMG_NAME")
  压缩包:     ${zip_basename}
  主控芯片:   ${SOC_PLATFORM}
  系统平台:   ${OS_VER}
  模组芯片:   ${CHIPSET}
  模组型号:   ${MODULE_MODEL}
  版本号:     ${VERSION}
  版本类型:   ${BUILD_TYPE}
  日期:       ${DATE}
  ${GIT_HASH:+Git 哈希: ${GIT_HASH}}

存储路径:    ${target_path}
压缩包大小:  ${zip_size}

========================================
REPORT_EOF

    if [[ "$FTP_USE_LFTP" == true ]]; then
        # 上传报告到远程（用 -o 指定目标文件名，避免 mktemp 的随机名）
        if lftp_exec "put -O ${target_path} ${temp_report} -o ${report_file}"; then
            log_info "✅ 上传报告已生成（远程）"
        else
            log_warn "上传报告远程上传失败"
        fi
    else
        cp "$temp_report" "${target_path}${report_file}"
        chmod 644 "${target_path}${report_file}"
        log_info "✅ 上传报告已生成"
    fi
    rm -f "$temp_report"
}

# ===================== 上传 build_info 相关文件 =====================
upload_build_info() {
    local target_path="$1"

    log_info "检查源目录中 build_info 相关文件..."

    # 自动发现所有 build_info* 文件（含子仓库独立 diff 文件 build_info_submodule_*.diff）
    local info_files=()
    while IFS= read -r -d '' f; do
        info_files+=("$(basename "$f")")
    done < <(find "${IMG_SOURCE_DIR}" -maxdepth 1 -type f -name "build_info*" -print0 2>/dev/null)

    if [[ ${#info_files[@]} -eq 0 ]]; then
        log_info "未发现 build_info 相关文件，跳过"
        return 0
    fi

    for info_file in "${info_files[@]}"; do
        local src_file="${IMG_SOURCE_DIR}/${info_file}"
        if [[ ! -f "$src_file" ]]; then
            continue
        fi

        local target_file="${target_path}${info_file}"

        if [[ "$DRY_RUN" == true ]]; then
            if [[ "$FTP_USE_LFTP" == true ]]; then
                log_info "[模拟] lftp put ${src_file} → ${target_path}"
            else
                log_info "[模拟] cp ${src_file} → ${target_file}"
            fi
            continue
        fi

        if [[ "$FTP_USE_LFTP" == true ]]; then
            if lftp_put_remote "$src_file" "$target_path"; then
                log_info "✅ ${info_file} 已上传到远程目录"
            else
                log_warn "${info_file} 远程上传失败"
            fi
        else
            cp "$src_file" "$target_file"
            chmod 644 "$target_file"
            log_info "✅ ${info_file} 已上传: ${target_file}"
        fi
    done
}

# ===================== 发布后提交（已禁用） =====================
# 此函数不再使用 —— 上传后不自动提交 SDK 仓库的 CHANGELOG.md
post_release_commit() {
    log_info "跳过 SDK git 提交（post_release_commit 已禁用）"
    return 0
}

# ===================== 清理函数 =====================
cleanup() {
    local exit_code=$?

    echo ""
    # 只在实际上传成功后清理草稿；help / 用户取消 / dry-run 都要保留已填写内容
    if [[ $exit_code -eq 0 && "$UPLOAD_SUCCEEDED" == true && "$DRY_RUN" != true ]]; then
        if [[ -f "${SDK_ROOT_DIR}/${CHANGELOG_TEMP}" ]]; then
            rm -f "${SDK_ROOT_DIR}/${CHANGELOG_TEMP}"
            log_info "已清理: ${CHANGELOG_TEMP}"
        fi
    fi

    # 清理上一次 CHANGELOG 缓存
    if [[ -f "${PREVIOUS_CHANGELOG_CACHE:-}" ]]; then
        rm -f "$PREVIOUS_CHANGELOG_CACHE"
        log_debug "已清理上一次 CHANGELOG 缓存"
    fi

    # 清理临时目录
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        log_debug "已清理临时目录"
    fi

    if [[ $exit_code -ne 0 ]]; then
        log_error "脚本执行失败，退出码: ${exit_code}"
        if [[ -f "${SDK_ROOT_DIR}/${CHANGELOG_TEMP}" ]]; then
            echo ""
            log_warn "CHANGELOG_TEMP.md 已保留，可编辑后重试:"
            log_warn "  ${SDK_ROOT_DIR}/${CHANGELOG_TEMP}"
        fi
    fi
    exit $exit_code
}

# ===================== 主函数 =====================
main() {
    local start_time
    start_time=$(date +%s)

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     Feasycom 模组测试镜像上传工具 v2.3   ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""

    # 注册清理函数
    trap cleanup EXIT

    # 1. 解析参数
    parse_args "$@"

    # 2. 前置检查
    pre_checks

    # 3. 解析镜像名
    if ! parse_image_name "$IMG_NAME"; then
        log_error "镜像名解析失败"
        exit 1
    fi

    # 4. 解析镜像文件源目录（用于查找 build_info 文件）
    IMG_SOURCE_DIR="$(cd "$(dirname "$IMG_NAME")" && pwd 2>/dev/null || echo "$(dirname "$IMG_NAME")")"

    # 打印信息摘要
    echo ""
    echo "镜像信息摘要:"
    echo "  - 平台:      ${SOC_PLATFORM}_${OS_VER}"
    echo "  - 模组:      ${CHIPSET}_${MODULE_MODEL}"
    echo "  - 版本:      ${VERSION} (${BUILD_TYPE})"
    echo "  - 日期:      ${DATE}"
    [[ -n "${GIT_HASH:-}" ]] && echo "  - Git 哈希:  ${GIT_HASH}"
    [[ -n "${TIME:-}" ]] && echo "  - 时间:      ${TIME}"
    echo ""

    # 5. 生成目标路径
    local target_path
    target_path=$(generate_target_path)
    log_info "目标路径: $target_path"

    # 6. 路径安全检查
    if ! check_path_security "$target_path"; then
        log_error "路径安全检查失败"
        exit 1
    fi

    # 7. 镜像版本冲突检查（仅 Release）
    check_version_conflict "$target_path"

    # 8. 拉取上一次全局 CHANGELOG（供持久章节继承；模板生成与打包共用）
    fetch_previous_changelog "$target_path"

    # 9. 检测 FEASY_FORCE_SKIP 环境变量（CI 自动化逃生通道）
    if [[ "${FEASY_FORCE_SKIP:-}" == "1" && "$SKIP_CHANGELOG" == false && -z "$RELEASE_NOTES_PATH" ]]; then
        log_info "检测到环境变量 FEASY_FORCE_SKIP=1，自动进入 --skip-changelog 模式"
        SKIP_CHANGELOG=true
    fi

    # 10. 生成/检查 CHANGELOG 模板
    if [[ "$SKIP_CHANGELOG" == true ]]; then
        log_info "已跳过 CHANGELOG 审核流程 (--skip-changelog)"
        log_info "将为 .zip 包生成默认 CHANGELOG.md（仍继承持久章节）"
    elif [[ -n "$RELEASE_NOTES_PATH" ]]; then
        log_info "使用外部 Release Notes 文件: ${RELEASE_NOTES_PATH}"
    else
        generate_changelog_template
    fi

    # 11. 目标路径确认
    confirm_target_path "$target_path"

    # 12. 打包镜像 (.img + CHANGELOG.md → .zip，CHANGELOG 与全局历史合并)
    if ! package_image "$target_path"; then
        log_error "打包失败"
        exit 1
    fi

    # 13. 检查目标文件是否已存在
    local zip_basename
    zip_basename=$(basename "$ZIP_FILE")
    if ! check_file_exists "$target_path" "$zip_basename"; then
        exit 1
    fi

    # 14. 创建目标目录（目录已存在则跳过）
    if [[ "$DRY_RUN" == true ]]; then
        if [[ "$FTP_USE_LFTP" == true ]]; then
            log_info "[模拟] lftp mkdir -p ${target_path}"
        else
            log_info "[模拟] mkdir -p ${target_path} && chmod 755"
        fi
    else
        if [[ "$FTP_USE_LFTP" == true ]]; then
            if lftp_remote_dir_exists "$target_path"; then
                log_info "目标目录已存在，跳过创建: ${target_path}"
            else
                if ! lftp_mkdir_remote "$target_path"; then
                    log_error "远程目录创建失败: ${target_path}"
                    exit 1
                fi
                log_info "远程目录已创建: ${target_path}"
            fi
        else
            if [[ ! -d "$target_path" ]]; then
                mkdir -p "$target_path"
                chmod 755 "$target_path"
                log_info "本地目录已创建: ${target_path}"
            else
                log_info "本地目录已存在，跳过创建: ${target_path}"
            fi
        fi
    fi

    # 15. 上传 .zip
    if ! upload_file "$target_path"; then
        log_error "文件上传失败"
        exit 1
    fi

    # 16. 更新全局 CHANGELOG.md（FTP 目录）
    update_global_changelog "$target_path"

    # 17. 生成上传报告
    generate_upload_report "$target_path"

    # 18. 上传 build_info 相关文件（build_info.txt / build_info.diff）
    upload_build_info "$target_path"

    # 19. 计算耗时并输出摘要
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          ✅ 上传完成!                    ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo "  耗时:   ${duration} 秒"
    echo "  目标:   ${target_path}"
    echo "  文件:   ${zip_basename}"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[模拟模式] 以上操作未实际执行${NC}"
        echo ""
    else
        UPLOAD_SUCCEEDED=true
    fi
}

# ===================== 脚本入口 =====================
main "$@"
