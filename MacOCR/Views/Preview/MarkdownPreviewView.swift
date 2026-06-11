import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct MarkdownPreviewView: View {
    let task: OCRTask
    @ObservedObject private var queueManager = TaskQueueManager.shared
    @State private var isEditing = false
    @State private var currentPage: Int = 0
    @State private var editText: String = ""
    @State private var pageEdits: [Int: String] = [:]
    @State private var dirtyPages: Set<Int> = []
    @State private var didInitialLoad = false

    /// Live task from queue manager (reflects saves)
    private var liveTask: OCRTask? {
        queueManager.tasks.first(where: { $0.id == task.id })
    }
    private var markdownContent: String {
        liveTask?.markdownContent ?? task.markdownContent ?? ""
    }
    private var isPDF: Bool { task.filePath.lowercased().hasSuffix(".pdf") }

    private let separator = "\n\n---\n\n"

    private var pages: [String] {
        markdownContent.components(separatedBy: separator)
    }
    private var pageCount: Int { max(pages.count, 1) }

    /// Page text shown in preview (edited or original)
    private var displayText: String {
        if isEditing { return editText }
        if let edit = pageEdits[currentPage] { return edit }
        guard currentPage >= 0, currentPage < pages.count else { return "" }
        return pages[currentPage]
    }

    private var pageLabel: String {
        let marker = dirtyPages.contains(currentPage) ? "*" : ""
        return "\(currentPage + 1)\(marker) / \(pageCount)"
    }

    /// Load editor text for the current page
    private func loadEditText() {
        editText = pageEdits[currentPage] ?? (currentPage < pages.count ? pages[currentPage] : "")
        didInitialLoad = true
    }

    /// Mark current page as edited
    private func markDirty() {
        guard didInitialLoad else { return }
        pageEdits[currentPage] = editText
        dirtyPages.insert(currentPage)
    }

    /// Full content with all edits merged
    private var mergedContent: String {
        var result = pages
        for (idx, text) in pageEdits { if idx < result.count { result[idx] = text } }
        return result.joined(separator: separator)
    }

    var body: some View {
        HSplitView {
            if isEditing {
                TextEditor(text: $editText)
                    .font(.body.monospaced())
                    .frame(minWidth: 300)
                    .onChange(of: currentPage) { _, _ in loadEditText() }
                    .onChange(of: editText) { _, _ in markDirty() }
            } else {
                MarkdownWebView(markdown: displayText)
                    .frame(minWidth: 300)
            }

            if FileManager.default.fileExists(atPath: task.filePath) {
                if isPDF {
                    PDFPreviewView(url: URL(fileURLWithPath: task.filePath), currentPage: $currentPage)
                        .frame(minWidth: 300, minHeight: 400)
                } else {
                    ImagePreviewView(url: URL(fileURLWithPath: task.filePath))
                        .frame(minWidth: 300, minHeight: 400)
                }
            }
        }
        .id(task.id)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 4) {
                    Button { if currentPage > 0 { currentPage -= 1 } } label: {
                        Image(systemName: "chevron.left")
                    }.disabled(currentPage <= 0)

                    Text(pageLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(dirtyPages.contains(currentPage) ? .blue : .primary)
                        .frame(minWidth: 60)

                    Button { if currentPage < pageCount - 1 { currentPage += 1 } } label: {
                        Image(systemName: "chevron.right")
                    }.disabled(currentPage >= pageCount - 1)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    saveEdits()
                } label: {
                    Label(dirtyPages.isEmpty ? "保存" : "保存 (\(dirtyPages.count))",
                          systemImage: "square.and.arrow.down")
                }
                .disabled(dirtyPages.isEmpty)
            }

            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $isEditing) {
                    Label(dirtyPages.isEmpty ? "编辑" : "编辑 *",
                          systemImage: dirtyPages.isEmpty ? "pencil" : "pencil.circle.fill")
                }
                .tint(dirtyPages.isEmpty ? .accentColor : .blue)
                .onChange(of: isEditing) { _, editing in
                    if editing {
                        loadEditText()
                    } else {
                        // Save current page edits when toggling out of edit mode
                        if didInitialLoad, editText != (pageEdits[currentPage] ?? pages[currentPage]) {
                            pageEdits[currentPage] = editText
                            dirtyPages.insert(currentPage)
                        }
                    }
                }
            }

            ToolbarItem(placement: .primaryAction) {
                ExportMenu(task: task, markdownContent: Binding(
                    get: { mergedContent },
                    set: { _ in }
                ))
            }
        }
    }

    // MARK: - Save

    private func saveEdits() {
        // Flush current page edits first
        if didInitialLoad, isEditing {
            pageEdits[currentPage] = editText
            dirtyPages.insert(currentPage)
        }

        guard !dirtyPages.isEmpty else { return }
        let content = mergedContent

        if let path = task.outputPath {
            let url = URL(fileURLWithPath: path)
            try? content.write(to: url, atomically: true, encoding: .utf8)
        } else {
            let name = (task.fileName as NSString).deletingPathExtension + "_ocr.md"
            let url = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Desktop").appendingPathComponent(name)
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }

        // Update in-memory
        if let idx = TaskQueueManager.shared.tasks.firstIndex(where: { $0.id == task.id }) {
            TaskQueueManager.shared.tasks[idx].markdownContent = content
        }

        dirtyPages.removeAll()
        pageEdits.removeAll()
        didInitialLoad = false
    }
}

