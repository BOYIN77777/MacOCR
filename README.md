# MacOCR

macOS 原生 OCR 工具，将 PDF 和图片转换为 Markdown。支持扫描件、文字型、混合型（表格+公式）文档。

## 功能特性

- **文档 OCR**：扫描件 PDF → Apple Vision OCR（ANE 加速，0.5s/页）
- **文字提取**：内嵌文字 PDF → fitz 直接提取（0.04ms/页，瞬间）
- **图片 OCR**：PNG / JPG / TIFF / BMP / HEIC / WebP 截图识别
- **表格识别**：RapidTable → HTML 表格输出
- **公式识别**：MFD + MFR (Unimernet) → LaTeX 输出
- **页眉页脚过滤**：自动排除边缘区域文字污染
- **逐页预览**：Markdown 渲染 + PDF/图片原文左右对比
- **分页联动**：翻页同步，Markdown 与原文页码对应
- **编辑保存**：逐页编辑 OCR 结果，保存回写文件
- **进度条**：实时显示页码进度 + 阶段名称 + 百分比
- **导出**：Markdown / 纯文本 / PDF 三种格式

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

图片（PNG/JPG等）→ cv2.imread → Vision OCR 单页处理
```

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
| 扫描教科书 | 422 | 5min | ~4.6GB | 无 |
| 文字型 PDF | 3 | 0.4s | — | 无 |
| 图片 PNG/JPG | 1 | 0.5s | — | 无 |
| 混合论文 | 40 | ~30s | ~5GB | MFD+MFR |
| 表格型 | 5 | 6.6s | ~5GB | RapidTable |

## 项目结构

```
MacOCR/
├── MacOCR/                        SwiftUI 应用
│   ├── App/                       入口
│   ├── Models/
│   │   └── OCRTask.swift          任务数据模型
│   ├── Views/
│   │   ├── MainWindow/            主窗口布局
│   │   ├── Import/                拖拽导入区
│   │   ├── Queue/                 任务列表 + 进度条
│   │   ├── Preview/               Markdown/PDF/图片预览 + 编辑
│   │   └── Export/                导出菜单
│   └── Services/
│       ├── PythonBackendManager   后端生命周期（自动启动/停止）
│       ├── OCRServiceClient       HTTP 客户端 + multipart 上传
│       ├── TaskQueueManager       任务队列调度 + 大文件确认
│       └── VisionOCRService       Apple Vision OCR（快速模式）
├── PythonBackend/                 FastAPI 后端
│   ├── server.py                  入口（工作目录自动切到可写位置）
│   ├── api/
│   │   ├── routes_ocr.py          上传 + OCR 路由
│   │   ├── routes_models.py       模型状态路由
│   │   └── routes_health.py       健康检查路由
│   ├── services/
│   │   ├── lightweight_pipeline.py   核心管道 (~700行)
│   │   ├── vision_text_detector.py   Vision OCR + 页眉页脚过滤 + 页面分类
│   │   ├── pdf_ocr_service.py        PDF OCR 集成层
│   │   ├── image_ocr_service.py      图片→PDF 转换 + OCR
│   │   ├── model_manager.py          模型状态检查
│   │   └── task_manager.py           后端任务管理
│   └── core/
│       ├── progress.py             进度追踪
│       ├── config.py               配置管理
│       └── exceptions.py           异常定义
└── Scripts/                       构建和打包
    ├── build_python_env.sh        构建可重定位 Python 运行时
    ├── patch_magic_pdf.sh         修复 magic-pdf 兼容性问题
    ├── package_app.sh             打包 .app（含自动签名）
    ├── bundle_dylibs.sh           修复原生库路径
    ├── create_dmg.sh              生成 DMG 安装包
    └── sign_and_notarize.sh       签名 + 公证
```

## API 接口

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/v1/health` | 健康检查 |
| GET | `/api/v1/models/status` | 模型状态 |
| POST | `/api/v1/ocr/upload?method=auto` | 上传文件并 OCR（支持 PDF/PNG/JPG/TIFF/BMP/HEIC/WebP） |
| GET | `/api/v1/ocr/tasks/{id}` | 查询任务进度（含 `completed_pages` + `latest_content`） |
| DELETE | `/api/v1/ocr/tasks/{id}` | 取消任务 |

## 打包发行

```bash
bash Scripts/build_python_env.sh
bash Scripts/package_app.sh

# .app 在 build/DerivedData/Build/Products/Release/MacOCR.app

# 可选：生成 DMG + 签名公证
bash Scripts/create_dmg.sh
DEVELOPER_ID="Developer ID Application: Name (TEAM)" \
  bash Scripts/sign_and_notarize.sh build/DerivedData/Build/Products/Release/MacOCR.app
```

## License

MIT
