#!/bin/bash
# =============================================================================
# feasy_template.sh - 模组项目快速克隆/删除脚本 (v1.4)
# 功能：按源项目拷贝 Android 工程目录，同步 u-boot/kernel 配置文件，并更新 AndroidProducts.mk
# 替换规则：工程文件中的源项目名改为目标名；#include / /include/ 行保持原样
# =============================================================================

set -uo pipefail

# ===================== Core Configuration (Exact match with your paths) =====================
SCRIPT_VERSION="1.4"
RK_BASE_DIR="device/rockchip/rk356x"
UBOOT_DTS_BASE="u-boot/arch/arm/dts"
UBOOT_DEFCONFIG_BASE="u-boot/configs"
KERNEL_DTS_BASE="kernel/arch/arm64/boot/dts/rockchip"
KERNEL_CONFIG_BASE="kernel/arch/arm64/configs"

# ===================== Usage Instructions =====================
usage() {
    echo "feasy_template.sh v${SCRIPT_VERSION}"
    echo "Usage: $0 <command> <source_project> <target_project>"
    echo "Commands:"
    echo "  clone   - Clone <source_project> as <target_project> (requires 3 params)"
    echo "  delete  - Delete <project> (requires 2 params)"
    echo "Examples:"
    echo "  $0 clone ok3568_r bw2231    # Clone ok3568_r as bw2231"
    echo "  $0 delete bw2231            # Remove bw2231 project"
    exit 1
}

# ===================== Safe Path Check (Warning only, no exit) =====================
safe_path_check() {
    local path="$1"
    local type="$2"
    if [[ "$type" == "dir" && ! -d "$path" ]]; then
        echo "WARNING: Directory not exist → $path"
        return 1
    elif [[ "$type" == "file" && ! -f "$path" ]]; then
        echo "WARNING: File not exist → $path"
        return 1
    fi
    return 0
}

# ===================== Case-Insensitive Path Resolution =====================
# Find the actual (case-variant) name of a directory under a parent
# Returns the actual basename, or empty string if not found
find_actual_dirname() {
    local parent="$1"
    local name="$2"
    local result
    result=$(find "$parent" -maxdepth 1 -iname "$name" -type d -print -quit 2>/dev/null)
    if [[ -n "$result" ]]; then
        basename "$result"
    fi
}

# Find the actual full path of a file under a parent, case-insensitive
# Returns the full path, or empty string if not found
find_actual_filepath() {
    local parent="$1"
    local name="$2"
    find "$parent" -maxdepth 1 -iname "$name" -type f -print -quit 2>/dev/null
}

