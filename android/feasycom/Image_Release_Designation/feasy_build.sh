#!/bin/bash
# =============================================================================
# feasy_build.sh - 模组测试镜像自动化编译脚本
# 功能：一键编译固件、自动生成标准命名镜像、支持Debug/Release模式
# 安全机制：Release模式检查Git提交状态，防止未提交修改的代码生成固件
# =============================================================================

set -euo pipefail

# ===================== 配置区域 =====================
# SDK 根目录（脚本所在目录的上一级）
SDK_ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 镜像输出目录
IMAGES_OUTPUT_DIR="${SDK_ROOT_DIR}/IMAGES"
# 编译日志文件
BUILD_LOG_FILE="${SDK_ROOT_DIR}/build_feasy.log"
# 设备配置文件基础路径
DEVICE_BASE_PATH="device/rockchip/rk356x"

# ===================== 颜色输出 =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ===================== 全局变量 =====================
MODULE_NAME=""
BUILD_TYPE="debug"  # debug 或 release
BUILD_SCOPE="all"   # all | uboot | kernel | android
VERBOSE=false
CLEAN_BUILD=false
SUBMODULE_UPDATE=false
DRY_RUN=false
COPY_FIRMWARE=false
FW_MODULE_NAME=""
SKIP_FW=false
# 本次由脚本拷贝到目标目录的顶层条目（相对路径名），编译成功后用于清理
FW_COPIED_ITEMS=()
FW_DEST_DIR=""
IMAGE_BASENAME=""
GENERATED_UPDATE_IMG=""
FW_SRC_BASE="vendor/rockchip/common/wifi/feasycom-fw"

# ===================== 日志函数 =====================
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$BUILD_LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" >> "$BUILD_LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "$BUILD_LOG_FILE"
}

log_debug() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1" >> "$BUILD_LOG_FILE"
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
用法: $0 [选项] -m <模组型号>

选项:
    -h, --help                  显示此帮助信息
    -m, --module <模组型号>     指定模组型号 (如: BW8205, BW8105)
    -d, --debug                 编译 Debug 调试固件 (默认)
    -r, --release               编译 Release 发行版固件
    -u, --uboot-only            仅编译 U-Boot（build.sh -Uu，提示 update.img 路径，不拷贝发行镜像）
    -k, --kernel-only           仅编译 Kernel（build.sh -Ku，提示 update.img 路径，不拷贝发行镜像）
    -a, --android-only          仅编译 Android（build.sh -Au，提示 update.img 路径，不拷贝发行镜像）
    -c, --clean                 先执行 clean 再编译
    -U, --update-submodules     更新 Git submodules
    -f, --copy-fw <固件名>      编译前拷贝 WiFi 固件 (如: mt7963, atbm6165)
    --skip-fw                   跳过 WiFi 固件拷贝（非交互模式默认跳过）
    -v, --verbose               详细输出模式

示例:
    $0 -h                             显示此帮助信息
    $0 -m BW8205                      一键编译 Debug 版 BW8205 固件（默认，source + lunch + build.sh -UKAu）
    $0 -m BW8205 -d                   编译 Debug 调试版 BW8205 固件
    $0 -m BW8205 -r                   编译 Release 发行版 BW8205 固件（检查 Git 未提交修改）
    $0 -m BW8205 -u                   仅编译 U-Boot（build.sh -Uu，打包 update.img 但不拷贝发行镜像）
    $0 -m BW8205 -k                   仅编译 Kernel（build.sh -Ku，打包 update.img 但不拷贝发行镜像）
    $0 -m BW8205 -a                   仅编译 Android（build.sh -Au，打包 update.img 但不拷贝发行镜像）
    $0 -m BW8205 -c -U                先 clean 并更新 submodules 后编译
    $0 -m BW8205 -d -v                Debug 编译 + 详细输出
    $0 -m BW8205 -f mt7963            编译前拷贝 mt7963 WiFi 固件
    $0 -m BW8205 --skip-fw            编译时不拷贝 WiFi 固件

说明:
    默认全量编译: build.sh -UKAu（U-Boot + Kernel + Android + update.img，不走 IMAGE/-p 发行拷贝）
    -u / -k / -a 互斥，且与全量流程互斥；仅编译模式会打包 update.img 并提示路径，但不拷贝到发行目录、不生成上传相关文件。

    Debug调试版命名:   [项目主控_芯片组]_[系统平台]_[模组芯片]_[模组型号]_[版本号]_Debug_[年月日].[时分].img
    Release发行版命名: [项目主控_芯片组]_[系统平台]_[模组芯片]_[模组型号]_[版本号]_Release_[年月日]_[Git哈希].img

    编译前需要在 device/rockchip/rk356x/<模组型号>/<模组型号>.mk 中配置以下变量:
        PRODUCT_CUSTOM_CHIP := RK3568
        PRODUCT_SYSTEM_PLATFORM := A11
        PRODUCT_CHIPSET_NAME := ATBM6165
        PRODUCT_CUSTOM_VERSION := V1.0.0

    以上四个字段必须符合以下规范（脚本会自动校验）:
        1. PRODUCT_CUSTOM_CHIP      — 英文和数字组成，必须英文起始，不区分大小写，e.g. RK3568, RK3588, MTK8391
        2. PRODUCT_SYSTEM_PLATFORM  — 英文和数字组成，必须英文起始，不区分大小写，e.g. A11, U2204, D12, Yocto
        3. PRODUCT_CHIPSET_NAME     — 英文和数字或至多一个下划线，必须英文起始，不区分大小写，e.g. ATBM6165, RTL8821CS, MT7921
        4. PRODUCT_CUSTOM_VERSION   — 形如 "Vx.x.x"，x 为数字（允许多位十进制），不区分大小写，e.g. V1.0.0, V1.10.0

    设备配置文件路径规则: device/rockchip/rk356x/<模组型号>/<模组型号>.mk
    例如: -m BW8205 则配置文件为 device/rockchip/rk356x/BW8205/BW8205.mk

    WiFi 固件拷贝（交互模式）:
        默认按 PRODUCT_CHIPSET_NAME 自动匹配固件目录（大小写不敏感），
        仅提示是否拷贝 (Y/n)；也可通过 -f/--copy-fw 指定固件名或路径。
        源: ${FW_SRC_BASE:-vendor/rockchip/common/wifi/feasycom-fw}/<固件名>/
        目标: device/rockchip/rk356x/<模组型号>/wifi/firmware/
        拷贝前会列出将拷贝的文件（相对路径，保留源目录层级）。
        若本次由脚本拷贝固件，编译成功后会自动删除本次拷贝的文件，保持工作区干净。
        -f 输入错误时会列出所有可拷贝的固件源路径与目标路径
