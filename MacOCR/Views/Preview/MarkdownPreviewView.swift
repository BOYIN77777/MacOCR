import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct MarkdownPreviewView: View {
    let task: OCRTask
    @State private var editedContent: String = ""
    @State private var isEditing = false
    @State private var currentPage: Int = 0

    private var isPDF: Bool {
        task.filePath.lowercased().hasSuffix(".pdf")
    }

    private var pages: [String] {
        (task.markdownContent ?? "").components(separatedBy: "\n\n---\n\n")
    }
    private var pageCount: Int { max(pages.count, 1) }
    private var currentMarkdown: String {
        guard currentPage >= 0, currentPage < pages.count else { return task.markdownContent ?? "" }
        return pages[currentPage]
    }

    var body: some View {
        HSplitView {
            // Left: Markdown preview
            if isEditing {
                TextEditor(text: $editedContent)
                    .font(.body.monospaced())
                    .frame(minWidth: 300)
            } else {
                MarkdownWebView(markdown: editedContent.isEmpty ? currentMarkdown : editedContent)
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

                    Text("\(currentPage + 1) / \(pageCount)")
                        .font(.caption.monospaced())
                        .frame(minWidth: 60)

                    Button { if currentPage < pageCount - 1 { currentPage += 1 } } label: {
                        Image(systemName: "chevron.right")
                    }.disabled(currentPage >= pageCount - 1)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $isEditing) { Label("编辑", systemImage: "pencil") }
            }

            ToolbarItem(placement: .primaryAction) {
                ExportMenu(task: task, markdownContent: $editedContent)
            }
        }
        .onAppear {
            editedContent = task.markdownContent ?? ""
        }
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
        context.coordinator.observer = view.observePageChanges { page in
            DispatchQueue.main.async {
                currentPage = page
            }
        }
        return view
    }

    func updateNSView(_ nsView: PDFKitView, context: Context) {
        // Only navigate if the target page differs (prevents feedback loop)
        if nsView.currentPageIndex != currentPage {
            nsView.goToPage(currentPage)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var observer: NSKeyValueObservation?
    }
}

final class PDFKitView: NSView {
    private let pdfView = PDFView()

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

    func observePageChanges(handler: @escaping (Int) -> Void) -> NSKeyValueObservation {
        pdfView.observe(\.currentPage, options: [.new]) { pdfView, _ in
            if let doc = pdfView.document, let page = pdfView.currentPage {
                handler(doc.index(for: page))
            }
        }
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
