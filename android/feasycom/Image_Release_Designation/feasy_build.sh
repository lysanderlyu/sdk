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
        PRODUCT_SYSTEM_PLATFORM := A11
        PRODUCT_CHIPSET_NAME := ATBM6165
        PRODUCT_CUSTOM_VERSION := V1.0.0

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
                MODULE_NAME="$(echo "$2" | tr '[:lower:]' '[:upper:]')"
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
    
    # 3. 检查设备配置文件是否存在
    local device_mk_path="${SDK_ROOT_DIR}/${DEVICE_BASE_PATH}/${MODULE_NAME}/${MODULE_NAME}.mk"
    if [[ ! -f "$device_mk_path" ]]; then
        log_error "未找到设备配置文件: $device_mk_path"
        log_error "请确认模组型号 '$MODULE_NAME' 是否正确，或创建对应的配置文件"
        exit 1
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
    log_info "检查 Git 仓库状态..."
    
    cd "$SDK_ROOT_DIR"
    
    # 检查是否有未提交的修改
    if ! git diff --quiet HEAD; then
        log_error "存在未提交的修改！Release 模式禁止使用未提交的代码编译固件"
        log_error "请先提交或暂存所有修改后再编译 Release 版本"
        echo ""
        echo "未提交的文件:"
        git status --short
        exit 1
    fi
    
    # 检查是否有未跟踪的文件
    local untracked_files
    untracked_files=$(git ls-files --others --exclude-standard)
    if [[ -n "$untracked_files" ]]; then
        log_warn "存在未跟踪的文件，建议检查是否需要纳入版本控制"
        if [[ "$VERBOSE" == true ]]; then
            echo "$untracked_files"
        fi
    fi
    
    log_info "Git 仓库状态检查通过"
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
    
    # 从设备配置文件中提取配置
    PRODUCT_CUSTOM_CHIP=$(grep -E "^PRODUCT_CUSTOM_CHIP\s*:=" "$device_mk_path" 2>/dev/null | awk '{print $3}' || echo "RK3568")
    PRODUCT_SYSTEM_PLATFORM=$(grep -E "^PRODUCT_SYSTEM_PLATFORM\s*:=" "$device_mk_path" 2>/dev/null | awk '{print $3}' || echo "A11")
    PRODUCT_CHIPSET_NAME=$(grep -E "^PRODUCT_CHIPSET_NAME\s*:=" "$device_mk_path" 2>/dev/null | awk '{print $3}' || echo "ATBM6165")
    PRODUCT_CUSTOM_VERSION=$(grep -E "^PRODUCT_CUSTOM_VERSION\s*:=" "$device_mk_path" 2>/dev/null | awk '{print $3}' || echo "V1.0.0")

    log_info "自定义芯片: $PRODUCT_CUSTOM_CHIP"
    log_info "系统平台: $PRODUCT_SYSTEM_PLATFORM"
    log_info "模组芯片: $PRODUCT_CHIPSET_NAME"
    log_info "版本号: $PRODUCT_CUSTOM_VERSION"
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
        IMAGE_NAME="${chip}_${platform}_${chipset}_${MODULE_NAME}_${version}_${build_type_capital}_${BUILD_DATE}.${BUILD_TIME}.img"
    else
        build_type_capital="Release"
        IMAGE_NAME="${chip}_${platform}_${chipset}_${MODULE_NAME}_${version}_${build_type_capital}_${BUILD_DATE}_${GIT_HASH}.img"
    fi
    
    log_info "镜像名: $IMAGE_NAME"
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
    
    local output_dir="${IMAGES_OUTPUT_DIR}/${output_subdir}"
    mkdir -p "$output_dir"
    
    log_info "输出目录: $output_dir"
    
    # 查找编译生成的镜像文件
    # 路径格式: IMAGE/RK356X_<模组型号>_<日期>.<时间>/IMAGES/RK356X_<模组型号>_<日期>.<时间>-update.img
    # 取该模组最新编译生成的镜像（按目录名排序取最新）
    local module_image_dir
    module_image_dir=$(find "${SDK_ROOT_DIR}/IMAGE" -maxdepth 1 -type d -name "RK356X_${MODULE_NAME}_*" 2>/dev/null | sort | tail -1)
    
    if [[ -z "$module_image_dir" ]]; then
        log_error "未找到模组 '$MODULE_NAME' 的编译输出目录: ${SDK_ROOT_DIR}/IMAGE/RK356X_${MODULE_NAME}_*"
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

# ===================== 生成编译报告 =====================
generate_build_report() {
    log_step "生成编译报告"
    
    local output_subdir
    if [[ "$BUILD_TYPE" == "debug" ]]; then
        output_subdir="DEBUG"
    else
        output_subdir="RELEASE"
    fi
    
    local report_file="${IMAGES_OUTPUT_DIR}/${output_subdir}/build_report_${BUILD_DATE}_${BUILD_TIME}.txt"
    
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
    echo "  镜像文件:     ${IMAGES_OUTPUT_DIR}/${output_subdir}/${IMAGE_NAME}"
    echo "  Git 哈希:     $GIT_HASH"
    echo ""
    echo -e "${YELLOW}  上传命令:${NC}"
    echo "  feasy_upload.sh ${IMAGES_OUTPUT_DIR}/${output_subdir}/${IMAGE_NAME}"
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
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      Feasycom 模组测试镜像编译工具       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    
    # 注册清理函数
    trap cleanup EXIT
    
    # 1. 解析参数
    parse_args "$@"
    
    # 2. 环境检查
    check_environment
    
    # 3. 获取版本信息
    get_version_info
    
    # 4. 更新 Submodules
    update_submodules
    
    # 5. 编译前准备
    prepare_build
    
    # 6. 生成镜像名
    generate_image_name
    
    # 7. 执行编译
    run_build
    
    # 8. 复制镜像
    copy_image
    
    # 9. 生成编译报告
    generate_build_report
    
    # 10. 显示结果摘要
    show_summary
    
    # 11. 计算执行时间
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    
    log_info "总耗时: ${minutes}分${seconds}秒"
}

# ===================== 脚本入口 =====================
main "$@"
