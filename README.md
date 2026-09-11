# LuckyHook

瑞幸咖啡 App 账号 Token 一键读取 / 更换工具（Theos tweak，悬浮窗 UI）。

## 功能

- 🔑 **悬浮球**：可拖动，点击展开面板
- 📋 **一键读取**：显示当前 App 内实际使用的 Token，可复制
- ✏️ **一键更换**：粘贴新 Token → 应用并自动重启 App
- 🔄 **持久化**：写入后重启 App 依然生效

## 产物

| 文件 | 说明 |
|---|---|
| `LuckyHook.dylib` | 通用二进制（arm64 + arm64e），169–205KB |
| `luckyhook.deb` | 越狱安装包（MobileSubstrate 插件） |
| `Tweak.xm` | 源码 |
| `Makefile` / `control` / `LuckyHook.plist` | Theos 工程文件 |

## 安装

**方式 A — 越狱设备**
```sh
dpkg -i luckyhook.deb
```
安装路径：`/Library/MobileSubstrate/DynamicLibraries/`

**方式 B — 注入 IPA（免越狱）**

用注入工具（Erosion / TrollFools / 万能签等）把 `LuckyHook.dylib` 注入目标 App，重签后安装。

**方式 C — 自行编译**
```sh
# 需 Theos 环境
make package
```

## 使用

1. 打开 App，屏幕右侧出现蓝色 🔑 悬浮球
2. 拖动可移动位置，**点击球**展开面板
3. 面板操作：
   - **当前 Token** — 只读显示，点「复制当前」可复制到剪贴板
   - **新 Token** — 输入框，可用「📋 粘贴」从剪贴板填入
   - **接管:开/关** — 切换是否启用 Token 接管（关=只读显示）
   - **✅ 应用并重启** — 写入并自动重启 App
4. 重启完成后即使用新 Token

## 配置文件（可选）

无需 UI 也可通过文件配置：

```sh
# 目标 Token
echo -n "<你的Token>" > /var/mobile/Library/Preferences/LuckyHook.txt

# 只观测不改写（排查用）
echo -n "OBSERVE" > /var/mobile/Library/Preferences/LuckyHook.txt

# 关闭自动接管（开=1 / 关=0）
echo -n "0" > /var/mobile/Library/Preferences/LuckyHook.auto
```

或使用 plist：`/var/mobile/Library/Preferences/LuckyHook.plist`

## 实现原理

### 核心：源头注入，而非出站改写

Token 的读取与签名校验发生在**同一处**，因此必须在**读取源头**替换，而不能在请求发出前改写：

```
❌ 错误做法（会报「客户端身份签名未通过」）
   App 读取 Token → 用该 Token 计算签名 → 发出请求前改写请求头 Token
   → 头部 Token 与签名不匹配 → 服务端拒绝

✅ 正确做法
   直接写入 App 的存储 → App 读到的就是新 Token
   → App 自身计算签名时也使用新 Token → 头部、签名、身份三者天然一致
```

### 接管点

| 层 | 处理 |
|---|---|
| `NSUserDefaults`（`com.luckincoffee.network.uid`） | 写入 + 读取接管 |
| MMKV（同名 key） | 写入 + 读取接管 |
| 持久化配置文件 | 每 5 秒节流重载，切换 App 前后台自动生效 |
| `NSMutableURLRequest` 请求头 | **只观测，不改写**（保证签名自洽） |

### 悬浮窗

使用独立 `UIWindow`（`windowLevel = UIWindowLevelAlert + 100`），并在 **Window 层**实现触摸穿透：

```objc
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil;  // 空白区穿透给下层
    return v;
}
```

> 注意：仅在 `UIView` 层做穿透不够，必须在 `UIWindow` 层拦截，否则整个界面会失去触摸响应。

## 调试

运行时会将捕获到的 Token 与来源写入 App 的 Documents 目录：

```
<App Documents>/LuckyHook_dump.txt
```

记录格式：`[来源标签] 值`，来源标签包括：

- `读[uid]` — 从 `NSUserDefaults` 读到的值
- `mmkv[<key>]` — 从 MMKV 读到的值
- `出站[<Header>]` — 出站请求头中观测到的值
- `UI` — 悬浮窗操作记录

## 环境要求

- iOS 15.0+（部署目标 16.5）
- arm64 / arm64e
- 需越狱环境或注入式安装

## 说明

本工具用于自有设备的账号管理，请遵守相关服务条款。
