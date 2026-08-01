# wealth_assistant Flutter 客户端

理财助手的 Flutter 客户端（Android + macOS），实时读取 Firestore 展示日报与投资建议。

## 快速开始

运行客户端（本目录下）：
```bash
flutter run -d chrome     # 本地开发推荐：浏览器直接跑，无需模拟器/桌面构建
flutter run               # Android 模拟器 / macOS 桌面
```

运行测试：
```bash
flutter test
```

更换 Firebase 项目时，重新生成配置：
```bash
flutterfire configure --project=wealth-assistant-5141d --platforms=android,macos,web
```

完整部署流程与后端 runner 配置详见 [assistant/README.md](../assistant/README.md)。
