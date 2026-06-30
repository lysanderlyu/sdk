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
VERBOSE=false
CLEAN_BUILD=false
SUBMODULE_UPDATE=false
DRY_RUN=false
IMAGE_BASENAME=""

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
    -c, --clean                 先执行 clean 再编译
    -u, --update-submodules     更新 Git submodules
    -v, --verbose               详细输出模式

示例:
    $0 -h                             显示此帮助信息
    $0 -m BW8205                      一键编译 Debug 版 BW8205 固件（默认，source + lunch + build.sh -UKAup）
    $0 -m BW8205 -d                   编译 Debug 调试版 BW8205 固件
    $0 -m BW8205 -r                   编译 Release 发行版 BW8205 固件（检查 Git 未提交修改）
    $0 -m BW8205 -c -u                先 clean 并更新 submodules 后编译
    $0 -m BW8205 -d -v                Debug 编译 + 详细输出

说明:
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
            -c|--clean)
                CLEAN_BUILD=true
                shift
                ;;
            -u|--update-submodules)
                SUBMODULE_UPDATE=true
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

# ===================== 编译前配置确认 =====================
confirm_config() {
    log_step "编译配置确认"

    echo ""
    echo -e "  模组型号:         ${CYAN}${MODULE_NAME}${NC}"
    echo -e "  编译类型:         ${CYAN}${BUILD_TYPE}${NC}"
    echo -e "  项目主控_芯片组:  ${CYAN}${PRODUCT_CUSTOM_CHIP}${NC}"
    echo -e "  系统平台:         ${CYAN}${PRODUCT_SYSTEM_PLATFORM}${NC}"
    echo -e "  模组芯片:         ${CYAN}${PRODUCT_CHIPSET_NAME}${NC}"
    echo -e "  版本号:           ${CYAN}${PRODUCT_CUSTOM_VERSION}${NC}"
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
        lunch "$MODULE_NAME" 2>&1 || log_warn "lunch 失败，可手动执行"
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
    log_info "模组型号: $MODULE_NAME"
    
    # 构建编译命令
    local build_cmd="./build.sh"
    local build_args=""
    
    # 根据编译类型添加参数
    if [[ "$BUILD_TYPE" == "debug" ]]; then
        build_args="-UKAup"  # Debug 编译参数
    else
        build_args="-UKAup"  # Release 编译参数（与 Debug 相同，但会检查 Git 状态）
    fi
    
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
    
    # 查找编译生成的镜像文件
    # 路径格式: IMAGE/RK356X_<模组型号>_<日期>.<时间>/IMAGES/RK356X_<模组型号>_<日期>.<时间>-update.img
    # 取该模组最新编译生成的镜像（按目录名排序取最新）
    local module_image_dir
    module_image_dir=$(find "${SDK_ROOT_DIR}/IMAGE" -maxdepth 1 -type d -iname "RK356X_${MODULE_NAME}_*" 2>/dev/null | sort | tail -1)

    if [[ -z "$module_image_dir" ]]; then
        log_error "未找到模组 '${MODULE_NAME}' 的编译输出目录"
        log_error "搜索路径: ${SDK_ROOT_DIR}/IMAGE/RK356X_*${MODULE_NAME}*（大小写不敏感）"
        exit 1
    fi
    
    local generated_image="${module_image_dir}/IMAGES/$(basename "${module_image_dir}")-update.img"
    
    if [[ ! -f "$generated_image" ]]; then
        log_warn "预期路径未找到镜像，尝试在目录中搜索..."
        generated_image=$(find "${module_image_dir}" -name "*.img" -type f 2>/dev/null | head -1)
    fi
    
    if [[ -z "$generated_image" ]]; then
        log_error "未找到编译生成的镜像文件"
        exit 1
    fi
    
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
    echo "  镜像文件:     ${IMAGES_OUTPUT_DIR}/${output_subdir}/${IMAGE_BASENAME}/${IMAGE_NAME}"
    echo "  Git 哈希:     $GIT_HASH"
    echo ""
    echo -e "${YELLOW}  上传命令:${NC}"
    echo "  FTP_PASS="密码" ./feasy_upload.sh ${IMAGES_OUTPUT_DIR}/${output_subdir}/${IMAGE_BASENAME}/${IMAGE_NAME}"
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
    echo -e "${CYAN}║      Feasycom 模组测试镜像编译工具 v1.0       ║${NC}"
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

    # 5. 编译前配置确认
    confirm_config

    # 6. 更新 Submodules
    update_submodules

    # 7. 编译前准备
    prepare_build

    # 8. 生成镜像名
    generate_image_name

    # 9. 执行编译
    run_build

    # 10. 复制镜像
    copy_image

    # 11. 生成构建记录 (build_info.txt + build_info.diff)
    generate_build_info

    # 12. 生成编译报告
    generate_build_report

    # 13. 显示结果摘要
    show_summary

    # 14. 计算执行时间
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    
    log_info "总耗时: ${minutes}分${seconds}秒"
}

# ===================== 脚本入口 =====================
main "$@"
