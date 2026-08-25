# Remember —— Claude Code 跨会话持久记忆系统

无损、防重复、跨会话的 Claude Code 记忆。每一轮对话都先落盘，再归档成干净可读的存档文件，新会话开始时自动把最近的对话注入上下文——让 Agent 一开场就知道上次进行到哪。

## 功能特性

- **写直通日志** —— 每轮对话先写入活缓存，崩溃最多丢一轮
- **双层防重复** —— 按 transcript 记录的水位线拦住"已归档消息再次进缓存"，写盘前的内容哈希再兜底，从根上杜绝孪生存档
- **缓存归属** —— 记录草稿纸属于哪场对话，并发/续聊的会话不会混进同一份存档
- **无损存档** —— 全文保留，永不总结、永不改写、永不自动删除
- **开场自动注入** —— 最近 5 份存档经过去重、过滤空档、超大截断后注入上下文
- **全量索引** —— 每次归档后从磁盘重建 `CHATLOG_INDEX.md`，旧存档永远找得到
- **健康自检** —— `check-memory.ps1` 一条命令对账存档/索引/水位线

## 环境要求

- Claude Code
- Windows PowerShell 5.1+ 或 PowerShell 7（`powershell` / `pwsh`）
- npx 安装方式需要 Node.js 18+（仅安装时需要，运行不需要）
- 零依赖、无需 API Key

## 工作原理

```
聊天轮次 ──▶ Stop 钩子（auto-save.ps1）──▶ _pending.md（活缓存）
                                                 │
会话结束 / 新会话开始 / 缓存超 512KB ───────────▶ archive-pending.ps1
                                                 │
                                        水位线 + 内容哈希双层去重
                                                 │
                              YYYYMMDD/HHmmss_auto.md + CHATLOG_INDEX.md
                                                 │
新会话开场 ──▶ load-last-chat.ps1 ──▶ 注入最近 5 份存档
```

双闸去重不是过度设计：两种失败模式都真实发生过——缓存重建会把已归档消息重新喂回来（水位线解决），水位线万一漏了还会写出孪生存档（内容哈希解决）。单靠任何一道闸都不够，合在一起才关掉"重复归档"这一整类 bug。

## 安装

### 直接让 Agent 装（推荐，零配置）

在 Claude Code、Codex 等支持 Agent Skills 的工具里，直接说：

```
帮我安装这个 skill：https://github.com/Rinademao/remember-memory
```

Agent 会把整个 skill（SKILL.md + hooks 脚本）装进对应的技能目录，不用管路径。

装好之后，在项目里启用记忆（挂上 SessionStart/Stop/SessionEnd 钩子）二选一：

- 在项目目录跑：`npx -y remember-memory -p "你的助手名"`（需要 Node.js 18+，仅安装时需要）
- 或下载本仓库后跑：`.\install.ps1 -ProjectDir <项目路径> -PersonaName "你的助手名" -ApplySettings`（零 Node 依赖）

两者都会复制钩子到 `.claude\scripts\`、skill 到 `.claude\skills\remember\`、写入 `remember.config.json`，并把钩子合并进 `.claude\settings.local.json`（先做 `.bak-时间戳` 备份）。

### 手动安装

```powershell
git clone https://github.com/Rinademao/remember-memory.git
Copy-Item remember-memory\hooks\*.ps1 <项目>\.claude\scripts\
Copy-Item remember-memory\SKILL.md <项目>\.claude\skills\remember\
```

再按 `settings.example.json` 把钩子配置合并进 `<项目>\.claude\settings.local.json`（`{{PROJECT_DIR}}` 换成项目绝对路径）。

改完重启该项目的 Claude Code，下一个新会话就会自动注入记忆。

### 手动安装

1. 把 `hooks\*.ps1` 复制到 `<项目>\.claude\scripts\`
2. 把 `SKILL.md` 复制到 `<项目>\.claude\skills\remember\`
3. 把 `settings.example.json` 内容合并进 `<项目>\.claude\settings.local.json`（如有其他配置请保留），并把 `{{PROJECT_DIR}}` 替换成项目绝对路径
4. 可选：把 `remember.config.example.json` 复制为钩子旁的 `remember.config.json` 并按需修改

### 全局安装

把钩子复制到 `~\.claude\scripts\remember\`，并在 `remember.config.json`（或环境变量 `REMEMBER_CHATLOG_ROOT`）里指定 `chatlogRoot`——脚本默认的目录推导只适用于钩子位于项目 `.claude\scripts\` 内的安装方式。

## 配置

`remember.config.json`（放在钩子脚本旁边）：

```json
{
  "personaName": "Assistant",
  "marker": "【不忘】",
  "chatlogRoot": null
}
```

| 字段 | 默认值 | 作用 |
|------|--------|------|
| `personaName` | `Assistant` | 存档里助手消息的署名 |
| `marker` | `【不忘】` | 开场注入记忆块的标记前缀 |
| `chatlogRoot` | 自动推导 | 存档目录的绝对路径覆盖 |

环境变量可覆盖配置文件：`REMEMBER_PERSONA`、`REMEMBER_MARKER`、`REMEMBER_CHATLOG_ROOT`。

## 使用

- 无需任何操作——新会话开场自动加载记忆
- 说 **"不忘" / "remember"** 强制深度回忆
- 随时运行 `check-memory.ps1` 体检
- 想翻更早的记录就看 `CHATLOG_INDEX.md` 按日期找

## 目录结构

```
remember-memory/
├── SKILL.md                 # Claude Code skill 定义（通用模板）
├── hooks/
│   ├── remember-common.ps1  # 公共函数 + 配置读取
│   ├── auto-save.ps1        # Stop 钩子：每轮写入活缓存
│   ├── archive-pending.ps1  # SessionStart/SessionEnd：归档 + 重建索引
│   ├── load-last-chat.ps1   # SessionStart：注入最近存档
│   └── check-memory.ps1     # 健康自检
├── settings.example.json    # 钩子配置模板
├── remember.config.example.json
├── install.ps1              # 一键安装
└── LICENSE                  # MIT
```

## 已知限制

- 去重哈希对正文是字节级精确的：同一生成路径产生的重复一定能拦住；手工改动过空白差异的文件会被视为不同
- 索引摘要是每条存档的第一条用户消息
- 不做语义/向量检索——本模板刻意保持全文保真，不为检索牺牲完整性

## 协议

MIT