EOF
    exit 0
}

# ===================== 参数解析 =====================
parse_args() {
    if [[ $# -eq 0 ]]; then
        usage
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                ;;
            -m|--module)
                if [[ -z "$2" || "$2" =~ ^- ]]; then
                    log_error "选项 $1 需要一个参数"
                    exit 1
                fi
                MODULE_NAME="$2"
                shift 2
                ;;
            -d|--debug)
                BUILD_TYPE="debug"
                shift
                ;;
            -r|--release)
                BUILD_TYPE="release"
                shift
                ;;
            -u|--uboot-only)
                set_build_scope "uboot" "-u/--uboot-only"
                shift
                ;;
            -k|--kernel-only)
                set_build_scope "kernel" "-k/--kernel-only"
                shift
                ;;
            -a|--android-only)
                set_build_scope "android" "-a/--android-only"
                shift
                ;;
            -c|--clean)
                CLEAN_BUILD=true
                shift
                ;;
            -U|--update-submodules)
                SUBMODULE_UPDATE=true
                shift
                ;;
            -f|--copy-fw)
                if [[ -z "$2" || "$2" =~ ^- ]]; then
                    log_error "选项 $1 需要一个参数"
                    exit 1
                fi
                FW_MODULE_NAME="$2"
                COPY_FIRMWARE=true
                shift 2
                ;;
            --skip-fw|--no-fw)
                SKIP_FW=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            *)
                log_error "未知选项: $1"
                usage
                exit 1
                ;;
        esac
    done

    # 检查必要参数
    if [[ -z "$MODULE_NAME" ]]; then
        log_error "必须指定模组型号 (-m 选项)"
        exit 1
    fi

    if [[ "$SKIP_FW" == true && "$COPY_FIRMWARE" == true ]]; then
        log_error "--skip-fw 与 -f/--copy-fw 不能同时使用"
        exit 1
    fi
}

# ===================== 环境检查 =====================
check_environment() {
    log_step "环境检查"
    
    # 1. 检查 SDK 根目录
    if [[ ! -d "$SDK_ROOT_DIR" ]]; then
        log_error "SDK 根目录不存在: $SDK_ROOT_DIR"
        exit 1
    fi
    log_info "SDK 根目录: $SDK_ROOT_DIR"
    
    # 2. 检查 build.sh 是否存在
    if [[ ! -f "${SDK_ROOT_DIR}/build.sh" ]]; then
        log_error "build.sh 不存在，请确认是否在 SDK 根目录"
        exit 1
    fi
    log_info "build.sh 存在"
    
    # 3. 检查设备配置文件是否存在（大小写不敏感）
    local device_mk_path
    device_mk_path=$(find "${SDK_ROOT_DIR}/${DEVICE_BASE_PATH}" -maxdepth 2 -type f -iname "${MODULE_NAME}.mk" 2>/dev/null | head -1)
    if [[ -z "$device_mk_path" ]]; then
        log_error "未找到模组 '${MODULE_NAME}' 的设备配置文件"
        log_error "搜索路径: ${SDK_ROOT_DIR}/${DEVICE_BASE_PATH}/**/${MODULE_NAME}.mk（大小写不敏感）"
        log_error "请确认模组型号是否正确，或创建对应的配置文件"
        log_error ""
        log_error "已存在的模组配置:"
        find "${SDK_ROOT_DIR}/${DEVICE_BASE_PATH}" -maxdepth 2 -name "*.mk" -type f 2>/dev/null | sort || true
        exit 1
    fi
    # 修正 MODULE_NAME 为磁盘上的实际大小写
    local real_module_dir
    real_module_dir=$(dirname "$device_mk_path")
    local real_module_name
    real_module_name=$(basename "$real_module_dir")
    if [[ "$real_module_name" != "$MODULE_NAME" ]]; then
        log_info "模组型号大小写修正: '${MODULE_NAME}' → '${real_module_name}'"
        MODULE_NAME="$real_module_name"
    fi
    log_info "找到设备配置文件: $device_mk_path"
    
    # 4. 检查必要工具
    local required_tools=("git" "make" "python3")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "必要工具未安装: $tool"
            exit 1
        fi
    done
    log_info "必要工具检查通过"
    
    # 5. 检查 Git 仓库状态（Release 模式）
    if [[ "$BUILD_TYPE" == "release" ]]; then
        check_git_status
    fi
}

# ===================== Git 状态检查 =====================
check_git_status() {
    log_info "检查 Git 仓库状态（含子仓库）..."

    cd "$SDK_ROOT_DIR"

    local has_dirty=false

    # 检查 superproject 是否有未提交的修改
    if ! git diff --quiet HEAD; then
        log_error "存在未提交的修改！Release 模式禁止使用未提交的代码编译固件"
        log_error "请先提交或暂存所有修改后再编译 Release 版本"
        echo ""
        echo "未提交的文件:"
        git status --short
        has_dirty=true
    fi

    # 检查 submodules 是否有未提交的修改
    local submodules
    submodules=$(git config --file .gitmodules --get-regexp path 2>/dev/null | awk '{print $2}' || true)
    if [[ -n "$submodules" ]]; then
        while IFS= read -r sub_path; do
            if [[ -d "$sub_path" ]]; then
                if ! git -C "$sub_path" diff --quiet HEAD 2>/dev/null; then
                    log_error "子仓库 ${sub_path} 存在未提交的修改！"
                    has_dirty=true
                fi
                local sub_untracked
                sub_untracked=$(git -C "$sub_path" ls-files --others --exclude-standard 2>/dev/null)
                if [[ -n "$sub_untracked" ]]; then
                    log_warn "子仓库 ${sub_path} 存在未跟踪的文件"
                fi
            fi
        done <<< "$submodules"
    fi

    if [[ "$has_dirty" == true ]]; then
        exit 1
    fi

    # 检查是否有未跟踪的文件（superproject）
    local untracked_files
    untracked_files=$(git ls-files --others --exclude-standard)
    if [[ -n "$untracked_files" ]]; then
        log_warn "存在未跟踪的文件，建议检查是否需要纳入版本控制"
        if [[ "$VERBOSE" == true ]]; then
            echo "$untracked_files"
        fi
    fi

    log_info "Git 仓库状态检查通过（含子仓库）"
}

