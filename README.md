# macOS as Code

用配置清单管理自己的 Mac：安装常用软件、应用系统偏好，并在重置或换机时备份恢复个人数据。入口使用 macOS 自带的 Shell，无需预装第三方运行时。

## 开始使用

```sh
sh init.sh
```

选择要完成的任务：

```text
mac-as-code
1 配置这台 Mac    查看差异、安装软件、应用设置
2 备份这台 Mac    保存个人配置和应用数据
3 从备份恢复      选择快照，恢复个人数据
0 退出
```

菜单本身不会安装工具或修改配置。安装软件时需要网络，系统可能要求管理员授权或 App Store 登录。

各级数字菜单均竖排展示。每个输入步骤显示 `b` 返回和 `q` 退出程序；多选页的导航提示始终显示，不会被页面说明覆盖。完整的选项层级、确认分支和操作影响见[交互操作树](docs/操作树.md)。

## 配置这台 Mac

新机配置和日常调整使用同一流程：**实时检测 → 查看待处理项 → 调整选择（可选）→ 确认应用 → 查看结果**。

- 软件、系统设置和 Dock 汇总展示；已满足项折叠，不重复执行。
- 可自动比较的差异默认选中，详情展示当前状态与目标状态。软件以是否安装为准，不在这个流程中自动升级已有软件。
- 复合命令、未知 Recipe、重置布局和清除密码策略等操作默认不选，需要明确选择。没有 Homebrew 或无法读取 App Store 清单时，不能可靠判断的应用也列为需确认项。
- 调整界面支持 `↑↓` / `j k` 移动、空格切换、`a` 全选、`n` 清空；`Enter` 保存选择返回，`b` 放弃此次调整返回，`q` 退出程序。长列表随光标翻页。
- 应用前再次读取当前状态；若状态变化，更新计划并返回确认。不会拿当天的审计缓存直接执行。
- 设置可能重启 Finder / Dock。结果突出失败项，完整记录保存在 `logs/init-*.tsv`。配置菜单的「重试上次失败项」只选择仍需处理的失败项。

本机新装的软件可从配置菜单选择「将本机软件加入配置清单」。此操作默认全部不选，确认后只追加选中的 Brewfile 条目，不安装或卸载软件。

## 重置与换机

旧电脑运行 `sh init.sh`，选择「备份这台 Mac」。确认备份位置、范围和应用退出提示后，会在 `~/Desktop/backup/reset-kit/` 创建带时间和机器名的快照。把整个快照目录拷到外置盘。

新电脑运行同一入口，选择「从备份恢复」，从默认位置选择快照，或输入外置盘中的快照目录。预览来源和内容、校验完整性后，可以直接恢复，也可以先安装快照对应的软件再恢复。软件安装失败时停止串联恢复，处理失败后可再次进入。

如果还要完整配置新电脑，先选择「配置这台 Mac」。恢复任务中的软件安装只覆盖快照对应的应用和环境，不会自动安装整份软件清单。

没有本项目时，快照仍可独立恢复：

```sh
cd /外置盘路径/快照目录
sh restore.sh
```

备份范围：SSH、`.gitconfig`（含 Git 用户信息）、`.zshrc`、Ghostty、CleanShot、Keyboard Maestro、Rime、TextFlash，以及 Brave 插件本地配置。备份与日志含个人信息，不提交到 GitHub。

- 恢复覆盖前保留现有文件为 `.before-restore-*`，快照缺少或校验失败时停止。
- 备份会临时退出 Keyboard Maestro 和 Brave，结束或失败时尝试恢复原先运行状态。`RESET_KIT_SKIP_QUIT_APPS=1` 仅供测试使用。
- Ghostty 只备份统一配置所在的 `~/.config/ghostty/`，排除 `*.bak`，不再备份 macOS 专用目录；已有快照中的专用目录仍可恢复。字体由 Brewfile 安装。
- CleanShot / Keyboard Maestro 偏好以 plist 迁移。Keyboard Maestro 只迁移主宏文件、偏好及引用的状态栏图标，不迁移历史、缓存、变量或剪贴板。
- TextFlash 使用应用 CLI 导入导出片段与配置；不支持 CLI 的旧版本会明确列为未备份或未恢复。
- Brave 迁移 `Local Extension Settings` 和扩展 IndexedDB；书签及扩展列表仍需 Brave Sync。

## 快捷命令与诊断

日常无需记忆以下命令；需要直接进入某个任务时可以使用：

```sh
sh init.sh configure
sh init.sh backup [备份根目录]
sh init.sh restore [快照目录]
sh init.sh doctor
sh init.sh --help
```

非交互执行必须显式提供 `--yes`：

```sh
sh init.sh configure --yes             # 仅应用可自动判断的差异
sh init.sh backup --yes [备份根目录]
sh init.sh restore --yes /快照目录     # 直接恢复，不自动安装软件
```

