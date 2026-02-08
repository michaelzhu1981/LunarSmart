# LunarSmart

LunarSmart 是一个基于 SwiftUI 的农历日程工具，用于把农历日期规则转换为 Apple 日历中的事件或提醒事项。

## 功能概览

- 创建农历规则（标题、备注、地点、目标类型）
- 支持按农历月/日配置重复策略
- 支持闰月相关设置与缺失日期处理策略
- 支持重复结束条件（按次数或截止日期）
- 预览未来触发日期
- 保存并管理规则，写入 Apple 日历（`EventKit`）

## 技术栈

- Swift
- SwiftUI
- EventKit
- Combine
- Xcode 工程（`LunarSmart.xcodeproj`）

## 运行环境

- macOS（推荐使用最新稳定版本）
- Xcode 16+
- iOS 或 macOS 运行目标（工程已包含跨平台适配代码）

## 快速开始

1. 打开工程：`LunarSmart.xcodeproj`
2. 选择运行目标（iOS Simulator 或 My Mac）
3. 点击 Run（`⌘R`）启动应用
4. 首次写入日历/提醒事项时，授予日历权限

## 项目结构

```text
LunarSmart/
├── LunarSmart/                # 应用主代码
│   ├── LunarSmartApp.swift    # 应用入口
│   ├── ContentView.swift      # 主界面与核心交互逻辑
│   ├── Item.swift             # 示例数据结构
│   └── Assets.xcassets/       # 资源文件
├── LunarSmartTests/           # 单元测试
├── LunarSmartUITests/         # UI 测试
└── LunarSmart.xcodeproj       # Xcode 工程文件
```

## 注意事项

- 本仓库当前包含 `.build` 等构建产物目录，建议按需清理并通过 `.gitignore` 管理。
- 仓库内若出现 `._*` 文件（macOS 扩展属性生成），通常不需要参与开发逻辑。

## License

本项目采用 [MIT License](https://opensource.org/licenses/MIT) 开源许可。
