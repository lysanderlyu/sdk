模组测试镜像发布管控规范设计

# 查阅权限：
## 要求

- 系统开发组部门具有可读可写的权限
- 其他部门成员只读权限，可以浏览下载镜像

## 方案

1. 开发组账号对固件发布目录可读可写
2. 其他人员账号对固件发布目录只可读


# 镜像命名：
## 要求

- 镜像名应带有一些必要字段，能让部门成员看镜像名就知道什么平台什么项目
- 镜像和源码应有明确的对应关系，能双向反查对应，看镜像能知道哪个源码

## 方案

1. 对于Debug调试版镜像名采用以下方式:
```txt
[项目主控_芯片组]_[系统平台]_[模组芯片]_[模组型号]_[版本号]_Debug_[年月日].[时分].img
```

2. 对于Release发行版镜像名采用以下方式:
```txt
[项目主控_芯片组]_[系统平台]_[模组芯片]_[模组型号]_[版本号]_Release_[年月日]_[Git哈希].img
```


# 发行说明：
## 要求

- 镜像版本发布应配套带有方便查阅版本差异的`Release Notes`

## 方案

1. `Release Notes文件格式`：目的是方便简洁查看发行版之间的差异，文本格式最好使用行内较为成熟的`Keep In Change`的`Markdown`格式
2. `Release Notes文件名规范`： Release Notes 文件名统一使用 `CHANGELOG.md`
3. `Release Notes文件路径`：除了镜像.zip压缩包同级目录存放这一个全局的Release Notes，每一个单独的压缩包内部应当在打包img时同时打包一个只全局CHANGELOG.md，目的是当发送zip镜像包时解包能看到CHANGELOG.md，在FTP浏览镜像时也能通过zip同级目录有个CHANGELOG.md查阅。

### 发行说明放置位置参考
对于`RK3568_A11_ATBM6165_BW8205_V1.0.0_Release_20260626_ab012388e4.zip` 和 `RK3568_A11_ATBM6165_BW8205_V1.0.0_Debug_20260626.0900.zip` 有以下存储规则

```txt
FTP/
├── RK3568_A11
│   ├── ATBM6165_Series
│   │   ├── BW8205
│   │   │   ├── Debug
│   │   │   │   ├── V1.0.0_20260625_1820
│   │   │   │   ├── V1.0.0_20260626_0900
│   │   │   │   │   ├── CHANGELOG.md
│   │   │   │   │   ├── RK3568_A11_ATBM6165_BW8205_V1.0.0_Debug_20260626.0900.zip
│   │   │   │   │   └── upload_report.txt
│   │   │   │   └── CHANGELOG.md
│   │   │   └── Release
│   │   │       ├── V1.0.0_20260626_ab012388e4
│   │   │       │   ├── CHANGELOG.md
│   │   │       │   ├── RK3568_A11_ATBM6165_BW8205_V1.0.0_Release_20260626_ab012388e4.zip
│   │   │       │   └── upload_report.txt
│   │   │       └── CHANGELOG.md
│   │   └── RTL8821CS_Series
│   │       └── BW121
│   ├── RK3568_Ubuntu2204
│   └── RK3588_A11
```

- RK3568_A11_ATBM6165_BW8205_V1.0.0_Release_20260625_ab012388e4.zip里面的内容应当是这样的:

```plain
── RK3568_A11_ATBM6165_BW8205_V1.0.1_Release_20260626_a0400dedca.zip
   ├── CHANGELOG.md
   └── RK3568_A11_ATBM6165_BW8205_V1.0.1_Release_20260626_a0400dedca.img
```

### 发行说明内容参考

- 版本说明是**每个版本追加模式**，如果现在FTP上该机型BSP发布是首次，那就新建一个CHANGELOG.md文件。
- 在执行自动上传固件脚本`feasy_upload.sh`时，脚本会提示先完善本次发行的Release内容，模板由脚本自动补全。
- 模板中的 **编译时间（Build）** 由脚本从镜像文件名自动解析（Debug 镜像的 `YYYYMMDD.HHMM` / Release 镜像的 `YYYYMMDD`），**上传时间（Upload）** 由脚本执行时的当前时间自动填充。两个时间分离记录，避免编译到上传的时间窗口被掩盖，同时也便于校对镜像文件名的合法性。

