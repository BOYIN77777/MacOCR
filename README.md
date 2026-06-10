# MacOCR

macOS 原生 OCR 工具，将 PDF 转换为 Markdown。支持扫描件、文字型、混合型（表格+公式）文档。

## 架构

```
 MacOCR.app (SwiftUI)
      │  HTTP REST (localhost:8765)
      ▼
 Python Backend (FastAPI)
      │
      ├── Apple Vision        OCR 主力引擎（ANE 加速，0.5s/页）
      ├── fitz (PyMuPDF)      文字提取（0.04ms/页）
      ├── RapidTable           表格识别 → HTML
      └── MFD + MFR (Unimernet) 公式检测 + 识别 → LaTeX
```

### 管道流程

```
文档 → _preflight() 前5页采样 → 文档级分类
  ├─ scanned   → Vision OCR
  ├─ text      → fitz 提取（瞬间）
  ├─ table     → RapidTable → HTML
  └─ formula   → MFD+MFR → LaTeX（3页无输出→自适应切 text）
```

**核心设计**：文档级预检（非逐页判断）+ 按需加载模型 + 自适应模式切换。

### 已移除的组件

| 组件 | 原因 |
|------|------|
| LayoutLMv3 (~3GB) | 分类不可靠，同一页面不同运行结果不同 |
| PaddleOCR (~1GB) | 速度慢 1.5×，质量与 Vision 持平，实测无优势 |
| CustomPEKModel | 强制预加载全部模型，改为直接调用 AtomModelSingleton |

## 前置条件

- macOS 14+ (Apple Silicon)
- Xcode 16+
- Python 3.12

## 快速开始

```bash
# 1. 创建 Python 虚拟环境
python3.12 -m venv PythonBackend/.venv
source PythonBackend/.venv/bin/activate
pip install -r PythonBackend/requirements.txt

# 2. 模型准备（RapidTable + MFD + MFR，约 5GB）
# 首次运行自动下载到 ~/Library/Application Support/MacOCR/models/

# 3. 启动后端
PYTHONPATH="$(pwd)" PythonBackend/.venv/bin/python -m uvicorn PythonBackend.server:app --port 8765

# 4. 打开 Xcode 项目，运行 MacOCR scheme
open MacOCR.xcodeproj
```

## 性能

| 场景 | 页数 | 耗时 | 内存 | 加载模型 |
|------|------|------|------|---------|
| 扫描教科书 | 422 | 4.5min | ~4.6GB | 无 |
| 文字型 PDF | 3 | 0.4s | — | 无 |
| 混合论文 | 40 | ~30s | ~5GB | MFD+MFR |
| 表格型 | 5 | 6.6s | ~5GB | RapidTable |

## 项目结构

```
MacOCR/
├── MacOCR/                    SwiftUI 应用
│   ├── App/                   入口
│   ├── Models/                数据模型
│   ├── Views/                 UI 视图（导入/队列/预览/导出/设置）
│   └── Services/              核心服务
│       ├── PythonBackendManager   后端生命周期管理
│       ├── OCRServiceClient       HTTP 客户端
│       ├── VisionOCRService       Apple Vision OCR（快速模式）
│       └── TaskQueueManager       任务队列调度
├── PythonBackend/             FastAPI 后端
│   ├── server.py              入口
│   ├── api/
│   │   └── routes_ocr.py       REST API 路由
│   ├── services/
│   │   ├── lightweight_pipeline.py   核心管道 (~700行)
│   │   ├── vision_text_detector.py   Apple Vision OCR + 页面分类
│   │   ├── pdf_ocr_service.py        FastAPI 集成层
│   │   └── image_ocr_service.py      图片 OCR
│   └── core/
│       ├── progress.py         进度追踪 + 流式端点
│       ├── config.py           配置管理
│       └── exceptions.py       异常定义
└── Scripts/                   构建和打包
    ├── build_python_env.sh    构建可重定位 Python 运行时
    ├── patch_magic_pdf.sh     修复 magic-pdf 兼容性问题
    ├── package_app.sh         打包 .app
    ├── bundle_dylibs.sh       修复原生库路径
    └── sign_and_notarize.sh   签名 + 公证
```

## API 接口

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/v1/health` | 健康检查 |
| GET | `/api/v1/models/status` | 模型状态 |
| POST | `/api/v1/ocr/upload?method=auto` | 上传文件并 OCR |
| GET | `/api/v1/ocr/tasks/{id}` | 查询任务进度（含 `completed_pages` + `latest_content`） |
| DELETE | `/api/v1/ocr/tasks/{id}` | 取消任务 |

## 打包发行

```bash
bash Scripts/build_python_env.sh
bash Scripts/package_app.sh
DEVELOPER_ID="Developer ID Application: Name (TEAM)" \
  bash Scripts/sign_and_notarize.sh build/DerivedData/Build/Products/Release/MacOCR.app
```

## License

MIT
