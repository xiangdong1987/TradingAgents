# Assistant Runner 部署指南

`assistant/` 是一个无人值守的 launchd 定时任务：每 15 分钟醒来一次，依次做僵尸任务清理、认领用户请求的
job、按 watchlist 规划到期的日报/深度分析 job、复盘到期建议，所有状态都存在 Firestore 里，进程跑完就退出。

按下面的步骤顺序操作，即可从零跑通。

1. **Firebase 项目创建**（手动，Firebase 控制台操作）

   打开 https://console.firebase.google.com → 新建项目（不需要勾选 Google Analytics）→ 左侧 Build →
   Firestore Database → Create database，选择 Native mode，区域可任选 `us-east` 系列中的一个。

2. **服务账号密钥**

   Project settings → Service accounts → Generate new private key，下载得到的 JSON 保存为
   `~/.tradingagents/firebase-service-account.json`，并执行 `chmod 600 ~/.tradingagents/firebase-service-account.json`
   收紧权限（默认路径无需设置 `TRADINGAGENTS_FIREBASE_CREDENTIALS`；若保存到其他路径，在 `.env` 里设置该变量指向实际文件）。

3. **安全规则与索引**

   说明：规则与索引已在仓库内（firebase/firestore.rules 已钉死唯一账号 UID；firebase/firestore.indexes.json 覆盖 App 查询所需索引），部署命令：

   ```bash
   firebase deploy --only firestore --project wealth-assistant-5141d
   ```

   换账号/换项目时需更新 rules 里的 UID 与 .firebaserc 的项目 ID。

4. **依赖安装**

   ```bash
   .venv/bin/pip install -r requirements.txt
   ```

5. **初始数据**

   在 Firestore 控制台手工建一个 `watchlist/NVDA` 文档作冒烟数据：

   ```json
   {
     "ticker": "NVDA",
     "deepFreq": "weekly",
     "note": "",
     "addedAt": "2026-08-01T00:00:00+00:00"
   }
   ```

   `addedAt` 用 ISO 8601 时间戳（与系统里其他时间字段一致），示例中的日期替换成实际添加当天即可。

6. **冒烟验证**

   手动跑一次 runner：

   ```bash
   .venv/bin/python -m assistant.runner
   ```

   若在收盘后运行，去 Firestore 控制台看 `briefs/` 集合下是否出现了今日日期的文档。

   也可以手工建一条 `jobs` 文档触发深度分析：

   ```json
   {
     "type": "deep_analysis",
     "ticker": "NVDA",
     "status": "queued",
     "requestedBy": "user",
     "createdAt": "2026-08-01T12:00:00+00:00"
   }
   ```

   （`createdAt` 用当前时刻的 ISO 时间戳）再跑一次 `.venv/bin/python -m assistant.runner`，确认
   `analyses/`、`suggestions/` 集合下各生成了一条新文档，且该 `jobs` 文档的 `status` 变为 `done`。

   > **注意**：`has_analysis_since` 在真实 Firestore 上是一个 `ticker ==` 与 `createdAt >=` 组合的查询，
   > 需要一个复合索引（composite index）才能执行。第一次触发时控制台会在错误信息里给出一个一键创建索引的
   > 链接，点开并创建索引即可，之后同样的查询就能正常工作。

7. **launchd 安装**

   ```bash
   cp scripts/com.tradingagents.assistant.plist ~/Library/LaunchAgents/
   launchctl load ~/Library/LaunchAgents/com.tradingagents.assistant.plist
   ```

   卸载：

   ```bash
   launchctl unload ~/Library/LaunchAgents/com.tradingagents.assistant.plist
   ```

   看日志：

   ```bash
   tail -f /tmp/tradingagents-assistant.log
   tail -f /tmp/tradingagents-assistant.err.log
   ```

8. **成本提示**

   - 日报（daily brief）每天一次，是一次 quick-think LLM 调用，成本约几美分。
   - 每次深度分析（deep analysis）是一次完整的多 agent run（分析师 + 辩论 + 风险评估等），成本在数美元
     量级，具体取决于所配置的模型（深度思考模型通常比 quick-think 模型贵得多）。

9. **免责声明**

   本系统所有产出（日报、深度分析、交易建议）均为软件自动生成的分析信息，不构成投资建议；相关交易决策与
   执行均由用户自行在其券商完成，本系统不代为下单、不承担投资结果的责任。

## Flutter 客户端（app/）

app/ 是 Flutter 客户端（Android + macOS）；`cd app && flutter run` 运行；换 Firebase 项目时用 `flutterfire configure --project=<id> --platforms=android,macos` 重新生成 lib/firebase_options.dart；测试 `flutter test`。完整部署流程见上述各步骤。