```md
# Release Notes

## [v1.2.0] 2026-06-26 09:15

> **Build:** 2026-06-25 17:23
> **Upload:** 2026-06-26 09:15

### Added
- RK3568-C 新增 ATBM6165 WiFi6 驱动支持
- 支持 OTA 增量包生成（target-files-package）

### Changed
- WiFi 固件加载方式由 C 数组改为文件系统加载（Kconfig ATBM_USE_FIRMWARE_BIN_WIFI6）
- Buildroot rootfs 升级至 gcc 13.2

### Fixed
- I2C2 时钟配置导致触控间歇性无响应
- WiFi 漫游时 KVR 协议栈下 SDIO 超时

### Known Issues
- PCIe ASPM L1 深度休眠唤醒后 WiFi 重连需 3s+

## [v1.1.0] 2026-06-25 14:30

> **Build:** 2026-06-24 11:05
> **Upload:** 2026-06-25 14:30

### Added
- RK3568-C 新增 ATBM6165 WiFi6 驱动支持
- 支持 OTA 增量包生成（target-files-package）

### Changed
- WiFi 固件加载方式由 C 数组改为文件系统加载（Kconfig ATBM_USE_FIRMWARE_BIN_WIFI6）
- Buildroot rootfs 升级至 gcc 13.2

### Fixed
- I2C2 时钟配置导致触控间歇性无响应
- WiFi 漫游时 KVR 协议栈下 SDIO 超时

### Known Issues
- PCIe ASPM L1 深度休眠唤醒后 WiFi 重连需 3s+
```

# FTP目录：
## 要求

- 镜像的查找检索应该简洁明了，能让各部门一眼就能知道某个模组平台的对应BSP镜像去哪拿
- 镜像的发布应该区分调试版本和正式版本

## 方案
对于当前需求，主要是区分1.SOC芯片，2.OS系统，3.模组芯片，以及4.镜像类型，可以考虑使用以下目录结构

```plain
FTP/
├── RK3568_A11
│   ├── ATBM6165_Series
│   │   ├── BW8205
│   │   │   ├── Debug
│   │   │   │   ├── V1.0.0_20260625_1820
│   │   │   │   ├── V1.0.0_20260626_0900
│   │   │   │   │   ├── CHANGELOG.md
│   │   │   │   │   ├── RK3568_A11_ATBM6165_BW8205_V1.0.0_Debug_20260626.0900.zip
│   │   │   │   │   └── upload_report.txt
│   │   │   │   └── CHANGELOG.md
│   │   │   └── Release
│   │   │       ├── V1.0.0_20260626_ab012388e4
│   │   │       │   ├── CHANGELOG.md
│   │   │       │   ├── RK3568_A11_ATBM6165_BW8205_V1.0.0_Release_20260626_ab012388e4.zip
│   │   │       │   └── upload_report.txt
│   │   │       └── CHANGELOG.md
│   │   └── RTL8821CS_Series
│   │       └── BW121
│   ├── RK3568_Ubuntu2204
│   └── RK3588_A11
```


# 自动化发布：
## 要求

- 应有`feasy_build.sh`自动化脚本生成固件，为了方便和RK平台兼容性，`feasy_build.sh`构建脚本沿用RK官方`build.sh`编译打包镜像操作，`feasy_build.sh`脚本只用于快速发布固件，避免人为编译发行版时生成了有本地修改但未提交git记录的源码生成的固件
- 应有`feasy_upload.sh`自动化脚本上传固件，并由专门的测试人员负责上传动作
- 对于编译固件，应有一个`build_info.txt`文件记录固件构建情况。


## 方案

### 自动化脚本生成固件

`feasy_build.sh` 脚本应具有以下操作

| 示例 | 具体内容 | 脚本结果 |
| --------------- | --------------- | --------------- |
| `feasy_build.sh -h` | 显示脚本使用说明 | 打印当前脚本用法、镜像命名规范、配置要求 |
| `feasy_build.sh -m BW8205` | source，lunch BW8205，`build.sh -UKAup` 集为一体便捷版（默认Debug模式） | 结果和原生 `./build.sh -UKAup` 相同，生成Debug镜像到 `IMAGES/DEBUG/` |
| `feasy_build.sh -m BW8205 -d` | 编译并生成Debug调试固件以及当前工作目录的git diff记录文件 | 在 `IMAGES/DEBUG/RK3568_A11_ATBM6165_BW8205_V1.0.0_Debug_20260625.1343` 下生成 `RK3568_A11_ATBM6165_BW8205_V1.0.0_Debug_20260625.1343.img` 并生成编译报告|
| `feasy_build.sh -m BW8205 -r` | 编译并生成Release发行版固件，检查Git未提交的修改 | 在 `IMAGES/RELEASE/RK3568_A11_ATBM6165_BW8205_V1.0.0_Release_20260625_ab012388e4/` 下生成 `RK3568_A11_ATBM6165_BW8205_V1.0.0_Release_20260625_ab012388e4.img` |
| `feasy_build.sh -m BW8205 -c -u` | 先 clean 再更新 submodules 后编译 | 清理构建产物后拉取最新submodules再执行编译流程 |
| `feasy_build.sh -m BW8205 -d -v` | Debug编译 + 详细输出模式 | 编译过程中输出更多调试信息，便于排查编译问题 |

