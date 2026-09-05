# macOS as Code

用配置清单管理自己的 Mac：安装常用软件、应用系统偏好，并在重置或换机时备份恢复个人数据。入口使用 macOS 自带的 Shell，无需预装第三方运行时。

## 开始使用

```sh
sh mac.sh
```

选择要完成的任务：

```text
mac-as-code
让每一台 Mac，都回到你的习惯。
以配置清单为准，确认后再执行。

今天想做什么？
› 配置这台 Mac    查看差异、安装软件、应用设置
  备份这台 Mac    保存个人配置和应用数据
  从备份恢复      恢复个人数据
  检查环境        查看工具与安装状态

↑↓ 选择 · Enter 执行
q 退出
```

菜单本身不会安装工具或修改配置。安装软件时需要网络，系统可能要求管理员授权或 App Store 登录。

进入菜单时清屏一次，移动光标时整帧缓冲后原位覆盖，不再清空整页。顶部为项目说明，中间为操作区，底部以灰色显示当前按键。单选使用 `↑↓`（或 `j` / `k`）移动、`Enter` 执行；`b` 返回上一层，`q` 退出，无需回车。确认页可按 `Enter` 或 `y` 执行；详情和长确认内容支持方向键与 PageUp / PageDown 滚动。返回和退出不会撤销已经完成的操作。完整层级见[交互操作树](docs/操作树.md)。

路径编辑为空时，`b` / `q` 即时返回或退出；开始输入后，字母按路径内容处理，使用 `Esc` 返回、`Ctrl+Q` 退出、`Enter` 使用路径。执行输出在中间滚动；系统授权、第三方安装器使用其自身交互，`Ctrl+C` 中止当前任务。

日常只需这一条命令。原入口和任务快捷参数已移除；`scripts/` 是内部实现，不需要直接调用。

## 配置这台 Mac

新机配置和日常调整使用同一流程：**实时检测 → 查看待处理项 → 调整选择（可选）→ 确认应用 → 查看结果**。

- 软件、系统设置和 Dock 汇总展示。已满足项只计数，不进入当前多选列表；「查看详情」也只展示差异和需确认项。
- 可自动比较的差异默认选中，详情展示当前状态与目标状态。软件以是否安装为准，不在这个流程中自动升级已有软件。
- 复合命令、未知 Recipe、重置布局和清除密码策略等操作默认不选，需要明确选择。没有 Homebrew 或无法读取 App Store 清单时，不能可靠判断的应用也列为需确认项。
- 调整界面支持 `↑↓` / `j k` 移动、空格切换、`a` 全选、`n` 清空；`Enter` 保存选择返回，`b` 放弃此次调整返回范围选择，`q` 退出程序。长列表随光标翻页。
- 应用前再次检测整份计划；即使变化发生在未选项目上，也会更新计划并返回确认。更新时保留仍待处理的原选择，不自动选中新出现的差异。不会拿当天的审计缓存直接执行。
- 系统设置 / Dock 只要有成功应用的项目，就会分别尝试重启 Finder / Dock。执行到汇总阶段时，结果摘要保存到 `logs/apply-*.tsv`（状态、项目、说明），不包含完整终端输出；前置检查失败或提前退出时可能没有这份日志。
- 执行前先保存全部已选项为重试计划，正常执行结束后缩减到失败项。因此「重试上次失败项」也可能包含上次中断或前置检查失败留下的项目；它只重新选择仍未满足的项，需要再选「应用已选项」才执行。

本机新装的软件可从配置菜单选择「将本机软件加入配置清单」。候选范围是 Homebrew 顶层 formula、cask、App Store 应用，以及能匹配到 cask 的手工安装应用。此操作默认全部不选，确认后逐项复核、追加到 Brewfile 的 `audit-added` 区块并运行格式检查；某项检查失败会撤销该次追加，之前成功的追加仍保留。不安装或卸载软件。

## 重置与换机

旧电脑运行 `sh mac.sh`，选择「备份这台 Mac」。选择默认目录 `~/Desktop/backup/reset-kit/`，或选「输入其他目录」；确认后创建带时间和机器名的新快照。备份范围固定，不提供逐项选择。完成后把整个快照目录拷到外置盘。