# Collect unique source project identifiers (longest first for safe replacement)
collect_source_identifiers() {
    local source_actual_name="$1"
    local source_upper="$2"
    local -a candidates=()
    local name

    for name in "$source_actual_name" "$source_upper" \
                "$(echo "$source_actual_name" | tr '[:lower:]' '[:upper:]')" \
                "$(echo "$source_actual_name" | tr '[:upper:]' '[:lower:]')" \
                "$(echo "$source_upper" | tr '[:lower:]' '[:upper:]')" \
                "$(echo "$source_upper" | tr '[:upper:]' '[:lower:]')"; do
        [[ -n "$name" ]] && candidates+=("$name")
    done

    # Deduplicate while preserving longest-first order
    local -a unique=()
    local candidate existing
    for candidate in "${candidates[@]}"; do
        local duplicate=0
        for existing in "${unique[@]}"; do
            if [[ "$candidate" == "$existing" ]]; then
                duplicate=1
                break
            fi
        done
        [[ $duplicate -eq 0 ]] && unique+=("$candidate")
    done

    # Sort by length descending (longest match first)
    local -a sorted=()
    local max_len len
    local -a remaining=("${unique[@]}")
    while [[ ${#remaining[@]} -gt 0 ]]; do
        max_len=0
        local longest=""
        local -a next_remaining=()
        for candidate in "${remaining[@]}"; do
            len=${#candidate}
            if [[ $len -gt $max_len ]]; then
                max_len=$len
                longest="$candidate"
            fi
        done
        sorted+=("$longest")
        for candidate in "${remaining[@]}"; do
            [[ "$candidate" != "$longest" ]] && next_remaining+=("$candidate")
        done
        remaining=("${next_remaining[@]}")
    done

    printf '%s\n' "${sorted[@]}"
}

# Replace source project identifiers with target in a single text file.
# #include / /include/ lines are left untouched: cloning only renames the
# project's own files, so included headers such as .dtsi still exist only
# under the source name and must keep pointing there.
replace_project_identifiers_in_file() {
    local file="$1"
    local target_proj="$2"
    shift 2
    local -a source_ids=("$@")
    local tmp_file="${file}.feasy_template.tmp"

    [[ -f "$file" ]] || return 0
    [[ ${#source_ids[@]} -eq 0 ]] && return 0

    FEASY_SOURCE_IDS="$(printf '%s\n' "${source_ids[@]}")" \
    awk -v target="$target_proj" '
    function lit_replace(s, from, to,    out, idx) {
        out = ""
        while ((idx = index(s, from)) > 0) {
            out = out substr(s, 1, idx - 1) to
            s = substr(s, idx + length(from))
        }
        return out s
    }
    BEGIN {
        n = 0
        cnt = split(ENVIRON["FEASY_SOURCE_IDS"], raw, "\n")
        for (i = 1; i <= cnt; i++) {
            if (raw[i] != "" && raw[i] != target) id[++n] = raw[i]
        }
    }
    {
        line = $0
        if (line ~ /^[[:space:]]*#[[:space:]]*include/ || line ~ /^[[:space:]]*\/include\//) {
            print line
            next
        }
        for (i = 1; i <= n; i++) line = lit_replace(line, id[i], target)
        print line
    }
    ' "$file" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }

    mv "$tmp_file" "$file"
}

# Replace identifiers across all common text files under a project directory
replace_project_identifiers_in_tree() {
    local root_dir="$1"
    local target_proj="$2"
    shift 2
    local -a source_ids=("$@")

    [[ -d "$root_dir" ]] || return 0

    while IFS= read -r -d '' file; do
        replace_project_identifiers_in_file "$file" "$target_proj" "${source_ids[@]}"
    done < <(find "$root_dir" -type f \( \
        -name "*.mk" -o -name "*.xml" -o -name "*.rc" -o -name "*.te" -o \
        -name "*.cfg" -o -name "*.conf" -o -name "*.prop" -o -name "*.sh" -o \
        -name "*.txt" -o -name "*.json" -o -name "*.bp" -o -name "*.dts" -o \
        -name "*.dtsi" -o -name "*.ini" -o -name "*.hal" \
    \) -print0 2>/dev/null)
}

# Copy a config file and replace embedded source project references
copy_with_project_identifiers() {
    local src="$1"
    local dst="$2"
    local target_proj="$3"
    shift 3
    local -a source_ids=("$@")

    cp "$src" "$dst" || return 1
    replace_project_identifiers_in_file "$dst" "$target_proj" "${source_ids[@]}"
}

# ===================== Global AndroidProducts.mk Management =====================
GLOBAL_ANDPROD_MK="${RK_BASE_DIR}/AndroidProducts.mk"

# Add project entries to global AndroidProducts.mk (used in clone)
add_to_global_android_products() {
    local target_proj="$1"
    local temp_file="${GLOBAL_ANDPROD_MK}.tmp"
    local product_processed=0
    local lunch_processed=0

    if [ ! -f "$GLOBAL_ANDPROD_MK" ]; then
        echo "ERROR: Global AndroidProducts.mk not found → $GLOBAL_ANDPROD_MK"
        return 1
    fi

    > "$temp_file"
    while IFS= read -r line; do
        echo "$line" >> "$temp_file"

        if [ $product_processed -eq 0 ]; then
            if echo "$line" | grep -qF 'PRODUCT_MAKEFILES := \'; then
                echo "    \$(LOCAL_DIR)/${target_proj}/${target_proj}.mk \\" >> "$temp_file"
                product_processed=1
            fi
        fi

        if [ $lunch_processed -eq 0 ]; then
            if echo "$line" | grep -qF 'COMMON_LUNCH_CHOICES := \'; then
                echo "    ${target_proj}-userdebug \\" >> "$temp_file"
                lunch_processed=1
            fi
        fi
    done < "$GLOBAL_ANDPROD_MK"

    mv "$temp_file" "$GLOBAL_ANDPROD_MK"
    rm -f "$temp_file" 2>/dev/null

    # Verification
    local makefile_entry='$(LOCAL_DIR)/'"$target_proj"'/'"$target_proj"'.mk'
    local lunch_entry="$target_proj-userdebug"
    if grep -qF "$makefile_entry" "$GLOBAL_ANDPROD_MK" && grep -qF "$lunch_entry" "$GLOBAL_ANDPROD_MK"; then
        echo "INFO: Global AndroidProducts.mk updated with ${target_proj} entries"
    else
        echo "WARNING: Verification of global AndroidProducts.mk may have failed"
        grep -n "$target_proj" "$GLOBAL_ANDPROD_MK" 2>/dev/null || true
    fi
}

# Remove project entries from global AndroidProducts.mk (used in delete)
remove_from_global_android_products() {
    local target_proj="$1"
    local temp_file="${GLOBAL_ANDPROD_MK}.tmp"
    local makefile_entry='$(LOCAL_DIR)/'"$target_proj"'/'"$target_proj"'.mk'
    local lunch_entry="$target_proj-userdebug"

    if [ ! -f "$GLOBAL_ANDPROD_MK" ]; then
        echo "ERROR: Global AndroidProducts.mk not found → $GLOBAL_ANDPROD_MK"
        return 1
    fi

    cp "$GLOBAL_ANDPROD_MK" "${GLOBAL_ANDPROD_MK}.bak"
    > "$temp_file"
    while IFS= read -r line; do
        if echo "$line" | grep -qF "$makefile_entry" || echo "$line" | grep -qF "$lunch_entry"; then
            continue
        fi
        echo "$line" >> "$temp_file"
    done < "$GLOBAL_ANDPROD_MK"

    mv "$temp_file" "$GLOBAL_ANDPROD_MK"
    rm -f "$temp_file" 2>/dev/null

    # Verification
    if ! grep -qF "$makefile_entry" "$GLOBAL_ANDPROD_MK" && ! grep -qF "$lunch_entry" "$GLOBAL_ANDPROD_MK"; then
        echo "INFO: ${target_proj} entries removed from global AndroidProducts.mk"
    else
        echo "WARNING: Some ${target_proj} entries may remain in global AndroidProducts.mk"
        grep -n "$target_proj" "$GLOBAL_ANDPROD_MK" 2>/dev/null || true
    fi
}

# ===================== Clone Project (Check first, then execute) =====================
clone_project() {
    local target_proj="$1"
    local source_proj="$2"

    # ========== Phase 1: Validate all prerequisites ==========
    echo "feasy_template.sh v${SCRIPT_VERSION}"
    echo "========== Phase 1: Validation =========="

    # 1. Resolve source directory (case-insensitive)
    local source_actual_name=$(find_actual_dirname "$RK_BASE_DIR" "$source_proj")
    if [[ -z "$source_actual_name" ]]; then
        echo "ERROR: Source directory not found for '$source_proj' under $RK_BASE_DIR"
        return 1
    fi
    local source_dir="${RK_BASE_DIR}/${source_actual_name}"
    echo "[OK] Source directory → ${source_dir}"

    # 2. Check source BoardConfig.mk and extract board identifier
    local source_board_config="${source_dir}/BoardConfig.mk"
    if [[ ! -f "$source_board_config" ]]; then
        echo "ERROR: BoardConfig.mk not found → $source_board_config"
        return 1
    fi
    local source_upper
    source_upper=$(grep -E "^PRODUCT_UBOOT_CONFIG :=" "$source_board_config" | awk -F':=' '{print $2}' | tr -d ' ')
    [[ -z "$source_upper" ]] && source_upper="${source_actual_name}"
    echo "[OK] Board identifier → ${source_upper}"

    # 3. Validate source files exist (record actual paths, non-fatal if missing)
    local uboot_dts_src=$(find_actual_filepath "$UBOOT_DTS_BASE" "${source_upper}.dts")
    local uboot_defconfig_src=$(find_actual_filepath "$UBOOT_DEFCONFIG_BASE" "${source_upper}_defconfig")
    local kernel_dts_src=$(find_actual_filepath "$KERNEL_DTS_BASE" "${source_upper}-android.dts")
    local kernel_defconfig_src=$(find_actual_filepath "$KERNEL_CONFIG_BASE" "${source_upper}-android_defconfig")
    local kernel_dts_tmp_domain_src=$(find_actual_filepath "$KERNEL_DTS_BASE" ".${source_upper}-android.dtb.dts.tmp.domain")
    [[ -n "$uboot_dts_src" ]] && echo "[OK] u-boot DTS → $(basename $uboot_dts_src)" || echo "[INFO] u-boot DTS will be skipped (not found)"
    [[ -n "$uboot_defconfig_src" ]] && echo "[OK] u-boot defconfig → $(basename $uboot_defconfig_src)" || echo "[INFO] u-boot defconfig will be skipped (not found)"
    [[ -n "$kernel_dts_src" ]] && echo "[OK] kernel DTS → $(basename $kernel_dts_src)" || echo "[INFO] kernel DTS will be skipped (not found)"
    [[ -n "$kernel_defconfig_src" ]] && echo "[OK] kernel defconfig → $(basename $kernel_defconfig_src)" || echo "[INFO] kernel defconfig will be skipped (not found)"
    [[ -n "$kernel_dts_tmp_domain_src" ]] && echo "[OK] kernel DTS tmp domain → $(basename $kernel_dts_tmp_domain_src)" || echo "[INFO] kernel DTS tmp domain will be skipped (not found)"

    # 4. Check if target project directory already exists
    local target_dir="${RK_BASE_DIR}/${target_proj}"
    if [[ -d "$target_dir" ]]; then
        echo ""
        echo "WARNING: 目标项目目录已存在: ${target_dir}"
        echo -n "是否覆盖? [y/N] "
        read -r confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "INFO: 操作已取消"
            return 1
        fi
    fi
    echo "[OK] Target project → ${target_proj}"

    # 5. Check global AndroidProducts.mk exists
    if [[ ! -f "$GLOBAL_ANDPROD_MK" ]]; then
        echo "ERROR: Global AndroidProducts.mk not found → $GLOBAL_ANDPROD_MK"
        return 1
    fi
    echo "[OK] Global AndroidProducts.mk exists"

    # ========== Phase 2: Execute all operations ==========
    echo ""
    echo "========== Phase 2: Execution =========="

    local -a source_ids=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && source_ids+=("$line")
    done < <(collect_source_identifiers "$source_actual_name" "$source_upper")

    # Copy source directory to target
    echo "[1/5] Copying ${source_actual_name} → ${target_proj}"
    rm -rf "$target_dir" 2>/dev/null
    cp -r "$source_dir" "$target_dir" || { echo "ERROR: Failed to copy source directory"; return 1; }

    # Replace project identifiers in all project text files
    echo "[2/5] Updating project file references"
    replace_project_identifiers_in_tree "$target_dir" "$target_proj" "${source_ids[@]}"

    if [[ -f "${target_dir}/${source_actual_name}.mk" ]]; then
        mv "${target_dir}/${source_actual_name}.mk" "${target_dir}/${target_proj}.mk" 2>/dev/null
    fi

    # Copy u-boot/kernel config files and replace embedded references
    echo "[3/5] Copying u-boot/kernel config files"
    [[ -n "$uboot_dts_src" ]] && copy_with_project_identifiers "$uboot_dts_src" "${UBOOT_DTS_BASE}/${target_proj}.dts" "$target_proj" "${source_ids[@]}"
    [[ -n "$uboot_defconfig_src" ]] && copy_with_project_identifiers "$uboot_defconfig_src" "${UBOOT_DEFCONFIG_BASE}/${target_proj}_defconfig" "$target_proj" "${source_ids[@]}"
    [[ -n "$kernel_dts_src" ]] && copy_with_project_identifiers "$kernel_dts_src" "${KERNEL_DTS_BASE}/${target_proj}-android.dts" "$target_proj" "${source_ids[@]}"
    [[ -n "$kernel_defconfig_src" ]] && copy_with_project_identifiers "$kernel_defconfig_src" "${KERNEL_CONFIG_BASE}/${target_proj}-android_defconfig" "$target_proj" "${source_ids[@]}"
    [[ -n "$kernel_dts_tmp_domain_src" ]] && copy_with_project_identifiers "$kernel_dts_tmp_domain_src" "${KERNEL_DTS_BASE}/.${target_proj}-android.dtb.dts.tmp.domain" "$target_proj" "${source_ids[@]}"

    # Append BSP metadata to .mk file
    echo "[4/5] Appending BSP metadata"
    if ! grep -q "PRODUCT_CUSTOM_CHIP" "${target_dir}/${target_proj}.mk" 2>/dev/null; then
        {
            echo ""
            echo "# ================= Feasycom 模组 BSP 发布配置 ================="
            echo "# 用户可在此处自定义项目相关的元数据字段，按需修改或增删，这些会影响生成镜像的名字，便于后续自动化编译和上传固件"
            echo "PRODUCT_CUSTOM_CHIP := RK3568"
            echo "PRODUCT_SYSTEM_PLATFORM := A11"
            echo "PRODUCT_CHIPSET_NAME := ATBM6165"
            echo "PRODUCT_CUSTOM_VERSION := V1.0.0"
            echo "# ============================================================"
        } >> "${target_dir}/${target_proj}.mk" 2>/dev/null
    fi

    # Add entries to global AndroidProducts.mk
    echo "[5/5] Updating global AndroidProducts.mk"
    add_to_global_android_products "$target_proj"

    echo ""
    echo "SUCCESS: Project ${target_proj} cloned successfully!"
}

# ===================== Delete Project (Delete files + Remove entries) =====================
delete_project() {
    local target_proj="$1"

    echo "feasy_template.sh v${SCRIPT_VERSION}"

    # 0. Remove entries from global AndroidProducts.mk
    remove_from_global_android_products "$target_proj"

    # 1. Delete project directory (case-insensitive match)
    echo "[2/5] Deleting project directory"
    local actual_name=$(find_actual_dirname "$RK_BASE_DIR" "$target_proj")
    if [[ -n "$actual_name" ]]; then
        rm -rf "${RK_BASE_DIR}/${actual_name}" || echo "WARNING: Failed to delete project directory"
    else
        echo "INFO: Project directory not found, skipping"
    fi

    # 2. Delete u-boot DTS (case-insensitive match)
    echo "[3/5] Deleting u-boot DTS file"
    local actual_file=$(find_actual_filepath "$UBOOT_DTS_BASE" "${target_proj}.dts")
    if [[ -n "$actual_file" ]]; then
        rm -f "$actual_file" || echo "WARNING: Failed to delete u-boot DTS"
    else
        echo "INFO: u-boot DTS not found, skipping"
    fi

    # 3. Delete u-boot defconfig (case-insensitive match)
    echo "[4/5] Deleting u-boot defconfig file"
    actual_file=$(find_actual_filepath "$UBOOT_DEFCONFIG_BASE" "${target_proj}_defconfig")
    if [[ -n "$actual_file" ]]; then
        rm -f "$actual_file" || echo "WARNING: Failed to delete u-boot defconfig"
    else
        echo "INFO: u-boot defconfig not found, skipping"
    fi

    # 4-5. Delete kernel DTS and defconfig (case-insensitive match)
    echo "[5/5] Deleting kernel files"
    actual_file=$(find_actual_filepath "$KERNEL_DTS_BASE" "${target_proj}-android.dts")
    if [[ -n "$actual_file" ]]; then
        rm -f "$actual_file" || echo "WARNING: Failed to delete kernel DTS"
    else
        echo "INFO: kernel DTS not found, skipping"
    fi
    actual_file=$(find_actual_filepath "$KERNEL_CONFIG_BASE" "${target_proj}-android_defconfig")
    if [[ -n "$actual_file" ]]; then
        rm -f "$actual_file" || echo "WARNING: Failed to delete kernel defconfig"
    else
        echo "INFO: kernel defconfig not found, skipping"
    fi

    # Deletes kernel DTS tmp domain file (case-insensitive)
    actual_file=$(find_actual_filepath "$KERNEL_DTS_BASE" ".${target_proj}-android.dtb.dts.tmp.domain")
    if [[ -n "$actual_file" ]]; then
        rm -f "$actual_file" || echo "WARNING: Failed to delete kernel DTS tmp domain"
    else
        echo "INFO: kernel DTS tmp domain not found, skipping"
    fi

    echo -e "\nSUCCESS: Project ${target_proj} deleted successfully!"
}

# ===================== Main Logic =====================
main() {
    if [[ $# -lt 2 || $# -gt 3 ]]; then
        echo "ERROR: Invalid parameter count!"
        usage
    fi

    local cmd="$1"
    # Normalize all project names to lowercase (case-insensitive input)
    local source_proj=$(echo "$2" | tr '[:upper:]' '[:lower:]')
    local target_proj=""

    if [[ "$cmd" == "clone" ]]; then
        if [[ -z "$3" ]]; then
            echo "ERROR: Clone requires target project name (3rd parameter)!"
            usage
        fi
        target_proj=$(echo "$3" | tr '[:upper:]' '[:lower:]')
        clone_project "$target_proj" "$source_proj"
    elif [[ "$cmd" == "delete" ]]; then
        delete_project "$source_proj"
    else
        echo "ERROR: Invalid command! Only 'clone' or 'delete' allowed"
        usage
    fi
}

main "$@"