- 为了适配自动化生成脚本生成正确的固件名，比如自动获取 1.SoC平台，2. OS平台，3.模组芯片类型，4.版本号，这四个信息的定义需要在`[device].mk`中新增四行，用于给`feasy_build.sh`脚本动态获取:

```makefile

# ================= Feasycom 模组 BSP 发布配置 =================
PRODUCT_CUSTOM_CHIP := RK3568
PRODUCT_SYSTEM_PLATFORM := A11
PRODUCT_CHIPSET_NAME := ATBM6165
PRODUCT_CUSTOM_VERSION := V1.1.0
# ====================================================
```

- 为了记录执行脚本时的代码情况，对于Debug固件编译，虽然不检查当前git工作目录是否干净，但也需要记录下当前的git diff，上传镜像时应当把这个diff一同上传，与`upload_report.txt`同级目录。对于Release固件编译，必须严格当前Git工作目录是干净的，不允许有未提交的代码编译Release固件。以下是build_info.diff参考内容

```bash
BUILD_ID=$(date -u +%Y%m%d-%H%M%S)
COMMIT=$(git rev-parse HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
DIRTY=$(git status --porcelain | wc -l)

# Include full diff + untracked files if dirty
if [ -n "$(git status --porcelain)" ]; then
    # Tracked file changes
    git diff HEAD > build_info.diff

    # Untracked files
    UNTRACKED=$(git ls-files --others --exclude-standard)
    if [ -n "$UNTRACKED" ]; then
        echo "" >> build_info.diff
        echo "=== UNTRACKED FILES ===" >> build_info.diff
        echo "$UNTRACKED" >> build_info.diff
        echo "=== CONTENTS ===" >> build_info.diff
        echo "$UNTRACKED" | while IFS= read -r f; do
            echo "--- $f ---" >> build_info.diff
            cat "$f" 2>/dev/null >> build_info.diff || echo "[binary or missing]" >> build_info.diff
            echo "" >> build_info.diff
        done
    fi
fi
```

> 以下是脚本执行案例 