新电脑运行同一入口，选择「从备份恢复」。方向键选择默认备份根目录下含 `restore.sh` 的快照；外置盘或自定义备份位置需选择「输入其他快照路径」。来源和内容预览在最终确认页展示，来自快照元数据，元数据缺失时不会因此停止。校验通过后，可以直接恢复，也可以先安装支持识别的对应软件再恢复。软件安装失败时停止串联恢复，处理失败后可再次进入。

如果还要完整配置新电脑，先选择「配置这台 Mac」。恢复前安装使用以下固定映射，并仅从当前配置清单中选取尚未满足的项目；没有待安装项也可能是清单中未登记对应软件，不代表已验证所有依赖。

| 快照中存在的内容 | 恢复前可安装的清单项目 |
|---|---|
| Ghostty 配置（XDG 或旧版 macOS 目录） | Ghostty、Maple Mono Normal NF CN 字体 |
| CleanShot 偏好 | CleanShot |
| Keyboard Maestro 应用数据目录 | Keyboard Maestro |
| Rime 目录 | Squirrel |
| Brave 插件配置目录 | Brave Browser |
| TextFlash 备份目录 | TextFlash |
| `.zshrc` | Oh My Zsh |

安装前会展示最终清单并单独确认；此路径会选中匹配到的「需确认」软件。安装成功后还需确认是否恢复数据；取消恢复不会卸载刚安装的软件。它不会自动安装整份 Brewfile，也不为任意应用推断依赖。

没有本项目时，快照仍可独立恢复：

```sh
cd /外置盘路径/快照目录
sh restore.sh
```

备份范围：SSH、`.gitconfig`（含 Git 用户信息）、`.zshrc`、Ghostty、CleanShot、Keyboard Maestro、Rime、TextFlash，以及 Brave 插件本地配置。备份与日志含个人信息，不提交到 GitHub。

- 快照目录无效、缺少 `restore.sh`、`SHA256SUMS` 缺失或为空、校验失败时不会执行恢复，菜单会要求重新选择。校验只覆盖清单中记录的数据文件；生成快照时不纳入 `restore.sh`、`metadata/` 和符号链接，也不验证后来额外加入的文件。
- 恢复普通文件 / 目录前会将已有目标移到 `.before-restore-*`，恢复 plist 前会导出现有偏好留存；TextFlash 通过 CLI 导入，脚本没有先导出其当前数据。恢复没有自动回滚。
- 缺少某项源数据、没有对应偏好、TextFlash CLI 不支持或导入导出失败，均可能显示为「跳过 / 未备份 / 未恢复」。这些情况通常继续后续项目，所以出现结束汇总或退出码 0 不代表所有数据都已迁移。请看每项原因；复制等命令的未处理错误可能提前中止，来不及打印完整汇总。
- 备份会尝试临时退出 Keyboard Maestro 和 Brave，退出时尝试重新打开备份前就在运行且当前已退出的应用；如果此前运行过 Keyboard Maestro 且尝试退出过它，还会尝试重启 ControlCenter。恢复会尝试退出 CleanShot、Keyboard Maestro，以及有对应待恢复数据的 TextFlash / Brave，不关闭 Ghostty，也不会自动重开这些应用。`RESET_KIT_SKIP_QUIT_APPS=1` 可跳过退出 / 重开，仅供测试使用。
- Ghostty 固定备份 `~/.config/ghostty/`，排除 `*.bak` 和 `.DS_Store`，不读取自定义 `XDG_CONFIG_HOME`，也不解析并追踪目录外的 `config-file` 引用。不再备份 macOS 专用目录；当前生成的恢复脚本仍兼容快照内的旧版专用目录。字体由 Brewfile 安装。
- CleanShot / Keyboard Maestro 偏好以 plist 迁移。Keyboard Maestro 只迁移主宏文件、偏好及引用的状态栏图标，不迁移历史、缓存、变量或剪贴板。
- TextFlash 使用应用 CLI 导入导出片段与配置；不支持 CLI 的旧版本会明确列为未备份或未恢复。
- Brave 默认只迁移 `Default` profile 的 `Local Extension Settings` 和 `chrome-extension_*` IndexedDB；可用 `BRAVE_PROFILE_DIR` 指定一个其他 profile，不会自动迁移全部 profiles。书签及扩展列表仍需 Brave Sync。
- SSH 备份排除 `agent/` 和 `.DS_Store`；Rime 排除 `build/`、`plum/` 及运行时日志 / 锁文件。恢复阶段还会调整现有 `~/.ssh` 及匹配密钥文件的权限，即使快照缺少 SSH 数据。

