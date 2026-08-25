#!/usr/bin/env node
"use strict";

// remember-memory — one-line installer for Claude Code persistent memory.
// Copies hooks + SKILL.md into the target project, writes remember.config.json,
// and merges SessionStart/Stop/SessionEnd hooks into settings.local.json.

const fs = require("fs");
const path = require("path");

const pkgRoot = path.resolve(__dirname, "..");
const hooksSrc = path.join(pkgRoot, "hooks");
const skillSrc = path.join(pkgRoot, "SKILL.md");

function printHelp() {
  console.log(`remember-memory — Claude Code 持久记忆安装器

用法:
  npx -y remember-memory                  # 安装到当前目录
  npx -y remember-memory -p "你的助手名"    # 指定助手署名
  npx -y remember-memory -d D:\\path\\to\\project

选项:
  -d, --dir <路径>      项目目录（默认当前目录）
  -p, --persona <名字>  存档里助手消息的署名（默认 Assistant）
  -m, --marker <标记>   开场注入记忆块的标记（默认 【不忘】）
  --no-settings         只复制文件，不修改 settings.local.json
  -f, --force           覆盖已存在的文件
  -h, --help            显示本帮助`);
}

function parseArgs(argv) {
  const args = {
    dir: process.cwd(),
    persona: "Assistant",
    marker: "【不忘】",
    applySettings: true,
    force: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => (i + 1 < argv.length ? argv[++i] : undefined);
    if (a === "--dir" || a === "-d") args.dir = next();
    else if (a === "--persona" || a === "-p") args.persona = next();
    else if (a === "--marker" || a === "-m") args.marker = next();
    else if (a === "--no-settings") args.applySettings = false;
    else if (a === "--force" || a === "-f") args.force = true;
    else if (a === "--help" || a === "-h") {
      printHelp();
      process.exit(0);
    }
  }
  return args;
}

function copyDir(src, dest, force) {
  fs.mkdirSync(dest, { recursive: true });
  for (const f of fs.readdirSync(src)) {
    const from = path.join(src, f);
    const to = path.join(dest, f);
    if (fs.existsSync(to) && !force) {
      console.log(`  跳过已存在: ${f}（加 -f 覆盖）`);
    } else {
      fs.copyFileSync(from, to);
      console.log(`  已复制: ${f}`);
    }
  }
}

function writeJson(file, obj) {
  fs.writeFileSync(file, JSON.stringify(obj, null, 2) + "\n", "utf8");
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const proj = path.resolve(args.dir);
  if (!fs.existsSync(proj) || !fs.statSync(proj).isDirectory()) {
    console.error(`找不到项目目录: ${proj}`);
    process.exit(1);
  }

  const scriptsDir = path.join(proj, ".claude", "scripts");
  const skillDir = path.join(proj, ".claude", "skills", "remember");
  const memoryDir = path.join(proj, ".claude", "memory", "chatlog");
  fs.mkdirSync(scriptsDir, { recursive: true });
  fs.mkdirSync(skillDir, { recursive: true });
  fs.mkdirSync(memoryDir, { recursive: true });

  console.log(`正在安装 remember-memory 到 ${proj}`);
  copyDir(hooksSrc, scriptsDir, args.force);

  const skillDest = path.join(skillDir, "SKILL.md");
  if (fs.existsSync(skillDest) && !args.force) {
    console.log("  跳过已存在: SKILL.md（加 -f 覆盖）");
  } else {
    fs.copyFileSync(skillSrc, skillDest);
    console.log("  已复制: SKILL.md");
  }

  const cfgFile = path.join(scriptsDir, "remember.config.json");
  if (fs.existsSync(cfgFile) && !args.force) {
    console.log("  保留现有配置: remember.config.json");
  } else {
    writeJson(cfgFile, {
      personaName: args.persona,
      marker: args.marker,
      chatlogRoot: null,
    });
    console.log("  已写入配置: remember.config.json");
  }

  if (args.applySettings) {
    const settingsFile = path.join(proj, ".claude", "settings.local.json");
    if (fs.existsSync(settingsFile)) {
      const ts = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "");
      const bak = `${settingsFile}.bak-${ts}`;
      fs.copyFileSync(settingsFile, bak);
      console.log(`  已备份设置到: ${path.basename(bak)}`);
    }

    const q = (p) => `powershell -NoProfile -ExecutionPolicy Bypass -File "${p}"`;
    const hooks = {
      SessionStart: [
        {
          hooks: [
            { type: "command", command: q(path.join(scriptsDir, "archive-pending.ps1")), timeout: 60 },
            { type: "command", command: q(path.join(scriptsDir, "load-last-chat.ps1")), timeout: 60 },
          ],
        },
      ],
      Stop: [
        {
          hooks: [
            { type: "command", command: q(path.join(scriptsDir, "auto-save.ps1")), timeout: 30 },
          ],
        },
      ],
      SessionEnd: [
        {
          hooks: [
            { type: "command", command: q(path.join(scriptsDir, "archive-pending.ps1")), timeout: 60 },
          ],
        },
      ],
    };

    let existing = {};
    if (fs.existsSync(settingsFile)) {
      try {
        existing = JSON.parse(fs.readFileSync(settingsFile, "utf8"));
      } catch {
        existing = {};
      }
    }
    existing.hooks = hooks;
    fs.writeFileSync(settingsFile, JSON.stringify(existing, null, 2) + "\n", "utf8");
    console.log("  已写入设置: .claude\\settings.local.json");
  } else {
    console.log("  未修改 settings.local.json（--no-settings）");
  }

  console.log("");
  console.log("完成。重启该项目的 Claude Code 即可生效。");
  console.log("体检：运行 .claude\\scripts\\check-memory.ps1");
}

main();