旧版 `sh init.sh --yes` 仍表示**全量装机**，包含需确认的重置类操作；`--from`、`--skip-doctor` 作为兼容参数保留。日常推荐新任务入口。

旧审计命令仍可使用：`sh scripts/audit.sh help` 列出完整命令。`review` 进入新的实时配置流程，`append` 实时检测并追加软件。纯查询继续支持当天缓存和 `--refresh`。

「初始化后变化」仅追踪可解析的标量设置。应用成功后只更新本次成功项目的基线，保留其他项目的变化；手动执行 `snapshot` 则重建全部可比较设置的基线。缓存位于 `~/.cache/mac-as-code/audit/`，基线和失败重试计划位于 `~/.local/state/mac-as-code/`。

## 配置清单与维护

配置按个人习惯编写，可按需改。新增本机软件优先从配置菜单选择「将本机软件加入配置清单」，预览后追加。改完配置后运行：

```sh
sh init.sh check
```

本地与 CI 使用同一个入口，逐文件执行 `bash -n`、`shellcheck -x -P SCRIPTDIR`、格式自测和隔离工作流测试。校验不安装工具、不访问网络、不修改用户配置；需事先有 ShellCheck。只改清单也可运行 `sh scripts/check_format.sh`。

系统设置 / Dock 在 `config/defaults_config.sh`、`config/defaults_dock.sh` 里用「注释 + 命令」维护，格式：

```shell
# my-setting | 这一项的说明（多选里显示）
defaults write NSGlobalDomain SomeKey -int 1
```

增减一项只需加/删这样一段；差异计划、多选与执行会自动解析，不必再改目录表或 `case`。

Recipes 放在 `config/recipes/`：每个 `<id>.sh` 是一个可独立执行的 recipe，文件头写明显示文案即可被发现：

```shell
#!/bin/sh
# oh-my-zsh | Oh My Zsh（非交互安装）
# …可重复执行的安装或配置逻辑
```

每个 recipe 都可以直接用 `sh config/recipes/<id>.sh` 单独执行；`init.sh` 也会自动发现并在 Brew/MAS 之后逐个执行。

当前内置 Recipe 为 `oh-my-zsh`。

### GitHub Releases 应用

不在 Brew / MAS 中、但通过 GitHub Releases 发布 DMG 的应用，统一写在 `config/github_release_apps.conf`：

```text
# 每行一个 GitHub 仓库（owner/repo）；仓库名用于推导 App 名称
vipic/pastry
vipic/textflash|TextFlash
stablyai/orca
```

清单允许空行和以 `#` 开头的整行注释，可以按软件用途分组说明。

应用 id、显示名称和安装路径会从仓库名自动生成，仓库名首字母会自动大写。例如 `stablyai/orca` 会生成 `orca`，显示为 `Orca`，并安装到 `/Applications/Orca.app`。推导结果与实际 App 名不一致时（如 `vipic/textflash` 的应用是 `TextFlash.app`），在仓库后用 `|` 显式指定 App 名称。

`init.sh` 会自动读取清单，并把未安装应用加入同一个差异选择列表。`scripts/github_release_apps.sh` 负责读取清单，`scripts/install_github_release_app.sh` 负责单个应用的实际安装，两者都不依赖 `jq`。安装器使用 macOS 自带的 `plutil` 解析 GitHub API 返回值，并执行以下流程：

1. 查询仓库的 latest release（不选 prerelease）
2. 找到 macOS DMG；有多个 DMG 时根据 Apple Silicon / Intel 架构选包
3. 比较 `/Applications/<App>.app` 的当前版本
4. 下载 DMG，并在 GitHub 提供 digest 时校验 SHA-256
5. 挂载镜像、校验应用代码签名，再复制到 `/Applications`
6. 卸载镜像并清理临时文件

可单独安装：

```shell
sh scripts/github_release_apps.sh pastry
sh scripts/github_release_apps.sh textflash

# 不传 id 时按清单安装全部
sh scripts/github_release_apps.sh
```

如果最新 Release 没有 DMG，或者根据当前 CPU 架构仍不能唯一确定 DMG，安装器会停止并提示人工确认，避免选错安装包。新增同类应用只需在 `config/github_release_apps.conf` 增加一行，不需要再写 Recipe 或修改 `init.sh`。

`check_format` 会校验：注解项格式、Recipe 头 id 与文件名一致、GitHub Releases 应用清单字段、Brewfile 的 `brew` / `cask` / `mas … id:` 行。

## 关联项目

- [Pastry](https://github.com/vipic/pastry)：macOS 剪贴板历史管理工具，可通过本仓的 GitHub Releases 应用清单安装。
- [TextFlash](https://github.com/vipic/textflash)：macOS 菜单栏文本展开工具；除安装外，本仓还支持备份和恢复其片段与配置。