# ===================== MK 配置校验 =====================
# 校验从设备配置文件中读取的四个字段是否符合文档规范
validate_mk_meta() {
    log_step "校验 MK 配置字段"

    local has_error=false

    # 1. PRODUCT_CUSTOM_CHIP: 英文和数字组成，必须英文起始，不区分大小写
    if [[ ! "$PRODUCT_CUSTOM_CHIP" =~ ^[A-Za-z][A-Za-z0-9]*$ ]]; then
        log_error "PRODUCT_CUSTOM_CHIP 格式错误: '${PRODUCT_CUSTOM_CHIP}'"
        log_error "  规范要求: 只能由英文和数字组成，必须英文起始，不区分大小写"
        log_error "  正确示例: RK3568, RK3588, MTK8391"
        has_error=true
    else
        log_info "PRODUCT_CUSTOM_CHIP: ${PRODUCT_CUSTOM_CHIP} ✓"
    fi

    # 2. PRODUCT_SYSTEM_PLATFORM: 英文和数字组成，必须英文起始，不区分大小写
    if [[ ! "$PRODUCT_SYSTEM_PLATFORM" =~ ^[A-Za-z][A-Za-z0-9]*$ ]]; then
        log_error "PRODUCT_SYSTEM_PLATFORM 格式错误: '${PRODUCT_SYSTEM_PLATFORM}'"
        log_error "  规范要求: 只能由英文和数字组成，必须英文起始，不区分大小写"
        log_error "  正确示例: A11, U2204, D12, Yocto"
        has_error=true
    else
        log_info "PRODUCT_SYSTEM_PLATFORM: ${PRODUCT_SYSTEM_PLATFORM} ✓"
    fi

    # 3. PRODUCT_CHIPSET_NAME: 英文和数字或至多一个下划线，必须英文起始，不区分大小写
    if [[ ! "$PRODUCT_CHIPSET_NAME" =~ ^[A-Za-z][A-Za-z0-9]*(_[A-Za-z0-9]+)?$ ]]; then
        log_error "PRODUCT_CHIPSET_NAME 格式错误: '${PRODUCT_CHIPSET_NAME}'"
        log_error "  规范要求: 只能由英文和数字或至多一个下划线组成，必须英文起始，不区分大小写"
        log_error "  正确示例: ATBM6165, RTL8821CS, MT7921"
        has_error=true
    else
        log_info "PRODUCT_CHIPSET_NAME: ${PRODUCT_CHIPSET_NAME} ✓"
    fi

    # 4. PRODUCT_CUSTOM_VERSION: 形如 "Vx.x.x"，x 为数字（允许多位十进制），不区分大小写
    if [[ ! "$PRODUCT_CUSTOM_VERSION" =~ ^[Vv][0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "PRODUCT_CUSTOM_VERSION 格式错误: '${PRODUCT_CUSTOM_VERSION}'"
        log_error "  规范要求: 只能形如 \"Vx.x.x\"，x 必须是数字，允许多位十进制，不区分大小写"
        log_error "  正确示例: V1.0.0, V1.10.0"
        has_error=true
    else
        log_info "PRODUCT_CUSTOM_VERSION: ${PRODUCT_CUSTOM_VERSION} ✓"
    fi

    if [[ "$has_error" == true ]]; then
        local device_mk_path="${SDK_ROOT_DIR}/${DEVICE_BASE_PATH}/${MODULE_NAME}/${MODULE_NAME}.mk"
        log_error ""
        log_error "请在 ${device_mk_path} 中修正上述配置错误后重试"
        exit 1
    fi

    log_info "MK 配置字段校验全部通过"

    # 全部转大写，后续流程统一使用大写值
    PRODUCT_CUSTOM_CHIP="${PRODUCT_CUSTOM_CHIP^^}"
    PRODUCT_SYSTEM_PLATFORM="${PRODUCT_SYSTEM_PLATFORM^^}"
    PRODUCT_CHIPSET_NAME="${PRODUCT_CHIPSET_NAME^^}"
    PRODUCT_CUSTOM_VERSION="${PRODUCT_CUSTOM_VERSION^^}"
    log_info "配置字段已统一转为大写"
}

# ===================== MK 配置读取辅助函数 =====================
# 从设备配置文件中提取指定 key 的值，未找到时警告并提示用户修改位置
read_mk_meta() {
    local key="$1"
    local mk_path="$2"
    local value
    value=$(grep -E "^${key}\s*:=" "$mk_path" 2>/dev/null | awk '{print $3}')
    if [[ -z "$value" ]]; then
        log_error "${key} 未在 ${mk_path} 中定义！"
        log_error "请在该文件中添加: ${key} := <值>"
        log_error "可使用 feasy_template.sh clone 自动生成模板，或参考已有项目的 .mk 文件手动配置"
        exit 1
    fi
    echo "$value"
}

# ===================== 获取版本信息 =====================
get_version_info() {
    log_step "获取版本信息"

    cd "$SDK_ROOT_DIR"

    # 1. 获取 Git 哈希
    GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    log_info "Git 哈希: $GIT_HASH"

    # 2. 获取当前日期时间
    BUILD_DATE=$(date '+%Y%m%d')
    BUILD_TIME=$(date '+%H%M')
    log_info "构建日期: $BUILD_DATE"
    log_info "构建时间: $BUILD_TIME"

    # 3. 从设备配置文件读取配置
    local device_mk_path="${SDK_ROOT_DIR}/${DEVICE_BASE_PATH}/${MODULE_NAME}/${MODULE_NAME}.mk"

    PRODUCT_CUSTOM_CHIP=$(read_mk_meta "PRODUCT_CUSTOM_CHIP" "$device_mk_path")
    PRODUCT_SYSTEM_PLATFORM=$(read_mk_meta "PRODUCT_SYSTEM_PLATFORM" "$device_mk_path")
    PRODUCT_CHIPSET_NAME=$(read_mk_meta "PRODUCT_CHIPSET_NAME" "$device_mk_path")
    PRODUCT_CUSTOM_VERSION=$(read_mk_meta "PRODUCT_CUSTOM_VERSION" "$device_mk_path")

    log_info "自定义芯片: $PRODUCT_CUSTOM_CHIP"
    log_info "系统平台: $PRODUCT_SYSTEM_PLATFORM"
    log_info "模组芯片: $PRODUCT_CHIPSET_NAME"
    log_info "版本号: $PRODUCT_CUSTOM_VERSION"
}

# ===================== 仅编译范围互斥 =====================
# -u / -k / -a 不能同时使用
set_build_scope() {
    local new_scope="$1"
    local flag="$2"
    if [[ "$BUILD_SCOPE" != "all" ]]; then
        log_error "${flag} 与已选择的仅编译选项互斥（-u/--uboot-only、-k/--kernel-only、-a/--android-only 不能同时使用）"
        exit 1
    fi
    BUILD_SCOPE="$new_scope"
}

# ===================== 编译范围描述 =====================
describe_build_scope() {
    case "$BUILD_SCOPE" in
        uboot)   echo "仅 U-Boot (build.sh -Uu)" ;;
        kernel)  echo "仅 Kernel (build.sh -Ku)" ;;
        android) echo "仅 Android (build.sh -Au)" ;;
        *)       echo "全量 (build.sh -UKAu)" ;;
    esac
}

