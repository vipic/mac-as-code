# macOS config and applications as code

一键改系统设置和安装软件。新电脑不用安装依赖直接就可以进行恢复。

| 命令 | 介绍 |
|------|--------|
| `sh init.sh`（或 `bash init.sh`） | 分步多选，按需执行 |
| `sh scripts/backup.sh` | 备份个人数据（自动生成快照目录），信息不上 Github。外置硬盘转移再恢复。非常个人化 |
| `sh scripts/doctor.sh` | 检查环境（可选） |
| `sh scripts/check_format.sh` | 检查 `config/` 编写格式（注解项 / 软件清单） |
| `sh scripts/check_format.sh --self-test` | 用固定件验证检查脚本本身（改它时用） |

可改的清单在 `config/`（Brewfile、GitHub Releases 应用、系统设置、Dock、recipes）；实现脚本在 `scripts/`。

## ⚠️ 注意

- 跑脚本前先解决网络连通性问题

## 🚀 更新设置和安装软件：`init.sh`

```shell
sh init.sh
# 或
bash init.sh
```

开始时**分步**多选（默认全选，可看说明后逐项取消）：

1. 系统设置（展开为具体 defaults 项）
2. Dock（展开为具体 Dock 项）
3. Homebrew 软件（formula / cask）
4. App Store 应用（若有）
5. Recipes / GitHub Releases 应用

操作：`↑↓` 移动，`空格` 选中/取消，`a` 全选，`n` 全不选，`Enter` 确认进入下一步，`q` 退出。确认后开始执行，中途不再询问，但可能需要管理员授权

主线三块：系统设置 → 软件安装（Brewfile、GitHub Releases 应用与 Recipes）→ Dock。若勾选了 App Store 应用，会在装机前打开 App Store 并等待登录确认。

软件按计划 **逐个**下载安装；失败单项会记录并继续。结束打印汇总，并写入项目内 `logs/init-*.tsv`。

## 💾 备份 / 恢复（独立管线）

```shell
# 重置前备份 → 自动生成目录，拷到外置盘
sh scripts/backup.sh

# 新机：先 sh init.sh 装好应用，再进入该次快照目录恢复
cd ~/Desktop/backup/reset-kit/<时间戳>-<机器名>
sh restore.sh
```

快照含：SSH、**`.gitconfig`（含 Git 用户信息）**、`.zshrc`、Ghostty、iTerm2、CleanShot、Keyboard Maestro、Rime/Squirrel、TextFlash，以及 Brave **插件本地配置**（Sync 不同步的那部分：`Local Extension Settings` + 扩展 IndexedDB）。书签/扩展列表仍靠 Brave Sync。

Ghostty 配置统一放在 macOS 专用目录 `~/Library/Application Support/com.mitchellh.ghostty/`（主配置为 `config.ghostty`，旧版为 `config`），reset-kit 只迁移此目录；配置使用的 Maple Mono NF CN 字体由 Brewfile 安装，不进入快照。`TEXTFLASH_APP_PATH` 可指定非默认 TextFlash 路径。恢复前会保留现有文件为 `.before-restore-*`。

## 📝 其他

配置按个人习惯编写，可按需改。`config/Brewfile` 可用 `brew bundle dump` 更新。改完配置后建议跑：

```shell
sh scripts/check_format.sh              # 查仓库 config（日常改配置用这个）
sh scripts/check_format.sh --self-test  # 改 check_format 时：固定件自测 + 再查 config
```

CI 会跑 `bash -n` 与 `check_format.sh --self-test`。

系统设置 / Dock 在 `config/defaults_config.sh`、`config/defaults_dock.sh` 里用「注释 + 命令」维护，格式：

```shell
# my-setting | 这一项的说明（多选里显示）
defaults write NSGlobalDomain SomeKey -int 1
```

增减一项只需加/删这样一段；`init` 多选与执行会自动解析，不必再改目录表或 `case`。

Recipes 放在 `config/recipes/`：每个 `<id>.sh` 是一个可独立执行的 recipe，文件头写明多选文案即可被发现：

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
vipic/Pastry
vipic/TextFlash
stablyai/orca
```

清单允许空行和以 `#` 开头的整行注释，可以按软件用途分组说明。

应用 id、显示名称和安装路径会从仓库名自动生成，仓库名首字母会自动大写。例如 `stablyai/orca` 会生成 `orca`，显示为 `Orca`，并安装到 `/Applications/Orca.app`。

`init.sh` 会自动读取清单，并把每个应用加入最后一步的多选列表。`scripts/github_release_apps.sh` 负责读取清单，`scripts/install_github_release_app.sh` 负责单个应用的实际安装，两者都不依赖 `jq`。安装器使用 macOS 自带的 `plutil` 解析 GitHub API 返回值，并执行以下流程：

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

如果最新 Release 没有 DMG，或者根据当前 CPU 架构仍不能唯一确定 DMG，安装器会停止并提示人工确认，避免选错安装包。新增同类应用只需在 `config/github_release_apps.conf` 增加一行，不需要再写 Recipe 或修改 `init.sh`。如果首字母大写后的仓库名与 App 名称仍不一致，则改用独立 Recipe。

`check_format` 会校验：注解项格式、Recipe 头 id 与文件名一致、GitHub Releases 应用清单字段、Brewfile 的 `brew` / `cask` / `mas … id:` 行。
