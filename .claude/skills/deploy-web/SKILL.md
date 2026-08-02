---
name: deploy-web
description: 把理财助手 Web 端构建并部署到 Firebase Hosting（https://wealth-assistant-5141d.web.app）。当用户说「部署 web」「发布网页版」「更新线上」「重新部署」「手机上打不开新功能」「线上还是旧版」时使用。也用于查看线上版本、回滚到上一版、发临时预览链接。
---

# Web 端部署到 Firebase Hosting

线上地址 **https://wealth-assistant-5141d.web.app**（自带 HTTPS，免费额度对单用户绰绰有余）。
数据安全由 Firestore 规则保证：全库锁死在 UID `oaItzb3ZpvR9uD7h9qrVoghPFei2`，
公网访客只能看到登录页，拿不到任何持仓/分析数据。

固定约定：主仓 `ROOT=/Volumes/external/code/ai/projects/TradingAgents`，
Hosting 配置在根目录 `firebase.json`（public 指向 `app/build/web`）。

## 正式部署

```bash
cd /Volumes/external/code/ai/projects/TradingAgents/app && flutter build web --release \
  && cd /Volumes/external/code/ai/projects/TradingAgents && firebase deploy --only hosting
```

部署前先跑 `flutter test`——线上是用户手机上唯一的入口，别把挂着的代码发上去。
部署后用浏览器面板打开线上地址截图确认，并看 `read_console_messages` 有无报错。

**部署是公开发布行为**：每次执行前要用户明确点头，别因为上次同意过就默认这次也行。

## 预览频道（临时链接，不动正式站）

```bash
cd /Volumes/external/code/ai/projects/TradingAgents && firebase hosting:channel:deploy preview --expires 7d
```

给出一个随机后缀的临时网址，7 天自动失效。适合"先自己看看效果"。

## 查看与回滚

```bash
firebase hosting:releases:list          # 历史版本
firebase hosting:rollback               # 回滚到上一个版本
```

线上出问题时先回滚止血，再在本地定位——别在线上试错。

## 手机当 App 用

iOS 签名/装包麻烦（免费 Apple ID 只有 7 天有效期），Web 版是更省事的路子：
Safari 打开线上地址 → 分享 → 添加到主屏幕，得到全屏图标，行为接近原生 App，
不过期、不用签名。代价是没有推送通知。

## 注意

- 缓存策略已配好：`index.html` 和 service worker 是 no-cache，带哈希的资源缓存一年
  ——所以重新部署后用户刷新即见新版，不用教用户清缓存
- 改了 Firestore 规则或索引要单独部署：`firebase deploy --only firestore`
- Firebase Auth 默认已授权 `.web.app` / `.firebaseapp.com` 域名，登录开箱可用；
  以后绑自定义域名要去 Authentication → Settings → Authorized domains 里加
- 构建产物约 36 MB，`app/build/` 已被 git 忽略，不要提交