# ===================== 编译前配置确认 =====================
confirm_config() {
    log_step "编译配置确认"

    echo ""
    echo -e "  模组型号:         ${CYAN}${MODULE_NAME}${NC}"
    echo -e "  编译类型:         ${CYAN}${BUILD_TYPE}${NC}"
    echo -e "  编译范围:         ${CYAN}$(describe_build_scope)${NC}"
    echo -e "  产品镜像目录:     ${CYAN}$(get_rockdev_image_dir)${NC}"
    echo -e "  项目主控_芯片组:  ${CYAN}${PRODUCT_CUSTOM_CHIP}${NC}"
    echo -e "  系统平台:         ${CYAN}${PRODUCT_SYSTEM_PLATFORM}${NC}"
    echo -e "  模组芯片:         ${CYAN}${PRODUCT_CHIPSET_NAME}${NC}"
    echo -e "  版本号:           ${CYAN}${PRODUCT_CUSTOM_VERSION}${NC}"
    if [[ "$COPY_FIRMWARE" == true ]]; then
        echo -e "  WiFi 固件拷贝:    ${CYAN}${FW_MODULE_NAME} → ${DEVICE_BASE_PATH}/${MODULE_NAME}/wifi/firmware/${NC}"
    else
        echo -e "  WiFi 固件拷贝:    ${CYAN}跳过${NC}"
    fi
    echo ""

    if [[ ! -t 0 ]]; then
        log_info "非交互模式，跳过配置确认"
        return 0
    fi

    echo -e -n "以上信息是否正确？(Y/n): "
    read -r confirm
    if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
        log_error "配置信息不正确，请检查 device/rockchip/rk356x/${MODULE_NAME}/${MODULE_NAME}.mk 中的配置后重试"
        exit 1
    fi
    log_info "配置确认通过"
}

# ===================== 列出可用 WiFi 固件 =====================
list_available_fw_modules() {
    local fw_base="${SDK_ROOT_DIR}/${FW_SRC_BASE}"
    [[ -d "$fw_base" ]] || return 1
    find "$fw_base" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort -f
}

# 列出所有可拷贝的固件源路径与目标路径
print_available_firmware_paths() {
    local fw_base="${SDK_ROOT_DIR}/${FW_SRC_BASE}"
    local dest_base="${DEVICE_BASE_PATH}/${MODULE_NAME}/wifi/firmware"

    if [[ ! -d "$fw_base" ]]; then
        log_error "固件源根目录不存在: ${FW_SRC_BASE}"
        return 1
    fi

    local modules
    modules=$(list_available_fw_modules || true)
    if [[ -z "$modules" ]]; then
        log_error "固件源目录为空: ${FW_SRC_BASE}"
        return 1
    fi

    echo ""
    echo "可用的 WiFi 固件路径 (源 → 目标):"
    while IFS= read -r mod; do
        [[ -n "$mod" ]] || continue
        echo "  ${FW_SRC_BASE}/${mod}/"
        echo "    → ${dest_base}/"
    done <<< "$modules"
    echo ""
    echo "使用示例:"
    local first_mod
    first_mod=$(echo "$modules" | head -1)
    echo "  -f ${first_mod}"
    echo "  -f ${FW_SRC_BASE}/${first_mod}"
    echo ""
}

# Case-insensitive lookup of firmware module directory name on disk
resolve_fw_module_name() {
    local input="$1"
    local fw_base="${SDK_ROOT_DIR}/${FW_SRC_BASE}"
    local found

    [[ -n "$input" ]] || return 1
    [[ -d "$fw_base" ]] || return 1

    found=$(find "$fw_base" -maxdepth 1 -mindepth 1 -type d -iname "$input" -print -quit 2>/dev/null)
    [[ -n "$found" ]] || return 1
    basename "$found"
}