// MARK: - WebView for Markdown Rendering

struct MarkdownWebView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let html = renderMarkdown(markdown)
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func renderMarkdown(_ md: String) -> String {
        let escaped = md
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
        <style>
            :root { color-scheme: light dark; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                line-height: 1.6;
                padding: 20px;
                max-width: 800px;
                margin: 0 auto;
                color: -apple-system-label;
                background: -apple-system-background;
            }
            pre { background: rgba(0,0,0,0.05); padding: 12px; border-radius: 6px; overflow-x: auto; }
            code { font-family: 'SF Mono', Menlo, monospace; font-size: 0.9em; }
            table { border-collapse: collapse; width: 100%; margin: 1em 0; }
            th, td { border: 1px solid rgba(0,0,0,0.15); padding: 8px 12px; text-align: left; }
            img { max-width: 100%; height: auto; }
            @media (prefers-color-scheme: dark) {
                pre { background: rgba(255,255,255,0.05); }
                th, td { border-color: rgba(255,255,255,0.15); }
            }
        </style>
        </head>
        <body>
            <div id="content"></div>
            <script>
                document.getElementById('content').innerHTML = marked.parse(`\(escaped)`);
            </script>
        </body>
        </html>
        """
    }
}

// MARK: - PDF Preview

import PDFKit

struct PDFPreviewView: NSViewRepresentable {
    let url: URL
    @Binding var currentPage: Int

    func makeNSView(context: Context) -> PDFKitView {
        let view = PDFKitView()
        view.loadPDF(from: url)
        // Observe PDF page changes via PDFKit notification (more reliable than KVO)
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: view.pdfView, queue: .main
        ) { _ in
            currentPage = view.currentPageIndex
        }
        return view
    }

    func updateNSView(_ nsView: PDFKitView, context: Context) {
        // Navigate PDF when toolbar changes the page
        if nsView.currentPageIndex != currentPage {
            nsView.goToPage(currentPage)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var observer: Any?
    }
}

final class PDFKitView: NSView {
    let pdfView = PDFView()

    var pageCount: Int { pdfView.document?.pageCount ?? 0 }
    var currentPageIndex: Int {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { return 0 }
        return doc.index(for: page)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pdfView.autoresizingMask = [.width, .height]
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .vertical
        pdfView.frame = bounds
        addSubview(pdfView)
    }

    override func layout() {
        super.layout()
        pdfView.frame = bounds
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func loadPDF(from url: URL) {
        guard let document = PDFDocument(url: url) else { return }
        pdfView.document = document
        pdfView.frame = bounds
    }

    func goToPage(_ pageIndex: Int) {
        guard let doc = pdfView.document,
              pageIndex >= 0, pageIndex < doc.pageCount,
              let page = doc.page(at: pageIndex) else { return }
        pdfView.go(to: page)
    }
}

// MARK: - Image Preview

import AppKit

struct ImagePreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        if let image = NSImage(contentsOf: url) {
            view.image = image
        }
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {}
}
