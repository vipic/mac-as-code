# macOS config and applications as code

一键改系统设置和安装软件。新电脑不用安装依赖直接就可以进行恢复。

| 命令 | 介绍 |
|------|--------|
| `sh init.sh`（或 `bash init.sh`） | 分步多选，按需执行 |
| `sh scripts/backup.sh` | 备份个人数据（自动生成快照目录），信息不上 Github。外置硬盘转移再恢复。非常个人化 |
| `sh scripts/doctor.sh` | 检查环境（可选） |
| `sh scripts/check_format.sh` | 检查 `config/` 编写格式（注解项 / Brewfile） |
| `sh scripts/check_format.sh --self-test` | 用固定件验证检查脚本本身（改它时用） |

可改的清单在 `config/`（Brewfile、系统设置、Dock、plugins）；实现脚本在 `scripts/`。

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
5. 插件（Oh My Zsh 等）

操作：`↑↓` 移动，`空格` 选中/取消，`a` 全选，`n` 全不选，`Enter` 确认进入下一步，`q` 退出。确认后开始执行，中途不再询问，但可能需要管理员授权

主线三块：系统设置 → 软件安装（Brewfile，含 mas）→ Dock。若勾选了 App Store 应用，会在装机前打开 App Store 并等待登录确认。

软件按计划 **逐个**下载安装；失败单项会记录并继续。结束打印汇总，并写入项目内 `logs/init-*.tsv`。

## 💾 备份 / 恢复（独立管线）

```shell
# 重置前备份 → 自动生成目录，拷到外置盘
sh scripts/backup.sh

# 新机：先 sh init.sh 装好应用，再进入该次快照目录恢复
cd ~/Desktop/backup/reset-kit/<时间戳>-<机器名>
sh restore.sh
```

快照含：SSH、**`.gitconfig`（含 Git 用户信息）**、`.zshrc`、iTerm2、CleanShot、Keyboard Maestro、Rime/Squirrel、TextFlash，以及 Brave **插件本地配置**（Sync 不同步的那部分：`Local Extension Settings` + 扩展 IndexedDB）。书签/扩展列表仍靠 Brave Sync。

`TEXTFLASH_APP_PATH` 可指定非默认 TextFlash 路径。恢复前会保留现有文件为 `.before-restore-*`。

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

插件放在 `config/plugins/`：每个 `<id>.sh` 一个插件，文件头写明多选文案即可被发现：

```shell
#!/bin/sh
# oh-my-zsh | Oh My Zsh（非交互安装）
# …安装逻辑
```

`check_format` 会校验：注解项格式、插件头 id 与文件名一致、Brewfile 的 `brew` / `cask` / `mas … id:` 行。
