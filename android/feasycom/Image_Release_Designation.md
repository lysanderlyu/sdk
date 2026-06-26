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
2. `Release Notes文件名规范`：自动脚本上传时，镜像img会被打包压缩为`.zip`格式，Release Notes在镜像同级目录，全部Release共用一个`Release Notes`文件
3. `Release Notes文件路径`：除了镜像.zip压缩包同级目录存放这一个全局的Release Notes，每一个单独的压缩包内部应当在打包img时同时打包一个只全局CHANGELOG.md，目的是当发送zip镜像包时解包能看到CHANGELOG.md，在FTP浏览镜像时也能通过zip同级目录有个CHANGELOG.md查阅。

### 发行说明放置位置参考
对于`RK3568_A11_ATBM6165_BW8205_V1.0.0_Release_20260625_ab012388e4.zip` 和 `RK3568_A11_ATBM6165_BW8205_V1.0.0_Debug_20260624.1224.zip` 有以下存储规则
```txt

```plain
├── FTP
│   ├── RK3568_A11
│   │   ├── ATBM6165_Series
│   │   │   ├── BW501GI
│   │   │   └── BW8205
│   │   │       ├── Debug
│   │   │           ├── CHANGELOG.md
│   │   │       │   ├── RK3568_A11_ATBM6165_BW8205_V1.0.0_Debug_20260624.1224.zip
│   │   │       │   ├── RK3568_A11_ATBM6165_BW8205_V1.0.0_Debug_20260625.1334.zip
│   │   │       │   └── RK3568_A11_ATBM6165_BW8205_V1.0.1_Debug_20260625.1634.zip
│   │   │       └── Release
│   │   │           ├── CHANGELOG.md
│   │   │           ├── RK3568_A11_ATBM6165_BW8205_V1.0.0_Release_20260625_ab012388e4.zip
│   │   │           └── RK3568_A11_ATBM6165_BW8205_V1.0.1_Release_20260626_a0400dedca.zip
│   │   └── RTL8821CS_Series
│   ├── RK3568_UBUNTU2204
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

## [v1.2.0]

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

## [v1.1.0]

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
├── FTP
│   ├── RK3568_A11
│   │   ├── ATBM6165_Series
│   │   │   ├── BW501GI
│   │   │   └── BW8205
│   │   │       ├── Debug
│   │   │           ├── CHANGELOG.md
│   │   │       │   ├── RK3568_A11_ATBM6165_BW8205_V1.0.0_Debug_20260624.1224.zip
│   │   │       │   ├── RK3568_A11_ATBM6165_BW8205_V1.0.0_Debug_20260625.1334.zip
│   │   │       │   └── RK3568_A11_ATBM6165_BW8205_V1.0.1_Debug_20260625.1634.zip
│   │   │       └── Release
│   │   │           ├── CHANGELOG.md
│   │   │           ├── RK3568_A11_ATBM6165_BW8205_V1.0.0_Release_20260625_ab012388e4.zip
│   │   │           └── RK3568_A11_ATBM6165_BW8205_V1.0.1_Release_20260626_a0400dedca.zip
│   │   └── RTL8821CS_Series
│   ├── RK3568_UBUNTU2204
│   └── RK3588_A11
```


# 自动化发布：
## 要求

- 应有`feasy_build.sh`自动化脚本生成固件，为了方便和RK平台兼容性，`feasy_build.sh`构建脚本沿用RK官方`build.sh`编译打包镜像操作，`feasy_build.sh`脚本只用于快速发布固件，避免人为编译发行版时生成了有本地修改但未提交git记录的源码生成的固件
- 应有`feasy_upload.sh`自动化脚本上传固件，并由专门的测试人员负责上传动作


## 方案

### 自动化脚本生成固件

`feasy_build.sh` 脚本应具有以下操作

| 示例 | 具体内容 | 脚本结果 |
| --------------- | --------------- | --------------- |
| `feasy_build.sh -h` | 显示脚本使用说明 | 打印当前脚本用法 |
| `feasy_build.sh -m BW8205` | 也就是source，lunch BW8205，build.sh -UKAup 集为一体便捷版 | 结果和原生`./build.sh -UKAup` 相同 |
| `feasy_build.sh -m BW8205 -d` | 编译并生成Debug调试固件 | 在SDK IMAGES/DEBUG/ 下生成 RK356X_A11_ATBM6165_BW8205_V1.0.0_Debug_20260625.1343.img |
| `feasy_build.sh -m BW8205 -r` | 编译并生成Release发行版固件，这个会检查当前是否有未提交的更改 | 在SDK IMAGES/RELEASE/ 下生成RK356X_A11_ATBM6165_BW8205_V1.0.0_Release_20260625_ab012388e4.img |

- 为了适配自动化生成脚本生成正确的固件名，比如自动获取 1.SoC平台，2. OS平台，3.模组芯片类型，4.版本号，这四个信息的定义需要在`device.mk`中新增四行，用于给`feasy_build.sh`脚本动态获取:

> 以下是脚本执行案例 

![镜像开始编译](http://106.55.165.251:9000/images/2026/06/80cf8d04cf1e706f3f5fbfb398bfdb8d.png)
![镜像生成案例](http://106.55.165.251:9000/images/2026/06/1808125cb9ebe724bc6e924a8065895d.png)
![镜像开始编译](http://106.55.165.251:9000/images/2026/06/33ea173d20e4141618ce5a2495373992.png)

### 自动化脚本上传固件

| 示例 | 描述 | 脚本结果 |
| --------------- | --------------- | --------------- |
| Item1.1 | Item2.1 | Item3.1 |

> 固件上传脚本应有以下功能：

1. 自动基于镜像名规划上传路径
2. 目录创建
3. 文件上传
4. CHANGLOG 追加集成
5. 上传到本地模式，不上传FTP，本地模式上传的根目录可由用户手动输入用于测试
6. 镜像包打包
7. 镜像包中的CHANGLOG.md应当是FTP上已有CHANGELOG.md的延伸版，也就是这个固件发布时，压缩包的CHANGELOG.md会和上一级目录中Debug类型/Release类型全局的CHANGELOG.md是同步的，并且是都是当时最新的。

> 上传脚本应有以下安全机制

1. 不得覆盖已有文件，如果同一个镜像名在FTP有重复，中断操作
2. 脚本可操作的路径为 `FTP://10_系统开发版本`，其余路径禁止修改
3. 镜像名合法性检查，由于路径是基于镜像名去推断的，如果镜像名格式错了，那就禁止后续推送操作
4. 发行说明模板生成，模板内容基于最近的一次提交点，随后提示用户完善这个发行说明，最后再进行提交动作，发行说明的中间文件为CHANGELOG_TEMP.md，存在于SDK根目录，这个模板有一个人为检查的标志字段，比如此`CHANGELOG是否已被开发者验证检查 CHECKED: yes/no`，脚本通过这个字段判断是否人为检查了发行说明，如果已检查，则可发行，发行后删除这个TEMP CHANGLOG。
5. 镜像版本检查，如果发现FTP上已有Release_V1.0.0 e.g. 的镜像，则提示用户当前FTP已有的镜像，并提示是否继续上传，此检查只对Release版本有效

> [!IMPORTANT]
> 自动化固件上传脚本上传操作应当基于镜像名来确定，从镜像名`RK3568_A11_ATBM6165_BW8205_V1.0.0_Release_20260625_ab012388e4.img` 可以得出固件存储路径，注意，Debug镜像名不带git哈希