统一入口实际执行的是所选快照自带的 `restore.sh`，不会用仓库里的新模板替换它。以上恢复细节描述当前模板；旧快照的行为以其自身脚本为准。当前独立恢复脚本支持 `Enter` / `y` 确认、`q` 即时退出；它是脱离仓库时的恢复入口，没有上一级菜单。

## 检查环境

主菜单「检查环境」检查 macOS、Command Line Tools、Git、Brewfile，以及 Homebrew、mas 和 Oh My Zsh 状态，不安装软件。安装前所需的检查仍会自动执行；缺少 Command Line Tools 时会打开系统安装器并停止本次安装，完成后重新进入配置菜单。

本机软件检测缓存位于 `~/.cache/mac-as-code/audit/`；进入「将本机软件加入配置清单」会刷新缓存，即使随后取消也会保留缓存。设置基线和失败重试计划位于 `~/.local/state/mac-as-code/`。应用成功后只更新成功设置的基线，保留其他项目的变化。

## 配置清单与维护

配置按个人习惯编写，可按需改。新增本机软件优先从配置菜单选择「将本机软件加入配置清单」，预览后追加。改完配置后运行：

```sh
sh mac.sh --check
```

本地与 CI 使用同一个入口，逐文件执行 `bash -n`、`shellcheck -x -P SCRIPTDIR`、格式自测和隔离工作流测试。校验不安装工具、不访问网络、不修改用户配置；需事先有 ShellCheck；终端交互测试使用 macOS 自带的 Expect。`--check` 是维护与 CI 选项，`--help` 显示入口帮助。

系统设置 / Dock 在 `config/defaults_config.sh`、`config/defaults_dock.sh` 里用「注释 + 命令」维护，格式：

```shell
# my-setting | 这一项的说明（多选里显示）
defaults write NSGlobalDomain SomeKey -int 1
```

增减一项只需加/删这样一段；差异计划、多选与执行会自动解析，不必再改目录表或 `case`。

Recipes 放在 `config/recipes/`：每个 `<id>.sh` 是一个 recipe，文件头写明显示文案即可被发现：

```shell
#!/bin/sh
# oh-my-zsh | Oh My Zsh（非交互安装）
# …可重复执行的安装或配置逻辑
```

配置菜单自动发现 recipe 后，仅在选中时于 Brew/MAS 之后执行。差异检测目前只识别 Oh My Zsh 是否存在，其他 Recipe 都需要明确选择。

当前内置 Recipe 为 `oh-my-zsh`，调用官方安装器并传入 `--unattended`，默认 `KEEP_ZSHRC=no`，可能替换现有 `.zshrc`。要让安装器保留它，可设置 `KEEP_ZSHRC=yes`。

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

`mac.sh` 会自动读取清单，并把未安装应用加入同一个差异选择列表。`scripts/github_release_apps.sh` 负责读取清单，`scripts/install_github_release_app.sh` 负责单个应用的实际安装，两者都不依赖 `jq`。安装器使用 macOS 自带的 `plutil` 解析 GitHub API 返回值，并执行以下流程：

1. 查询仓库的 latest release（不选 prerelease）
2. Release 只有一个 DMG 时直接选用；多个 DMG 时优先选择唯一匹配架构的包，没有匹配架构包时尝试唯一通用包
3. 比较 `/Applications/<App>.app` 的当前版本
4. 下载 DMG，并在 GitHub 提供 digest 时校验 SHA-256
5. 挂载镜像、校验应用代码签名，再复制到 `/Applications`
6. 尝试卸载镜像并清理临时文件（失败退出也会触发清理）

如果最新 Release 没有 DMG，或者根据当前 CPU 架构仍不能唯一确定 DMG，安装器会停止并提示人工确认，避免选错安装包。新增同类应用只需在 `config/github_release_apps.conf` 增加一行，不需要再写 Recipe 或修改 `mac.sh`。

`check_format` 会校验：注解项格式、Recipe 头 id 与文件名一致、GitHub Releases 应用清单字段、Brewfile 的 `brew` / `cask` / `mas … id:` 行。

## 关联项目

- [Pastry](https://github.com/vipic/pastry)：macOS 剪贴板历史管理工具，可通过本仓的 GitHub Releases 应用清单安装。
- [TextFlash](https://github.com/vipic/textflash)：macOS 菜单栏文本展开工具；除安装外，本仓还支持备份和恢复其片段与配置。