![镜像开始编译](http://106.55.165.251:9000/images/2026/06/80cf8d04cf1e706f3f5fbfb398bfdb8d.png)
![镜像生成案例](http://106.55.165.251:9000/images/2026/06/1808125cb9ebe724bc6e924a8065895d.png)
![镜像开始编译](http://106.55.165.251:9000/images/2026/06/33ea173d20e4141618ce5a2495373992.png)

### 自动化脚本上传固件

上传固件使用 `lftp` 程序连接到 FTP 服务器，脚本**自动检测传输模式**：

| 条件 | 传输方式 | 说明 |
|------|----------|------|
| 本地挂载路径 `/srv/ftp/firmware` 存在 | `cp`（本地文件系统） | 走本地文件拷贝，快速直接 |
| 本地挂载路径不存在 | `lftp` 远程连接 | 自动切换到 lftp 模式 |

| 项目 | 配置值 |
|------|--------|
| FTP 服务器地址 | `192.168.0.71` |
| 端口 | `20249` |
| 账号 | `system develop.share` |
| 密码 | 通过环境变量 `FTP_PASS` 设置，未设置则交互式静默输入 |

> 密码安全提示：CI 自动化场景建议通过 `export FTP_PASS='passwd'` 设置，避免交互输入中断流程。

| 示例 | 具体内容 | 脚本结果 |
| --------------- | --------------- | --------------- |
| `feasy_upload.sh -h` | 显示脚本使用说明 | 打印当前脚本用法、镜像命名规范、路径规则、FTP 服务器信息 |
| `feasy_upload.sh <镜像文件>.img` | 基本模式：解析镜像名、生成模板发行说明、等待审核确认后打包上传FTP | 上传镜像到 `FTP/{路径}/{版本}_{日期}/`，生成`.zip`压缩包（内含`CHANGELOG.md`），更新全局`CHANGELOG.md`，生成`upload_report.txt` |
| `FTP_PASS='passwd' feasy_upload.sh <镜像文件>.img` | 预先指定 FTP 密码，非交互式执行 | 跳过密码输入提示，其余流程不变 |
| `feasy_upload.sh -l <目录> <镜像文件>.img` | 本地模式：上传到本地指定目录（不上传FTP），用于测试验证 | 文件上传到 `<目录>/` 下保持相同的分层子目录结构，其余流程不变 |
| `feasy_upload.sh -s <镜像文件>.img` | 跳过CHANGELOG人工审核流程（CI自动化使用） | 直接生成默认CHANGELOG.md，跳过审核门禁 |
| `feasy_upload.sh -n <CHANGELOG文件> <镜像文件>.img` | 使用外部指定CHANGELOG文件，跳过自动生成模板 | 将指定文件内容作为发行说明打包进zip |
| `feasy_upload.sh -d <镜像文件>.img` | 模拟运行（Dry-Run），不实际拷贝或上传 | 输出每一步将要执行的操作，便于提前排查问题 |
| `feasy_upload.sh -y <镜像文件>.img` | 跳过所有交互确认（版本冲突检查、CHANGELOG审核等） | 全自动静默执行，适用于已确认的场景 |
| `feasy_upload.sh -f <镜像文件>.img` | 强制覆盖FTP上已存在的同名文件（谨慎使用） | 同路径已有文件时不再报错中断，直接覆盖 |

> 固件上传脚本应有以下功能：

1. 自动基于镜像名规划上传路径
2. 目录创建（本地挂载 `mkdir -p` / lftp 远程 `mkdir -p`）
3. 文件上传（自动检测模式：优先本地挂载 `cp`，否则 `lftp put`）
4. CHANGLOG 追加集成
5. 上传到本地模式，不上传FTP，本地模式上传的根目录可由用户手动输入用于测试
6. 镜像包打包
7. 镜像包中的CHANGLOG.md应当是FTP上已有CHANGELOG.md的延伸版，也就是这个固件发布时，压缩包的CHANGELOG.md会和上一级目录中Debug类型/Release类型全局的CHANGELOG.md是同步的，并且是都是当时最新的。
8. FTP 密码安全机制：优先从环境变量 `FTP_PASS` 读取，未设置时交互式静默输入，避免密码明文暴露
9. 检查镜像同级目录是否有`build_info`相关文件，若有，一同上传，该文件并与upload_report.txt同级目录

> 上传脚本应有以下安全机制

1. 不得覆盖已有文件，如果同一个镜像名在FTP有重复，中断操作（lftp 模式下同样适用，通过 `cls` 远程检查文件存在性）
2. 脚本可操作的路径为 `/10_系统开发版本`（lftp 模式）或 `FTP_PATH/10_系统开发版本`（本地挂载模式），其余路径禁止修改
3. 镜像名合法性检查，由于路径是基于镜像名去推断的，如果镜像名格式错了，那就禁止后续推送操作
4. 发行说明模板生成，模板内容基于最近的一次提交点，随后提示用户完善这个发行说明，最后再进行提交动作，发行说明的中间文件为CHANGELOG_TEMP.md，存在于SDK根目录，这个模板有一个人为检查的标志字段，比如此`CHANGELOG是否已被开发者验证检查 CHECKED: yes/no`，脚本通过这个字段判断是否人为检查了发行说明，如果已检查，则可发行，发行后删除这个TEMP CHANGLOG。
5. 镜像版本检查，如果发现FTP上已有Release_V1.0.0 e.g. 的镜像，则提示用户当前FTP已有的镜像，并提示是否继续上传（lftp 模式同样适用），此检查只对Release版本有效
6. 上传完整性校验：上传后对比本地与远程文件大小，防止传输损坏（lftp 模式通过 `cls --size` 获取远程文件大小）

> [!IMPORTANT]
> 自动化固件上传脚本上传操作应当基于镜像名来确定，从镜像名`RK3568_A11_ATBM6165_BW8205_V1.0.0_Release_20260625_ab012388e4.img` 可以得出固件存储路径，注意，Debug镜像名不带git哈希
