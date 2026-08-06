# AGENTS

Shared instructions for coding agents (Cursor, Claude Code, Codex, Hermes, CLI, etc.).

## Git 提交规范（强制）

所有提交（人工或 agent）必须使用 Conventional Commits，标题使用中文说明。

### 格式

```text
<type>(<optional-scope>): <中文说明>
```

### 允许的 type

- `feat` 新功能
- `fix` 修 bug
- `refactor` 重构（不改外部行为）
- `perf` 性能优化
- `docs` 文档
- `test` 测试
- `build` 构建 / 打包 / 发布链路
- `ci` CI 配置
- `chore` 杂务 / 依赖 / 工具
- `style` 纯格式或样式（不影响逻辑）

### 规则

1. `scope` 可选；用短小英文，如 `init`、`backup`、`brew`
2. 冒号后必须有一个空格
3. 标题用中文，完整说明「做了什么 / 为什么」；不要只写「修复」「更新」
4. 标题尽量不超过 72 字符
5. 标题不要以句号结尾
6. 一次提交只做一件事；无关改动拆开提交
7. 未明确要求时，不要自动 `git commit`
8. 用户要求提交时，先看 `git status` / `git diff` / 最近提交风格，再起草 message
9. 不要使用 `--no-verify` 跳过 hook
10. 不要擅自 `git commit --amend`；仅在用户明确要求且符合安全条件时才 amend

### 禁止 Co-Author / 署名尾注

**禁止**在 commit message 中添加任何 co-author、生成器署名或类似 trailer，包括但不限于：

- `Co-Authored-By: ...`
- `Co-authored-by: ...`
- `Signed-off-by: ...`（除非用户或仓库明确要求）
- `Generated-by: ...` / `Assisted-by: ...` / `Made-with: ...`
- Cursor / Claude / Codex / Copilot / ChatGPT 等工具署名行

Commit 只保留用户约定的 subject（以及必要时的 body / `BREAKING CHANGE`），不要附加 AI 相关元数据。

### 好例子

- `feat(backup): 快照新增 Ghostty 配置目录`
- `fix(init): 修复 Dock 项多选后未生效`
- `refactor(ui): 统一中文文案表述`
- `docs(agents): 补充提交规范`
- `chore(deps): 升级依赖`

### 坏例子

- `修复问题`
- `update code`
- `feat: 搞定了`
- `临时提交一下`
- `fix(ui): 修复按钮抖动` 后再附加 `Co-Authored-By: Cursor <cursor@cursor.com>`

### Body（可选）

需要时再写正文，说明动机、影响范围或破坏性变更：

```text
fix(auth): 修复过期 token 后无限刷新

在 401 时先清理本地会话，再跳转登录，避免循环请求。
```

### Breaking change

```text
feat(api)!: 调整用户接口返回结构

BREAKING CHANGE: `/users` 不再返回嵌套 profile 字段。
```

## 提交操作约定

1. 默认只改代码，不主动提交
2. 需要提交时：
   - 用 Conventional Commits + 中文标题
   - 优先用 HEREDOC 方式传 message，避免 shell 转义破坏信息
3. 禁止添加 Co-Authored-By 或其他 AI/工具署名 trailer
4. 禁止用 `--no-verify` 绕过校验
