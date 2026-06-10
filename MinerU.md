**核心要点概括：**

- **部署建议**：MinerU 模型较多，强烈建议在 Mac 上使用 **Conda 虚拟环境** 进行隔离部署，并确保 Mac 已安装 **Homebrew** 和 **Xcode 命令行工具**。
- **核心配置**：必须在配置文件中开启 **Apple Silicon (MPS) 加速**，否则单靠 CPU 跑会非常慢。
- **工作流建议**：建议先用官方提供的 Python 脚本或 CLI（命令行）测试单页 PDF，调通后再写脚本进行批量处理。

### 一、 部署前准备与建议

在 Mac（尤其是 Apple Silicon M1/M2/M3/M4 芯片）上部署 MinerU，请注意以下几点：

1. **统一内存（RAM）建议**：由于 MinerU 会同时加载布局检测（Layout）、公式识别（Formula）和表格理解（Table）等多个模型，建议 Mac 的统一内存至少为 **16GB**。如果是 8GB 内存，建议关闭公式识别模块（可在配置文件中关闭）以防内存溢出（OOM）。
2. **磁盘空间**：模型权重文件总计约 **10GB - 15GB**，请预留足够的存储空间。
3. **环境隔离**：不要直接安装在 Mac 的全局 Python 环境中，务必使用 Conda。

### 二、 MinerU 本地部署完整流程

MinerU 的核心解析引擎是 `magic-pdf`。以下是基于 Mac 系统的标准部署步骤：

#### 步骤 1：安装系统级依赖

Mac 缺乏一些 Linux 自带的图形和 PDF 处理库，需要通过 Homebrew 安装：

Bash

```
# 安装 xcode 命令行工具（如果没装过）
xcode-select --install

# 使用 Homebrew 安装 openjpeg 和 mupdf 依赖
brew install openjpeg mupdf
```

#### 步骤 2：创建并激活 Conda 虚拟环境

建议使用 Python 3.10，这是目前对各类深度学习库兼容性最好的版本。

Bash

```
# 创建名为 mineru 的环境
conda create -n mineru python=3.10 -y

# 激活环境
conda activate mineru
```

#### 步骤 3：安装 magic-pdf 核心包

在 Mac 上，直接安装官方的发布包即可（国内用户可以加清华源加速）：

Bash

```
pip install magic-pdf[full] --extra-index-url https://pypi.tuna.tsinghua.edu.cn/simple
```

> *注：`[full]` 包含了布局、公式、表格等所有功能模块。*

#### 步骤 4：下载模型权重文件

MinerU 需要下载预训练模型才能运行。官方推荐通过 Hugging Face 或 ModelScope（魔搭社区，国内推荐）下载。

1. 安装下载工具：

   Bash

   ```
   pip install modelscope
   ```

2. 创建一个准备存放模型的目录（例如在用户根目录下）：

   Bash

   ```
   mkdir -p ~/mineru_models
   cd ~/mineru_models
   ```

3. 使用 Python 脚本一键下载全部权重（在终端执行以下 Python 代码）：

   Python

   ```
   python -c "
   from modelscope import snapshot_download
   # 下载 Magic-PDF 官方打包的模型库
   snapshot_download('OpenDataLab/PDF-Extract-Kit', local_dir='./PDF-Extract-Kit')
   "
   ```

#### 步骤 5：配置 magic-pdf.json 文件

这是最关键的一步，你需要告诉程序模型下载到了哪里，并开启 Mac 的硬件加速。

1. **生成默认配置文件**：

   在终端运行以下命令，它会在你的用户家目录下生成一个 `magic-pdf.json` 文件：

   Bash

   ```
   # 获取模板路径
   wget https://github.com/opendatalab/MinerU/raw/master/magic-pdf.template.json -O ~/magic-pdf.json
   ```

2. **修改配置文件**：

   使用 Mac 自带的文本编辑器或 VS Code 打开 `~/magic-pdf.json`。

   - 修改 `models-dir`：将其指向你刚刚下载的路径，例如 `"/Users/你的用户名/mineru_models/PDF-Extract-Kit"`。
   - **开启 Mac 加速**：找到 `"device"` 字段，将其修改为 `"mps"`（Metal Performance Shaders，Mac 的 GPU 加速）。如果部分算子报错，可降级为 `"cpu"`。
   - 确保 `"table"` 和 `"formula"` 模块的开关为 `true`。

### 三、 使用与测试

#### 1. 命令行单文件测试（CLI）

选一个包含文字和表格的 PDF 文件，执行以下命令：

Bash

```
magic-pdf -p /path/to/your/document.pdf -o /path/to/output_dir -m auto
```

- `-p`：输入的 PDF 路径。
- `-o`：输出目录。
- `-m`：模式，`auto` 代表自动识别（通常会走基于模型的布局分析）。

解析完成后，去输出目录下查看，你会得到：

- 一个 `.md` 文件（保持了段落顺序的 Markdown 文本）。
- 一个 `images` 文件夹（提取出来的图片和表格截图）。
- 提取出的表格数据的 `.csv` 或 `.html` 文件。

#### 2. Python 批量处理脚本

如果你有大量的文档需要批处理，可以编写一个简单的 Python 脚本：

Python

```
import os
from magic_pdf.pipe.UNIPipe import UNIPipe
from magic_pdf.rw.DiskReaderWriter import DiskReaderWriter

def process_pdf(pdf_path, output_dir):
    # 1. 读取 PDF 二进制数据
    pdf_bytes = open(pdf_path, "rb").read()
    
    # 2. 初始化读写器
    jso_dir = os.path.join(output_dir, "json")
    img_dir = os.path.join(output_dir, "images")
    image_writer = DiskReaderWriter(img_dir)
    
    # 3. 初始化流水线
    pipe = UNIPipe(pdf_bytes, {}, image_writer)
    
    # 4. 执行解析
    pipe.pipe_classify()
    pipe.pipe_parse()
    
    # 5. 获取并保存 Markdown 结果
    md_content = pipe.to_markdown()
    pdf_name = os.path.splitext(os.path.basename(pdf_path))[0]
    
    with open(os.path.join(output_dir, f"{pdf_name}.md"), "w", encoding="utf-8") as f:
        f.write(md_content)

# 使用示例
# process_pdf("my_table_doc.pdf", "./output")
```

### 四、 避坑指南（Mac 专属）

1. **`Library not loaded: libopenjpeg.8.dylib` 报错**：

   如果在运行中提示找不到 `openjpeg`，说明 Homebrew 的路径没有被 Python 识别到。可以通过在 `.zshrc` 中添加环境变量，或者在 Conda 环境中直接安装解决：

   Bash

   ```
   conda install -c conda-forge openjpeg mupdf -y
   ```

2. **内存卡死 / 速度极慢**：

   检查 `magic-pdf.json` 里的 `"device"` 是不是漏配成了 `"cpu"`。如果是 M 系列芯片，一定要确认 `"mps"` 是否生效。如果遇到某些算子 MPS 不支持导致崩溃，可以尝试更新 `torch` 到最新稳定版：

   Bash

   ```
   pip install --upgrade torch torchvision
   ```