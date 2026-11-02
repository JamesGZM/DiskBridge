# 贡献指南

项目范围是 macOS 原生应用。请保持 Swift、SwiftUI/AppKit 和系统工具实现，不引入 Python 后台或其他平台客户端。

提交修改前：

```sh
swift test
./scripts/build-app.sh
swift Tools/PrivacyCheck.swift
```

修改数据切换、挂载、还原或清理逻辑时，请为失败与恢复路径增加测试。使用自动生成的临时夹具；真实外置盘测试必须显式启用，不将真实配置或数据提交到仓库。

优先小而清晰的变更。说明触发条件、修复后的行为和实际运行的检查。UI 改动可附使用合成数据的截图，移除账号、用户名、个人路径和其他应用中的内容。

公开问题与 Pull Request 请遵循 [隐私说明](docs/PRIVACY.md)。不要附带密钥、签名证书或聊天文件。

代码贡献采用本项目的 MIT 协议。
