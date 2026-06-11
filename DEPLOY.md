# MacOCR 分发与部署

## 本地运行

### 方式一：双击 .app（推荐）

将 `MacOCR.app` 复制到 `/Applications/`，执行一次去隔离：

```bash
xattr -cr /Applications/MacOCR.app
```

之后双击即可运行。后端自动启动，无需手动操作。

### 方式二：开发模式

先启动 Python 后端，再 Xcode 运行 SwiftUI 前端：

```bash
cd /path/to/MacOCR
PYTHONPATH="$(pwd)" PythonBackend/.venv/bin/python -m uvicorn PythonBackend.server:app --port 8765
```

然后 Xcode → ⌘R 运行。

## 分发给他人的 Mac

### 直接复制 .app

将 `MacOCR.app` 复制到目标电脑的 `/Applications/`，对方执行：

```bash
xattr -cr /Applications/MacOCR.app
```

然后双击即可。

**前置条件：**
- macOS 14+ 
- Apple Silicon（M1/M2/M3/M4/M5）
- 不需要安装 Python 或其他依赖

### 制作 DMG（推荐分发方式）

```bash
cd /path/to/MacOCR
bash Scripts/create_dmg.sh
```

生成的 `Distribution/MacOCR.dmg` 可以直接发给他人。对方挂载 DMG 后拖入 `/Applications/`，右键 →「打开」即可绕过 Gatekeeper。

## 签名与公证（可选）

以下操作需要 Apple Developer Program 会员（$99/年）。

```bash
DEVELOPER_ID="Developer ID Application: Name (TEAM)" \
APPLE_ID="your@email.com" \
APPLE_TEAM_ID="TEAMID" \
APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
  bash Scripts/sign_and_notarize.sh \
  build/DerivedData/Build/Products/Release/MacOCR.app
```

公证后用户可直接双击打开，无需右键或执行任何命令。

## 限制

| 限制 | 说明 |
|------|------|
| 仅 Apple Silicon | Intel Mac 不支持（Python 运行时仅 ARM64） |
| 仅 macOS 14+ | 依赖 Vision 框架和 SwiftUI API |
| 未签名版本 | 首次启动需 `xattr -cr` 移除隔离标记 |
| 无法从 App Store 分发 | 未经过 App Store 审核 |

## 常见问题

**Q: 双击后提示「无法打开，因为无法验证开发者」**

执行 `xattr -cr /Applications/MacOCR.app` 移除隔离标记。

**Q: 双击后无响应或连接错误**

等待 5-10 秒，Python 后端需要启动时间。如果持续报错，检查 8765 端口是否被占用。

**Q: 导入文件后服务器 500 错误**

确保 `~/Library/Application Support/MacOCR/` 目录存在且可写。重启应用一般可解决。

**Q: 图片文件无法 OCR**

支持 PNG / JPG / TIFF / BMP / HEIC / WebP。确保图片是截图或包含文字的照片。