# 从固件名或路径中提取模组目录名（大小写不敏感）
extract_fw_module_from_input() {
    local input="$1"
    local candidate resolved
    local fw_base_rel="${FW_SRC_BASE}"

    [[ -n "$input" ]] || return 1

    input="${input%/}"

    # 去掉 SDK 根目录前缀，便于统一按相对路径处理
    if [[ "$input" == "${SDK_ROOT_DIR}/"* ]]; then
        input="${input#${SDK_ROOT_DIR}/}"
    fi
    input="${input#./}"

    if [[ "$input" == */* ]]; then
        if [[ "$input" == "${fw_base_rel}/"* ]]; then
            candidate="${input#${fw_base_rel}/}"
            candidate="${candidate%%/*}"
        elif [[ "$input" == */feasycom-fw/* ]]; then
            candidate="${input##*/feasycom-fw/}"
            candidate="${candidate%%/*}"
        else
            candidate="${input##*/}"
        fi
    else
        candidate="$input"
    fi

    [[ -n "$candidate" ]] || return 1
    resolve_fw_module_name "$candidate"
}

# 列出固件源目录中将拷贝的相对路径（文件/符号链接，保留层级）
list_firmware_relative_paths() {
    local src_dir="$1"
    [[ -d "$src_dir" ]] || return 1
    (cd "$src_dir" && find . -mindepth 1 \( -type f -o -type l \) | sed 's|^\./||' | sort)
}

# 打印即将拷贝的固件清单（相对路径映射到目标目录）
print_firmware_copy_plan() {
    local src_dir="${SDK_ROOT_DIR}/${FW_SRC_BASE}/${FW_MODULE_NAME}"
    local dest_rel="${DEVICE_BASE_PATH}/${MODULE_NAME}/wifi/firmware"
    local rel count=0 dest_name dest_parent

    echo ""
    echo "将拷贝以下文件（保留源目录层级）:"
    echo "  源:   ${FW_SRC_BASE}/${FW_MODULE_NAME}/"
    echo "  目标: ${dest_rel}/"
    echo ""

    if [[ ! -d "$src_dir" ]]; then
        log_warn "源目录不存在，无法列出文件: ${src_dir}"
        return 1
    fi

    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        ((count++)) || true
        printf "  %d. %s\n" "$count" "$rel"
        dest_name="${rel##*/}"
        dest_parent="${rel%/*}"
        if [[ "$dest_parent" == "$rel" ]]; then
            echo -e "     → ${CYAN}${dest_rel}/${GREEN}${dest_name}${NC}"
        else
            echo -e "     → ${CYAN}${dest_rel}/${dest_parent}/${GREEN}${dest_name}${NC}"
        fi
    done < <(list_firmware_relative_paths "$src_dir" || true)

    if [[ "$count" -eq 0 ]]; then
        log_warn "源目录无可拷贝文件: ${src_dir}"
        return 1
    fi

    echo ""
    log_info "共 ${count} 个文件"
    return 0
}

# Normalize FW_MODULE_NAME to the actual directory name (case-insensitive)
normalize_fw_module_name() {
    if [[ "$COPY_FIRMWARE" != true || -z "$FW_MODULE_NAME" ]]; then
        return 0
    fi

    local original_input="$FW_MODULE_NAME"
    local resolved
    if ! resolved=$(extract_fw_module_from_input "$FW_MODULE_NAME"); then
        log_error "未找到 WiFi 固件路径（大小写不敏感）: ${original_input}"
        log_error "期望格式: <固件名> 或 ${FW_SRC_BASE}/<固件名>"
        print_available_firmware_paths >&2
        exit 1
    fi

    if [[ "$resolved" != "$original_input" && "${resolved,,}" != "${original_input,,}" ]]; then
        log_info "固件路径解析: '${original_input}' → '${FW_SRC_BASE}/${resolved}'"
    elif [[ "$resolved" != "$original_input" ]]; then
        log_info "固件名大小写修正: '${original_input}' → '${resolved}'"
    fi
    FW_MODULE_NAME="$resolved"
}

# ===================== WiFi 固件拷贝选择 =====================
prompt_firmware_copy() {
    if [[ "$SKIP_FW" == true ]]; then
        log_info "已跳过 WiFi 固件拷贝 (--skip-fw)"
        return 0
    fi

    if [[ "$COPY_FIRMWARE" == true ]]; then
        normalize_fw_module_name
        log_info "将拷贝 WiFi 固件: ${FW_MODULE_NAME} (-f/--copy-fw)"
        print_firmware_copy_plan || true
        return 0
    fi

    if [[ ! -t 0 ]]; then
        log_info "非交互模式且未指定 -f，跳过 WiFi 固件拷贝"
        return 0
    fi

    local fw_base="${SDK_ROOT_DIR}/${FW_SRC_BASE}"
    if [[ ! -d "$fw_base" ]]; then
        log_warn "未找到固件源目录 ${fw_base}，跳过 WiFi 固件拷贝"
        return 0
    fi

    # 默认按 PRODUCT_CHIPSET_NAME 自动匹配固件目录（大小写不敏感）
    local resolved
    if ! resolved=$(resolve_fw_module_name "$PRODUCT_CHIPSET_NAME"); then
        log_warn "未找到与 PRODUCT_CHIPSET_NAME='${PRODUCT_CHIPSET_NAME}' 匹配的固件目录，跳过拷贝"
        print_available_firmware_paths >&2 || true
        return 0
    fi

    echo ""
    echo -e "  固件: ${CYAN}${resolved}${NC} (来自 PRODUCT_CHIPSET_NAME)"
    FW_MODULE_NAME="$resolved"
    print_firmware_copy_plan || true
    echo -e -n "是否拷贝该 WiFi 固件？(Y/n): "
    read -r fw_confirm
    if [[ "$fw_confirm" == "n" || "$fw_confirm" == "N" ]]; then
        FW_MODULE_NAME=""
        log_info "跳过 WiFi 固件拷贝"
        return 0
    fi

    FW_MODULE_NAME="$resolved"
    COPY_FIRMWARE=true
    log_info "将拷贝 WiFi 固件: ${FW_MODULE_NAME}"
}

# ===================== 执行 WiFi 固件拷贝 =====================
copy_wifi_firmware() {
    if [[ "$COPY_FIRMWARE" != true ]]; then
        return 0
    fi

    log_step "拷贝 WiFi 固件"

    local firmware_script
    firmware_script="$(cd "$(dirname "$0")" && pwd)/feasy_firmware.sh"

    if [[ ! -f "$firmware_script" ]]; then
        log_error "未找到 feasy_firmware.sh: ${firmware_script}"
        exit 1
    fi

    local src_dir="${SDK_ROOT_DIR}/${FW_SRC_BASE}/${FW_MODULE_NAME}"
    FW_DEST_DIR="${SDK_ROOT_DIR}/${DEVICE_BASE_PATH}/${MODULE_NAME}/wifi/firmware"

    log_info "项目: ${MODULE_NAME}"
    log_info "固件: ${FW_MODULE_NAME}"
    log_info "源: ${FW_SRC_BASE}/${FW_MODULE_NAME}/"
    log_info "目标: ${DEVICE_BASE_PATH}/${MODULE_NAME}/wifi/firmware/"

    # 记录即将拷贝的顶层条目，编译成功后按此列表清理
    FW_COPIED_ITEMS=()
    if [[ -d "$src_dir" ]]; then
        local item
        while IFS= read -r item; do
            [[ -n "$item" ]] && FW_COPIED_ITEMS+=("$item")
        done < <(find "$src_dir" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null)
    fi

    if [[ ${#FW_COPIED_ITEMS[@]} -eq 0 ]]; then
        log_warn "源目录无可拷贝条目: ${src_dir}"
    else
        log_info "本次将拷贝 ${#FW_COPIED_ITEMS[@]} 个顶层条目（编译成功后自动清理）"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[模拟] SDK_ROOT_DIR=${SDK_ROOT_DIR} ${firmware_script} -p ${MODULE_NAME} -m ${FW_MODULE_NAME} -f"
        return 0
    fi

    if SDK_ROOT_DIR="$SDK_ROOT_DIR" "$firmware_script" -p "$MODULE_NAME" -m "$FW_MODULE_NAME" -f; then
        log_info "WiFi 固件拷贝完成"
    else
        log_error "WiFi 固件拷贝失败"
        FW_COPIED_ITEMS=()
        FW_DEST_DIR=""
        exit 1
    fi
}

# ===================== 清理本次拷贝的 WiFi 固件 =====================
# 仅删除本次脚本拷贝进去的顶层条目，不动目标目录中原有其他文件
cleanup_copied_firmware() {
    if [[ "$COPY_FIRMWARE" != true || ${#FW_COPIED_ITEMS[@]} -eq 0 ]]; then
        return 0
    fi

    if [[ -z "$FW_DEST_DIR" ]]; then
        FW_DEST_DIR="${SDK_ROOT_DIR}/${DEVICE_BASE_PATH}/${MODULE_NAME}/wifi/firmware"
    fi

    log_step "清理本次拷贝的 WiFi 固件"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[模拟] 将删除以下拷贝条目:"
        local name
        for name in "${FW_COPIED_ITEMS[@]}"; do
            echo "  ${FW_DEST_DIR}/${name}"
        done
        return 0
    fi

    if [[ ! -d "$FW_DEST_DIR" ]]; then
        log_warn "目标目录已不存在，无需清理: ${FW_DEST_DIR}"
        FW_COPIED_ITEMS=()
        return 0
    fi

    local removed=0
    local missing=0
    local name target
    for name in "${FW_COPIED_ITEMS[@]}"; do
        target="${FW_DEST_DIR}/${name}"
        if [[ -e "$target" || -L "$target" ]]; then
            if rm -rf "$target"; then
                log_info "已删除: ${DEVICE_BASE_PATH}/${MODULE_NAME}/wifi/firmware/${name}"
                ((removed++)) || true
            else
                log_warn "删除失败: ${target}"
            fi
        else
            log_debug "已不存在，跳过: ${target}"
            ((missing++)) || true
        fi
    done

    log_info "固件清理完成: 删除 ${removed} 个条目$([ "$missing" -gt 0 ] && echo "，${missing} 个已不存在")"
    FW_COPIED_ITEMS=()
}

# ===================== 更新 Submodules =====================
update_submodules() {
    if [[ "$SUBMODULE_UPDATE" == false ]]; then
        log_info "跳过 submodules 更新"
        return 0
    fi
    
    log_step "更新 Git Submodules"
    
    cd "$SDK_ROOT_DIR"
    
    log_info "正在更新 submodules..."
    if git submodule update --init --recursive; then
        log_info "Submodules 更新成功"
    else
        log_error "Submodules 更新失败"
        exit 1
    fi
}

# ===================== 编译前准备 =====================
prepare_build() {
    log_step "编译前准备"

    cd "$SDK_ROOT_DIR"

    # 1. 设置环境变量
    log_info "设置编译环境..."
    # 根据实际 SDK 的环境设置命令调整
    if [[ -f "build/envsetup.sh" ]]; then
        # 临时关闭 set -u，因为 envsetup.sh/lunch 引用的变量在 bash 下可能未定义
        set +u
        source build/envsetup.sh
        log_info "已加载 build/envsetup.sh"
        # Lunch 目标
        log_info "Lunch 目标: $MODULE_NAME"
        if ! lunch "$MODULE_NAME-userdebug" 2>&1; then
            log_error "lunch 失败，无法继续编译"
            log_error "请检查 BoardConfig.mk 等配置文件中是否存在变量冲突或语法错误"
            exit 1
        fi
        set -u
    else
        log_warn "未找到 build/envsetup.sh，跳过 envsetup/lunch"
    fi

    # 2. 如果需要清理
    if [[ "$CLEAN_BUILD" == true ]]; then
        log_info "执行清理..."
        # make clean  # 根据实际 SDK 调整
    fi

    log_info "编译前准备完成"
}

# ===================== 生成镜像名 =====================
generate_image_name() {
    log_step "生成镜像名"

    local chip="${PRODUCT_CUSTOM_CHIP}"
    local platform="${PRODUCT_SYSTEM_PLATFORM}"
    local chipset="${PRODUCT_CHIPSET_NAME}"
    local version="${PRODUCT_CUSTOM_VERSION}"
    local build_type_capital

    if [[ "$BUILD_TYPE" == "debug" ]]; then
        build_type_capital="Debug"
        IMAGE_NAME="${chip}_${platform}_${chipset}_${MODULE_NAME^^}_${version}_${build_type_capital}_${BUILD_DATE}.${BUILD_TIME}.img"
    else
        build_type_capital="Release"
        IMAGE_NAME="${chip}_${platform}_${chipset}_${MODULE_NAME^^}_${version}_${build_type_capital}_${BUILD_DATE}_${GIT_HASH}.img"
    fi
    
    IMAGE_BASENAME="${IMAGE_NAME%.img}"
    log_info "镜像名: $IMAGE_NAME"
    log_info "镜像子目录: $IMAGE_BASENAME"
    echo "$IMAGE_NAME"
}

# ===================== 执行编译 =====================
run_build() {
    log_step "开始编译"
    
    cd "$SDK_ROOT_DIR"
    
    log_info "编译类型: $BUILD_TYPE"
    log_info "编译范围: $(describe_build_scope)"
    log_info "模组型号: $MODULE_NAME"
    log_info "产品镜像目录: $(get_rockdev_image_dir)"
    
    # 构建编译命令
    local build_cmd="./build.sh"
    local build_args=""

    case "$BUILD_SCOPE" in
        uboot)
            # 仅 U-Boot：编译并打包 update.img，不走 IMAGE/-p 发行拷贝
            build_args="-Uu"
            ;;
        kernel)
            # 仅 Kernel：编译并打包 update.img，不走 IMAGE/-p 发行拷贝
            build_args="-Ku"
            ;;
        android)
            # 仅 Android：编译并打包 update.img，不走 IMAGE/-p 发行拷贝
            build_args="-Au"
            ;;
        *)
            # 全量：U-Boot + Kernel + Android + update.img，不走 IMAGE/-p 发行拷贝
            # Debug/Release 传参相同，Release 额外在 check_git_status 中校验干净工作区
            build_args="-UKAu"
            ;;
    esac
    
    log_info "执行编译命令: $build_cmd $build_args"
    
    # 执行编译
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[模拟] 执行编译: $build_cmd $build_args"
        return 0
    fi
    
    if $build_cmd $build_args 2>&1 | tee -a "$BUILD_LOG_FILE"; then
        log_info "编译成功"
    else
        log_error "编译失败"
        exit 1
    fi
}

# ===================== 查找编译生成的 update.img =====================
find_image_dir_update_img() {
    # 路径格式: IMAGE/RK356X_<模组型号>_<日期>.<时间>/IMAGES/RK356X_<模组型号>_<日期>.<时间>-update.img
    # 取该模组最新编译生成的镜像（按目录名排序取最新）
    local module_image_dir
    module_image_dir=$(find "${SDK_ROOT_DIR}/IMAGE" -maxdepth 1 -type d -iname "RK356X_${MODULE_NAME}_*" 2>/dev/null | sort | tail -1)
    [[ -z "$module_image_dir" ]] && return 1

    local generated_image="${module_image_dir}/IMAGES/$(basename "${module_image_dir}")-update.img"
    if [[ ! -f "$generated_image" ]]; then
        generated_image=$(find "${module_image_dir}" -name "*update.img" -type f 2>/dev/null | head -1)
    fi
    [[ -n "$generated_image" && -f "$generated_image" ]] || return 1
    echo "$generated_image"
}

# Rockchip 将各产品镜像放到 rockdev/Image-$TARGET_PRODUCT/
# 目录名大小写不敏感，例如 Image-bw6002gi / Image-BW6002GI / image-Bw6002gi 均可
get_rockdev_image_dir() {
    local rockdev_dir="${SDK_ROOT_DIR}/rockdev"
    local product_lower="${MODULE_NAME,,}"
    local expected="${rockdev_dir}/Image-${product_lower}"
    local expected_base_lower="image-${product_lower}"

    if [[ -d "$rockdev_dir" ]]; then
        local dir base
        for dir in "$rockdev_dir"/*; do
            [[ -d "$dir" ]] || continue
            base="$(basename "$dir")"
            if [[ "${base,,}" == "$expected_base_lower" ]]; then
                echo "$dir"
                return 0
            fi
        done
    fi
    echo "$expected"
}

find_rockdev_update_img() {
    local image_dir
    image_dir=$(get_rockdev_image_dir)

    if [[ -f "${image_dir}/update.img" ]]; then
        echo "${image_dir}/update.img"
        return 0
    fi

    if [[ -d "$image_dir" ]]; then
        local rockdev_img
        rockdev_img=$(find "$image_dir" -maxdepth 1 -type f -name "update.img" 2>/dev/null | head -1)
        if [[ -n "$rockdev_img" && -f "$rockdev_img" ]]; then
            echo "$rockdev_img"
            return 0
        fi
    fi

    # mkupdate.sh 常把当前 lunch 产品的 update.img 写到 rockdev 根目录
    if [[ -f "${SDK_ROOT_DIR}/rockdev/update.img" ]]; then
        echo "${SDK_ROOT_DIR}/rockdev/update.img"
        return 0
    fi
    return 1
}

find_generated_update_img() {
    GENERATED_UPDATE_IMG=""
    local found=""

    # feasy_build.sh 不传 -p，update.img 在 rockdev/；兼容旧的 IMAGE/ 产物
    found=$(find_rockdev_update_img || true)
    [[ -z "$found" ]] && found=$(find_image_dir_update_img || true)

    if [[ -n "$found" ]]; then
        GENERATED_UPDATE_IMG="$found"
        return 0
    fi
    return 1
}

# ===================== 复制镜像 =====================
copy_image() {
    log_step "复制镜像文件"
    
    # 创建输出目录
    local output_subdir
    if [[ "$BUILD_TYPE" == "debug" ]]; then
        output_subdir="DEBUG"
    else
        output_subdir="RELEASE"
    fi
    
    local output_dir="${IMAGES_OUTPUT_DIR}/${output_subdir}/${IMAGE_BASENAME}"
    mkdir -p "$output_dir"

    log_info "输出目录: $output_dir"
    log_info "产品镜像目录: $(get_rockdev_image_dir)"

    if ! find_generated_update_img; then
        log_error "未找到模组 '${MODULE_NAME}' 的编译输出镜像"
        log_error "搜索路径: ${SDK_ROOT_DIR}/IMAGE/RK356X_${MODULE_NAME}_* 与 $(get_rockdev_image_dir)/update.img"
        exit 1
    fi

    local generated_image="$GENERATED_UPDATE_IMG"
    log_info "找到生成的镜像: $generated_image"
    
    # 复制并重命名镜像
    local target_image="${output_dir}/${IMAGE_NAME}"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[模拟] 复制镜像: $generated_image -> $target_image"
        return 0
    fi
    
    if cp "$generated_image" "$target_image"; then
        log_info "镜像复制成功: $target_image"
        
        # 计算 MD5
        local md5_value
        md5_value=$(md5sum "$target_image" | cut -d' ' -f1)
        echo "$md5_value" > "${target_image}.md5"
        log_info "MD5: $md5_value"
    else
        log_error "镜像复制失败"
        exit 1
    fi
}

# ===================== 生成构建记录 (build_info) =====================
generate_build_info() {
    log_step "生成构建记录 (build_info.txt)"

    local output_subdir
    if [[ "$BUILD_TYPE" == "debug" ]]; then
        output_subdir="DEBUG"
    else
        output_subdir="RELEASE"
    fi

    local output_dir="${IMAGES_OUTPUT_DIR}/${output_subdir}/${IMAGE_BASENAME}"

    cd "$SDK_ROOT_DIR"

    local build_id
    build_id=$(date -u +%Y%m%d-%H%M%S)
    local commit
    commit=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    local dirty
    dirty=$(git status --porcelain 2>/dev/null | wc -l)

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[模拟] 生成 build_info.txt: ${output_dir}/build_info.txt"
        return 0
    fi

    # 生成 build_info.txt
    local build_info_file="${output_dir}/build_info.txt"
    cat > "$build_info_file" << EOF
BUILD_ID=${build_id}
COMMIT=${commit}
BRANCH=${branch}
DIRTY=${dirty}
EOF

    # 记录所有子仓库状态（submodules），同时累计子仓库改动计数
    local submodules sub_dirty_total=0
    submodules=$(git config --file .gitmodules --get-regexp path 2>/dev/null | awk '{print $2}' || true)
    if [[ -n "$submodules" ]]; then
        echo "" >> "$build_info_file"
        echo "# SUBMODULES" >> "$build_info_file"
        while IFS= read -r sub_path; do
            if [[ -d "$sub_path" ]]; then
                local sub_commit sub_branch sub_dirty
                sub_commit=$(git -C "$sub_path" rev-parse --short HEAD 2>/dev/null || echo "unknown")
                sub_branch=$(git -C "$sub_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
                sub_dirty=$(git -C "$sub_path" status --porcelain 2>/dev/null | wc -l)
                sub_dirty_total=$((sub_dirty_total + sub_dirty))
                echo "" >> "$build_info_file"
                echo "[${sub_path}]" >> "$build_info_file"
                echo "COMMIT=${sub_commit}" >> "$build_info_file"
                echo "BRANCH=${sub_branch}" >> "$build_info_file"
                echo "DIRTY=${sub_dirty}" >> "$build_info_file"
            fi
        done <<< "$submodules"
    fi

    log_info "build_info.txt 已生成: ${build_info_file}"

    # 如果有未提交改动（主仓库或子仓库），生成 build_info.diff（含 tracked changes + untracked files）
    # 子仓库的 diff 用独立的 build_info_submodule_<name>.diff 文件区分
    if [[ "$dirty" -gt 0 || "$sub_dirty_total" -gt 0 ]]; then
        local diff_file="${output_dir}/build_info.diff"

        # Tracked file changes
        git diff HEAD > "$diff_file" 2>/dev/null || true

        # Untracked files（列出名称并 append 内容）
        local untracked
        untracked=$(git ls-files --others --exclude-standard 2>/dev/null || true)
        if [[ -n "$untracked" ]]; then
            echo "" >> "$diff_file"
            echo "=== UNTRACKED FILES ===" >> "$diff_file"
            echo "$untracked" >> "$diff_file"
            echo "=== CONTENTS ===" >> "$diff_file"
            while IFS= read -r f; do
                echo "--- $f ---" >> "$diff_file"
                cat "$f" 2>/dev/null >> "$diff_file" || echo "[binary or missing]" >> "$diff_file"
                echo "" >> "$diff_file"
            done <<< "$untracked"
        fi

        log_info "build_info.diff 已生成 (${dirty} 个未提交变更)"

        # 子仓库 diff 用独立的文件区分
        if [[ -n "$submodules" ]]; then
            while IFS= read -r sub_path; do
                if [[ -d "$sub_path" ]]; then
                    local sub_dirty
                    sub_dirty=$(git -C "$sub_path" status --porcelain 2>/dev/null | wc -l)
                    if [[ "$sub_dirty" -gt 0 ]]; then
                        local sub_diff_name="build_info_submodule_${sub_path//\//_}.diff"
                        local sub_diff_file="${output_dir}/${sub_diff_name}"
                        git -C "$sub_path" diff HEAD > "$sub_diff_file" 2>/dev/null || true
                        log_info "${sub_diff_name} 已生成 (${sub_path}, ${sub_dirty} 个未提交变更)"
                    fi
                fi
            done <<< "$submodules"
        fi
    fi
}

# ===================== 生成编译报告 =====================
generate_build_report() {
    log_step "生成编译报告"
    
    local output_subdir
    if [[ "$BUILD_TYPE" == "debug" ]]; then
        output_subdir="DEBUG"
    else
        output_subdir="RELEASE"
    fi
    
    local report_file="${IMAGES_OUTPUT_DIR}/${output_subdir}/${IMAGE_BASENAME}/build_report_${BUILD_DATE}_${BUILD_TIME}.txt"
    
    log_info "生成编译报告: $report_file"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[模拟] 生成编译报告"
        return 0
    fi
    
    cat > "$report_file" << EOF
========================================
  模组测试镜像编译报告
========================================

编译时间: $(date '+%Y-%m-%d %H:%M:%S')
编译用户: $(whoami)
编译主机: $(hostname)

编译配置:
  模组型号: $MODULE_NAME
  编译类型: $BUILD_TYPE
  系统平台: $PRODUCT_SYSTEM_PLATFORM
  模组芯片: $PRODUCT_CHIPSET_NAME
  版本号: $PRODUCT_CUSTOM_VERSION

镜像信息:
  文件名: $IMAGE_NAME
  Git 哈希: $GIT_HASH
  构建日期: $BUILD_DATE
  构建时间: $BUILD_TIME

编译选项:
  清理构建: $CLEAN_BUILD
  更新 Submodules: $SUBMODULE_UPDATE

========================================
EOF
    
    log_info "编译报告已生成"
}

# ===================== 显示结果摘要 =====================
show_summary() {
    log_step "编译完成摘要"
    
    local output_subdir
    if [[ "$BUILD_TYPE" == "debug" ]]; then
        output_subdir="DEBUG"
    else
        output_subdir="RELEASE"
    fi
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  编译成功!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "  模组型号:     $MODULE_NAME"
    echo "  编译类型:     $BUILD_TYPE"
    echo "  编译范围:     $(describe_build_scope)"
    echo "  产品镜像目录: $(get_rockdev_image_dir)"
    echo "  Git 哈希:     $GIT_HASH"
    if [[ "$COPY_FIRMWARE" == true ]]; then
        echo "  WiFi 固件:    ${FW_MODULE_NAME}（已在编译成功后清理本次拷贝）"
    fi

    if [[ "$BUILD_SCOPE" == "all" ]]; then
        echo "  镜像文件:     ${IMAGES_OUTPUT_DIR}/${output_subdir}/${IMAGE_BASENAME}/${IMAGE_NAME}"
        echo ""
        echo -e "${YELLOW}  上传命令:${NC}"
        echo "  FTP_PASS=\"密码\" ./feasy_upload.sh ${IMAGES_OUTPUT_DIR}/${output_subdir}/${IMAGE_BASENAME}/${IMAGE_NAME}"
    else
        echo ""
        echo -e "${YELLOW}  提示: 仅编译模式已打包 update.img，但未拷贝到发行目录${NC}"
        if [[ -n "$GENERATED_UPDATE_IMG" ]]; then
            echo "  update.img:   $GENERATED_UPDATE_IMG"
        else
            echo "  update.img:   未找到（请检查 $(get_rockdev_image_dir)/update.img 或 IMAGE/ 目录）"
        fi
        echo -e "${YELLOW}  如需发行命名镜像并拷贝到 IMAGES/，请去掉 -u/-k/-a 做全量编译${NC}"
    fi
    echo ""
}

# ===================== 清理函数 =====================
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "脚本执行失败，退出码: $exit_code"
    fi
    exit $exit_code
}

# ===================== 主函数 =====================
main() {
    local start_time
    start_time=$(date +%s)
    
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      Feasycom 模组测试镜像编译工具 v1.3.2     ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""
    
    # 注册清理函数
    trap cleanup EXIT
    
    # 1. 解析参数
    parse_args "$@"
    
    # 2. 环境检查
    check_environment
    
    # 3. 获取版本信息
    get_version_info

    # 4. 校验 MK 配置字段
    validate_mk_meta

    # 5. WiFi 固件拷贝选择
    prompt_firmware_copy
    normalize_fw_module_name

    # 6. 编译前配置确认
    confirm_config

    # 7. 拷贝 WiFi 固件（若已选择）
    copy_wifi_firmware

    # 8. 更新 Submodules
    update_submodules

    # 9. 编译前准备
    prepare_build

    # 10. 执行编译
    run_build

    # 11. 编译成功后清理本次脚本拷贝的固件，保持工作区干净
    cleanup_copied_firmware

    # 12-15. 全量编译才拷贝发行镜像与生成上传相关文件
    # 仅 U-Boot/Kernel/Android 编译：打包 update.img 后提示路径，不拷贝
    if [[ "$BUILD_SCOPE" == "all" ]]; then
        generate_image_name
        copy_image
        generate_build_info
        generate_build_report
    else
        log_info "仅编译模式（${BUILD_SCOPE}），跳过镜像拷贝 / build_info / 编译报告"
        log_info "产品镜像目录: $(get_rockdev_image_dir)"
        if find_generated_update_img; then
            log_info "update.img 路径: ${GENERATED_UPDATE_IMG}"
        else
            log_warn "未找到 update.img，请检查 $(get_rockdev_image_dir)/ 或 IMAGE/ 目录"
        fi
    fi

    # 16. 显示结果摘要
    show_summary

    # 17. 计算执行时间
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    
    log_info "总耗时: ${minutes}分${seconds}秒"
}

# ===================== 脚本入口 =====================
main "$@"
