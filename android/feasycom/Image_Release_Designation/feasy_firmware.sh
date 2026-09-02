#!/bin/bash
# =============================================================================
# feasy_firmware.sh - WiFi 模组固件拷贝脚本
# 功能：将 vendor 下的 Feasycom WiFi 固件拷贝到指定项目的 wifi/firmware 目录
# =============================================================================

set -euo pipefail

# ===================== 配置区域 =====================
# 脚本所在目录；Android SDK 根目录默认取当前工作目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SDK_ROOT_DIR="${SDK_ROOT_DIR:-$(pwd)}"

SRC_BASE="vendor/rockchip/common/wifi/feasycom-fw"
DEST_BASE="device/rockchip/rk356x"

# ===================== 颜色输出 =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ===================== 全局变量 =====================
PROJECT_NAME=""
MODULE_NAME=""
VERBOSE=false
DRY_RUN=false
FORCE=false

# ===================== 日志函数 =====================
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
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
    cat << EOF
用法: $0 [选项] <project_name> <module_name>
   或: $0 [选项] -p <project_name> -m <module_name>

将 WiFi 固件从 vendor 公共目录拷贝到指定项目目录:
  源: ${SRC_BASE}/<module_name>/*
  目标: ${DEST_BASE}/<project_name>/wifi/firmware/

参数:
    project_name                设备项目名 (如: ok3568_r, BW8205)
    module_name                 WiFi 模组固件目录名 (如: mt7963, atbm6165)

选项:
    -h, --help                  显示此帮助信息
    -p, --project <名称>        指定设备项目名
    -m, --module <名称>         指定 WiFi 模组固件名
    -f, --force                 目标目录不存在时自动创建
    -d, --dry-run               仅模拟运行，不实际拷贝
    -v, --verbose               详细输出模式

示例:
    $0 ok3568_r mt7963
    $0 -p BW8205 -m atbm6165
    $0 -p BW8205 -m mt7963 -f
    $0 -d ok3568_r mt7963

说明:
    请在 Android SDK 根目录下执行本脚本（需存在 vendor/ 与 device/）。
    也可通过环境变量 SDK_ROOT_DIR 指定 SDK 根目录。
EOF
    exit 0
}

# ===================== 参数解析 =====================
parse_args() {
    if [[ $# -eq 0 ]]; then
        usage
    fi

    local positional=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                ;;
            -p|--project)
                if [[ -z "${2:-}" || "$2" =~ ^- ]]; then
                    log_error "选项 $1 需要一个参数"
                    exit 1
                fi
                PROJECT_NAME="$2"
                shift 2
                ;;
            -m|--module)
                if [[ -z "${2:-}" || "$2" =~ ^- ]]; then
                    log_error "选项 $1 需要一个参数"
                    exit 1
                fi
                MODULE_NAME="$2"
                shift 2
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -*)
                log_error "未知选项: $1"
                usage
                exit 1
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    # 位置参数: <project_name> <module_name>
    if [[ ${#positional[@]} -eq 2 ]]; then
        PROJECT_NAME="${positional[0]}"
        MODULE_NAME="${positional[1]}"
    elif [[ ${#positional[@]} -gt 0 ]]; then
        log_error "位置参数数量不正确（需要 0 或 2 个）"
        usage
        exit 1
    fi

    if [[ -z "$PROJECT_NAME" || -z "$MODULE_NAME" ]]; then
        log_error "必须指定 project_name 和 module_name"
        usage
        exit 1
    fi
}

# ===================== 环境检查 =====================
check_environment() {
    log_step "环境检查"

    if [[ ! -d "${SDK_ROOT_DIR}/vendor" || ! -d "${SDK_ROOT_DIR}/device" ]]; then
        log_error "当前目录不是有效的 Android SDK 根目录: ${SDK_ROOT_DIR}"
        log_error "请在 SDK 根目录执行，或设置 SDK_ROOT_DIR"
        exit 1
    fi
    log_info "SDK 根目录: ${SDK_ROOT_DIR}"
    log_debug "脚本目录: ${SCRIPT_DIR}"
}

# ===================== 路径解析 =====================
resolve_paths() {
    SRC_DIR="${SDK_ROOT_DIR}/${SRC_BASE}/${MODULE_NAME}"
    DEST_DIR="${SDK_ROOT_DIR}/${DEST_BASE}/${PROJECT_NAME}/wifi/firmware"

    log_info "项目: ${PROJECT_NAME}"
    log_info "模组固件: ${MODULE_NAME}"
    log_info "源目录: ${SRC_DIR}"
    log_info "目标目录: ${DEST_DIR}"
}

# ===================== 前置校验 =====================
pre_checks() {
    log_step "路径校验"

    if [[ ! -d "$SRC_DIR" ]]; then
        log_error "源目录不存在: ${SRC_DIR}"
        log_error "请确认 WiFi 模组固件名是否正确"
        if [[ -d "${SDK_ROOT_DIR}/${SRC_BASE}" ]]; then
            echo ""
            echo "可用的模组固件目录:"
            find "${SDK_ROOT_DIR}/${SRC_BASE}" -mindepth 1 -maxdepth 1 -type d -printf '  %f\n' 2>/dev/null \
                || find "${SDK_ROOT_DIR}/${SRC_BASE}" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sed 's/^/  /'
        fi
        exit 1
    fi

    # 源目录至少要有一个文件/子目录可拷贝
    if [[ -z "$(ls -A "$SRC_DIR" 2>/dev/null)" ]]; then
        log_error "源目录为空: ${SRC_DIR}"
        exit 1
    fi
    log_info "源目录检查通过"

    local project_dir="${SDK_ROOT_DIR}/${DEST_BASE}/${PROJECT_NAME}"
    if [[ ! -d "$project_dir" ]]; then
        log_error "项目目录不存在: ${project_dir}"
        log_error "请先用 feasy_template.sh clone 创建项目，或确认项目名是否正确"
        exit 1
    fi
    log_info "项目目录检查通过"

    if [[ ! -d "$DEST_DIR" ]]; then
        if [[ "$FORCE" == true ]]; then
            log_warn "目标目录不存在，将自动创建: ${DEST_DIR}"
        else
            log_error "目标目录不存在: ${DEST_DIR}"
            log_error "请先创建该目录，或使用 -f/--force 自动创建"
            exit 1
        fi
    else
        log_info "目标目录检查通过"
    fi
}

# 列出源目录中将拷贝的相对路径（文件/符号链接，保留层级）
list_firmware_relative_paths() {
    local src_dir="$1"
    [[ -d "$src_dir" ]] || return 1
    (cd "$src_dir" && find . -mindepth 1 \( -type f -o -type l \) | sed 's|^\./||' | sort)
}

print_firmware_copy_plan() {
    local rel count=0 dest_name dest_parent
    echo ""
    echo "将拷贝以下文件（保留源目录层级）:"
    echo "  源:   ${SRC_DIR}/"
    echo "  目标: ${DEST_DIR}/"
    echo ""
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        ((count++)) || true
        printf "  %d. %s\n" "$count" "$rel"
        dest_name="${rel##*/}"
        dest_parent="${rel%/*}"
        if [[ "$dest_parent" == "$rel" ]]; then
            echo -e "     → ${CYAN}${DEST_DIR}/${GREEN}${dest_name}${NC}"
        else
            echo -e "     → ${CYAN}${DEST_DIR}/${dest_parent}/${GREEN}${dest_name}${NC}"
        fi
    done < <(list_firmware_relative_paths "$SRC_DIR" || true)
    echo ""
    log_info "共 ${count} 个文件"
}

