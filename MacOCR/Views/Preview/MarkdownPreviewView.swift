import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct MarkdownPreviewView: View {
    let task: OCRTask
    @State private var isEditing = false
    @State private var currentPage: Int = 0
    @State private var pageEdits: [Int: String] = [:]   // page index → edited text
    @State private var dirtyPages: Set<Int> = []         // pages with unsaved edits

    private var isPDF: Bool {
        task.filePath.lowercased().hasSuffix(".pdf")
    }

    private var pages: [String] {
        (task.markdownContent ?? "").components(separatedBy: "\n\n---\n\n")
    }
    private var pageCount: Int { max(pages.count, 1) }

    /// Current page text (edited or original)
    private var currentPageText: String {
        if let edit = pageEdits[currentPage] { return edit }
        guard currentPage >= 0, currentPage < pages.count else { return "" }
        return pages[currentPage]
    }

    /// Page label with dirty marker
    private var pageLabel: String {
        let marker = dirtyPages.contains(currentPage) ? "*" : ""
        return "\(currentPage + 1)\(marker) / \(pageCount)"
    }

    /// Full markdown content with all edits merged in
    private var currentFullContent: String {
        var merged = pages
        for (idx, text) in pageEdits {
            if idx < merged.count { merged[idx] = text }
        }
        return merged.joined(separator: "\n\n---\n\n")
    }

    var body: some View {
        HSplitView {
            // Left: Markdown preview or editor
            if isEditing {
                TextEditor(text: Binding(
                    get: { currentPageText },
                    set: { newValue in
                        pageEdits[currentPage] = newValue
                        dirtyPages.insert(currentPage)
                    }
                ))
                .font(.body.monospaced())
                .frame(minWidth: 300)
            } else {
                MarkdownWebView(markdown: currentPageText)
                    .frame(minWidth: 300)
            }

            // Right: Preview (PDF or image)
            if FileManager.default.fileExists(atPath: task.filePath) {
                if isPDF {
                    PDFPreviewView(
                        url: URL(fileURLWithPath: task.filePath),
                        currentPage: $currentPage
                    )
                    .frame(minWidth: 300, minHeight: 400)
                } else {
                    ImagePreviewView(url: URL(fileURLWithPath: task.filePath))
                        .frame(minWidth: 300, minHeight: 400)
                }
            }
        }
        .id(task.id)  // Force rebuild on task switch
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

            // Save button — always visible, disabled when no edits
            ToolbarItem(placement: .primaryAction) {
                Button {
                    saveEdits()
                } label: {
                    Label(dirtyPages.isEmpty ? "保存" : "保存 (\(dirtyPages.count))",
                          systemImage: "square.and.arrow.down")
                }
                .disabled(dirtyPages.isEmpty)
                .help(dirtyPages.isEmpty ? "无修改" : "保存所有编辑")
            }

            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $isEditing) {
                    Label(isEditing && !dirtyPages.isEmpty ? "编辑 *" : "编辑",
                          systemImage: dirtyPages.isEmpty ? "pencil" : "pencil.circle.fill")
                }
                .tint(dirtyPages.isEmpty ? .accentColor : .blue)
            }

            // Export uses the live edited content, not stale task.markdownContent
            ToolbarItem(placement: .primaryAction) {
                ExportMenu(task: task, markdownContent: Binding(
                    get: { currentFullContent },
                    set: { _ in }
                ))
            }
        }
    }

    // MARK: - Save

    private func saveEdits() {
        guard !dirtyPages.isEmpty else { return }

        let fullContent = currentFullContent

        // Write to output.md
        if let outputPath = task.outputPath {
            do {
                try fullContent.write(toFile: outputPath, atomically: true, encoding: .utf8)
            } catch {
                // Fallback: save to desktop
                let fallback = NSHomeDirectory() + "/Desktop/" +
                    ((task.fileName as NSString).deletingPathExtension) + "_ocr_edited.md"
                try? fullContent.write(toFile: fallback, atomically: true, encoding: .utf8)
            }
        } else {
            // No output path — save to desktop
            let desktop = NSHomeDirectory() + "/Desktop/" +
                ((task.fileName as NSString).deletingPathExtension) + "_ocr.md"
            try? fullContent.write(toFile: desktop, atomically: true, encoding: .utf8)
        }

        // Update the task's in-memory content
        if let idx = TaskQueueManager.shared.tasks.firstIndex(where: { $0.id == task.id }) {
            TaskQueueManager.shared.tasks[idx].markdownContent = fullContent
        }

        dirtyPages.removeAll()
        pageEdits.removeAll()
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