# ===================== 拷贝固件 =====================
copy_firmware() {
    log_step "拷贝 WiFi 固件"

    print_firmware_copy_plan

    if [[ "$DRY_RUN" == true ]]; then
        if [[ ! -d "$DEST_DIR" && "$FORCE" == true ]]; then
            log_info "[模拟] mkdir -p ${DEST_DIR}"
        fi
        log_info "[模拟] cp -a ${SRC_DIR}/. ${DEST_DIR}/"
        return 0
    fi

    if [[ ! -d "$DEST_DIR" ]]; then
        mkdir -p "$DEST_DIR"
        log_info "已创建目标目录: ${DEST_DIR}"
    fi

    log_debug "执行: cp -a \"${SRC_DIR}/.\" \"${DEST_DIR}/\""
    if cp -a "${SRC_DIR}/." "${DEST_DIR}/"; then
        log_info "拷贝成功: ${SRC_DIR} → ${DEST_DIR}"
    else
        log_error "拷贝失败: ${SRC_DIR} → ${DEST_DIR}"
        exit 1
    fi

    if [[ "$VERBOSE" == true ]]; then
        echo ""
        echo "目标目录内容:"
        (cd "$DEST_DIR" && find . -mindepth 1 | sed 's|^\./||' | sort | sed 's/^/  /')
    fi
}

# ===================== 主函数 =====================
main() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      Feasycom WiFi 固件拷贝工具 v1.1          ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    parse_args "$@"
    check_environment
    resolve_paths
    pre_checks
    copy_firmware

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ✅ 固件拷贝完成!                 ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  项目:   ${PROJECT_NAME}"
    echo "  模组:   ${MODULE_NAME}"
    echo "  目标:   ${DEST_DIR}"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[模拟模式] 以上操作未实际执行${NC}"
        echo ""
    fi
}

main "$@"
