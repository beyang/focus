//
//  TodoView.swift
//  Focus
//
//  Created by Beyang Liu on 7/19/25.
//

import SwiftUI
import AppKit

struct CursorTrackingTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursorPosition: NSRange?
    @Binding var shouldFocus: Bool
    var onChange: () -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = context.coordinator
        
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let textView = nsView.documentView as! NSTextView
        
        if textView.string != text {
            textView.string = text
        }
        
        // Restore cursor position if we have one saved
        if let savedPosition = cursorPosition {
            let safePosition = NSRange(
                location: min(savedPosition.location, text.count),
                length: min(savedPosition.length, text.count - min(savedPosition.location, text.count))
            )
            if textView.selectedRange() != safePosition {
                textView.setSelectedRange(safePosition)
            }
        }
        
        // Focus the text view if requested
        if shouldFocus {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                self.shouldFocus = false
            }
        }
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CursorTrackingTextEditor
        
        init(_ parent: CursorTrackingTextEditor) {
            self.parent = parent
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.cursorPosition = textView.selectedRange()
            parent.onChange()
        }
        
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.cursorPosition = textView.selectedRange()
        }
    }
}

struct TodoView: View {
    @Environment(FocusModel.self) private var model
    @State private var filePath: String = ""
    @State private var isEditing: Bool = false
    @State private var showingFilePathEditor: Bool = false
    @State private var errorMessage: String = ""
    @State private var lastSaveTime: Date?
    @State private var autoSaveTimer: Timer?
    @State private var cursorPosition: NSRange?
    @State private var clickedLineIndex: Int?
    @State private var shouldFocusEditor: Bool = false
    @FocusState private var previewFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // Header with file path
            HStack {
                Text("Todo")
                    .font(.headline)

                Spacer()
                
                Button(action: { showingFilePathEditor.toggle() }) {
                    Image(systemName: "folder")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Change file path")
                
                Button(action: { isEditing.toggle() }) {
                    Image(systemName: isEditing ? "eye" : "pencil")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(isEditing ? "Preview" : "Edit")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor))
            
            // File path editor
            if showingFilePathEditor {
                HStack {
                    TextField("File path (e.g., ~/todo.md)", text: $filePath)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .background(Color.black.opacity(0.1))
                        .cornerRadius(4)
                        .onSubmit {
                            saveFilePath()
                            loadFromFile()
                            showingFilePathEditor = false
                        }
                    
                    Button("Save") {
                        saveFilePath()
                        loadFromFile()
                        showingFilePathEditor = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            }
            
            // Error message
            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
            
            // Main content
            if isEditing {
                // Markdown editor
                CursorTrackingTextEditor(
                    text: $model.todoMarkdown,
                    cursorPosition: $cursorPosition,
                    shouldFocus: $shouldFocusEditor,
                    onChange: { scheduleAutoSave() }
                )
                .background(Color(NSColor.textBackgroundColor))
            } else {
                // Markdown preview
                ScrollView {
                    Group {
                        if model.todoMarkdown.isEmpty {
                            Text("No todos yet. Add one from the command bar, e.g. todo buy milk")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            MarkdownPreview(
                                markdown: $model.todoMarkdown,
                                onChange: { saveToFile() },
                                onLineClick: { lineIndex in
                                    clickedLineIndex = lineIndex
                                }
                            )
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(NSColor.textBackgroundColor))
                .focusable()
                .focusEffectDisabled()
                .focused($previewFocused)
                .onKeyPress(.return) {
                    switchToEditMode()
                    return .handled
                }
                .onTapGesture(count: 2) {
                    switchToEditMode()
                }
                .onTapGesture(count: 1) {
                    // Single tap to ensure focus
                    previewFocused = true
                }
            }
            
            // Status bar
            HStack {
                if let saveTime = lastSaveTime {
                    Text("Saved \(saveTime.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Text(filePath.isEmpty ? "No file selected" : filePath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .onAppear {
            loadFilePath()
            if !filePath.isEmpty {
                loadFromFile()
            }
        }
        .onDisappear {
            saveToFile()
            autoSaveTimer?.invalidate()
        }
        .onKeyPress(keys: [.return], phases: .down) { keyPress in
            if keyPress.modifiers.contains(.command) {
                isEditing.toggle()
                return .handled
            }
            // Plain Enter in preview mode switches to edit
            if !isEditing && keyPress.modifiers.isEmpty {
                switchToEditMode()
                return .handled
            }
            return .ignored
        }
    }
    
    private func switchToEditMode() {
        // If we have a clicked line and no existing cursor position, set cursor to that line
        if cursorPosition == nil, let lineIndex = clickedLineIndex {
            let lines = model.todoMarkdown.components(separatedBy: "\n")
            var charOffset = 0
            for i in 0..<min(lineIndex, lines.count) {
                charOffset += lines[i].count + 1 // +1 for newline
            }
            cursorPosition = NSRange(location: charOffset, length: 0)
        } else if cursorPosition == nil {
            // Default to beginning of text if no position saved
            cursorPosition = NSRange(location: 0, length: 0)
        }
        clickedLineIndex = nil
        isEditing = true
        shouldFocusEditor = true
    }
    
    private func loadFilePath() {
        filePath = model.todoFilePath
    }

    private func saveFilePath() {
        model.todoFilePath = filePath
    }

    private func loadFromFile() {
        do {
            try model.loadTodos()
            errorMessage = ""
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
        }
    }

    private func saveToFile() {
        guard !model.todoFilePath.isEmpty else { return }
        do {
            try model.saveTodos()
            lastSaveTime = Date()
            errorMessage = ""
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }

    private func scheduleAutoSave() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
            saveToFile()
        }
    }
}

struct MarkdownPreview: View {
    @Binding var markdown: String
    var onChange: () -> Void
    var onLineClick: ((Int) -> Void)?

    /// Line of the todo item being dragged by its handle.
    @State private var draggedLine: Int?
    /// Todo item or heading the dragged item is over.
    @State private var dropTarget: MarkdownElement?
    /// Frames of todo items and headings, keyed by line, in the list's coordinate space.
    @State private var targetFrames: [Int: CGRect] = [:]

    private static let coordinateSpace = "todoList"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parseMarkdown(), id: \.id) { element in
                if element.isTodoItem {
                    reorderTarget(
                        HStack(alignment: .top, spacing: 6) {
                            dragHandle(for: element)
                            CheckboxRow(element: element, onToggle: { toggleCheckbox(at: element.lineIndex) })
                                .onTapGesture { onLineClick?(element.lineIndex) }
                        }
                        .opacity(draggedLine == element.lineIndex ? 0.4 : 1),
                        element: element
                    )
                } else if element.isHeading {
                    reorderTarget(
                        element.view
                            .contentShape(Rectangle())
                            .onTapGesture { onLineClick?(element.lineIndex) },
                        element: element
                    )
                } else {
                    element.view
                        .contentShape(Rectangle())
                        .onTapGesture { onLineClick?(element.lineIndex) }
                }
            }
        }
        .coordinateSpace(.named(Self.coordinateSpace))
    }

    // A SwiftUI gesture rather than AppKit drag and drop: the hidden browser tabs'
    // web views sit above this list in AppKit and would swallow drop events.
    private func dragHandle(for element: MarkdownElement) -> some View {
        Image(systemName: "circle.grid.2x2.fill")
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
            .frame(width: 14, height: 16)
            .contentShape(Rectangle())
            .pointerStyle(draggedLine == nil ? .grabIdle : .grabActive)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.coordinateSpace))
                    .onChanged { value in
                        draggedLine = element.lineIndex
                        dropTarget = nearestTarget(to: value.location.y)
                    }
                    .onEnded { _ in
                        if let source = draggedLine, let dropTarget, let insertion = insertionLine(onto: dropTarget) {
                            moveLine(source, before: insertion)
                        }
                        draggedLine = nil
                        dropTarget = nil
                    }
            )
            .help("Drag to reorder")
    }

    /// Records where a todo item or heading is and shows a line where the dragged item will land.
    private func reorderTarget(_ content: some View, element: MarkdownElement) -> some View {
        let insertion = dropTarget?.lineIndex == element.lineIndex ? insertionLine(onto: element) : nil
        return content
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.coordinateSpace))
            } action: { frame in
                targetFrames[element.lineIndex] = frame
            }
            .overlay(alignment: insertion == element.lineIndex ? .top : .bottom) {
                if insertion != nil {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .offset(y: insertion == element.lineIndex ? -4 : 4)
                }
            }
    }

    private func nearestTarget(to y: CGFloat) -> MarkdownElement? {
        parseMarkdown()
            .filter { $0.isTodoItem || $0.isHeading }
            .compactMap { element in targetFrames[element.lineIndex].map { (element, $0) } }
            .min { abs($0.1.midY - y) < abs($1.1.midY - y) }?
            .0
    }

    /// The line the dragged item will be inserted before when dropped on `element`,
    /// or nil when the drop would not move it. Items go below headings; on another
    /// item they go below it when dragged down and above it when dragged up.
    private func insertionLine(onto element: MarkdownElement) -> Int? {
        guard let source = draggedLine else { return nil }
        let insertion = element.isTodoItem && source > element.lineIndex ? element.lineIndex : element.lineIndex + 1
        return insertion == source || insertion == source + 1 ? nil : insertion
    }

    private func moveLine(_ source: Int, before insertion: Int) {
        var lines = markdown.components(separatedBy: "\n")
        guard source < lines.count, insertion <= lines.count else { return }
        let line = lines.remove(at: source)
        lines.insert(line, at: insertion > source ? insertion - 1 : insertion)
        markdown = lines.joined(separator: "\n")
        onChange()
    }
    
    private func toggleCheckbox(at lineIndex: Int) {
        var lines = markdown.components(separatedBy: "\n")
        guard lineIndex < lines.count else { return }
        
        let line = lines[lineIndex]
        if line.contains("- [ ]") {
            lines[lineIndex] = line.replacingOccurrences(of: "- [ ]", with: "- [x]")
        } else if line.contains("- [x]") || line.contains("- [X]") {
            lines[lineIndex] = line
                .replacingOccurrences(of: "- [x]", with: "- [ ]")
                .replacingOccurrences(of: "- [X]", with: "- [ ]")
        }
        
        markdown = lines.joined(separator: "\n")
        onChange()
    }
    
    private func parseMarkdown() -> [MarkdownElement] {
        let lines = markdown.components(separatedBy: "\n")
        var elements: [MarkdownElement] = []
        var inCodeBlock = false
        var codeBlockContent = ""
        var currentList: [String] = []
        var listIndentLevel = 0
        
        for (index, line) in lines.enumerated() {
            // Handle code blocks
            if line.hasPrefix("```") {
                if inCodeBlock {
                    elements.append(MarkdownElement(id: "code-\(index)", content: codeBlockContent, type: .codeBlock, lineIndex: index))
                    codeBlockContent = ""
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                }
                continue
            }
            
            if inCodeBlock {
                codeBlockContent += (codeBlockContent.isEmpty ? "" : "\n") + line
                continue
            }
            
            // Flush current list if line is not a list item
            if !currentList.isEmpty && !isListItem(line) {
                elements.append(MarkdownElement(id: "list-\(index)", content: currentList.joined(separator: "\n"), type: .list, lineIndex: index))
                currentList = []
            }
            
            // Headers
            if line.hasPrefix("# ") {
                elements.append(MarkdownElement(id: "h1-\(index)", content: String(line.dropFirst(2)), type: .h1, lineIndex: index))
            } else if line.hasPrefix("## ") {
                elements.append(MarkdownElement(id: "h2-\(index)", content: String(line.dropFirst(3)), type: .h2, lineIndex: index))
            } else if line.hasPrefix("### ") {
                elements.append(MarkdownElement(id: "h3-\(index)", content: String(line.dropFirst(4)), type: .h3, lineIndex: index))
            }
            // Checkbox items
            else if line.trimmingCharacters(in: .whitespaces).hasPrefix("- [x]") || 
                    line.trimmingCharacters(in: .whitespaces).hasPrefix("- [X]") {
                let content = line.replacingOccurrences(of: "- [x] ", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "- [X] ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                elements.append(MarkdownElement(id: "check-\(index)", content: content, type: .checkedItem, lineIndex: index))
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("- [ ]") {
                let content = line.replacingOccurrences(of: "- [ ] ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                elements.append(MarkdownElement(id: "uncheck-\(index)", content: content, type: .uncheckedItem, lineIndex: index))
            }
            // List items
            else if isListItem(line) {
                currentList.append(line)
            }
            // Horizontal rule
            else if line == "---" || line == "***" || line == "___" {
                elements.append(MarkdownElement(id: "hr-\(index)", content: "", type: .horizontalRule, lineIndex: index))
            }
            // Blockquote
            else if line.hasPrefix("> ") {
                elements.append(MarkdownElement(id: "quote-\(index)", content: String(line.dropFirst(2)), type: .blockquote, lineIndex: index))
            }
            // Regular paragraph
            else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                elements.append(MarkdownElement(id: "p-\(index)", content: line, type: .paragraph, lineIndex: index))
            }
            // Empty line
            else {
                elements.append(MarkdownElement(id: "empty-\(index)", content: "", type: .empty, lineIndex: index))
            }
        }
        
        // Flush remaining list
        if !currentList.isEmpty {
            elements.append(MarkdownElement(id: "list-end", content: currentList.joined(separator: "\n"), type: .list, lineIndex: lines.count - 1))
        }
        
        return elements
    }
    
    private func isListItem(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || 
               trimmed.range(of: #"^\d+\. "#, options: .regularExpression) != nil
    }
}

struct MarkdownTextView: View {
    let text: String
    
    var body: some View {
        // SwiftUI Text supports markdown natively when initialized with AttributedString
        if let attributed = try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
                .font(.body)
                .environment(\.openURL, OpenURLAction { url in
                    NSWorkspace.shared.open(url)
                    return .handled
                })
        } else {
            Text(text)
                .font(.body)
        }
    }
}

struct CheckboxRow: View {
    let element: MarkdownElement
    let onToggle: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onToggle) {
                if element.type == .checkedItem {
                    Image(systemName: "checkmark.square.fill")
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "square")
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            
            if element.type == .checkedItem {
                MarkdownTextView(text: element.content)
                    .strikethrough(true)
                    .foregroundColor(.secondary)
            } else {
                MarkdownTextView(text: element.content)
                    .foregroundColor(.primary)
            }
        }
    }
}

struct MarkdownElement: Identifiable {
    let id: String
    let content: String
    let type: MarkdownElementType
    let lineIndex: Int
    
    init(id: String, content: String, type: MarkdownElementType, lineIndex: Int = 0) {
        self.id = id
        self.content = content
        self.type = type
        self.lineIndex = lineIndex
    }

    var isTodoItem: Bool { type == .checkedItem || type == .uncheckedItem }
    var isHeading: Bool { type == .h1 || type == .h2 || type == .h3 }
    
    @ViewBuilder
    var view: some View {
        switch type {
        case .h1:
            Text(content)
                .font(.system(size: 20, weight: .bold))
                .padding(.top, 10)
                .padding(.bottom, 2)
        case .h2:
            Text(content)
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 8)
                .padding(.bottom, 1)
        case .h3:
            Text(content)
                .font(.system(size: 15, weight: .medium))
                .padding(.top, 6)
        case .paragraph:
            MarkdownTextView(text: content)
        case .codeBlock:
            Text(content)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.1))
                .cornerRadius(4)
        case .list:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(content.components(separatedBy: "\n"), id: \.self) { item in
                    HStack(alignment: .top, spacing: 4) {
                        Text("•")
                        // Use the same markdown-capable text renderer as paragraphs so
                        // `[label](url)` links in list items become clickable.
                        MarkdownTextView(text: cleanListItem(item))
                    }
                }
            }
        case .checkedItem, .uncheckedItem:
            EmptyView()
        case .blockquote:
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                Text(applyInlineFormatting(content))
                    .font(.body)
                    .italic()
                    .padding(.leading, 8)
            }
            .padding(.vertical, 4)
        case .horizontalRule:
            Divider()
                .padding(.vertical, 8)
        case .empty:
            Spacer()
                .frame(height: 8)
        }
    }
    
    private func cleanListItem(_ item: String) -> String {
        var cleaned = item.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("- ") {
            cleaned = String(cleaned.dropFirst(2))
        } else if cleaned.hasPrefix("* ") {
            cleaned = String(cleaned.dropFirst(2))
        } else if let range = cleaned.range(of: #"^\d+\. "#, options: .regularExpression) {
            cleaned = String(cleaned[range.upperBound...])
        }
        return cleaned
    }
    
    private func applyInlineFormatting(_ text: String) -> AttributedString {
        var result = AttributedString()
        var remaining = text
        
        // Process markdown links: [text](url)
        let linkPattern = #"\[([^\]]+)\]\(([^)]+)\)"#
        
        while let match = remaining.range(of: linkPattern, options: .regularExpression) {
            // Add text before the link
            let beforeLink = String(remaining[remaining.startIndex..<match.lowerBound])
            result += AttributedString(beforeLink)
            
            // Extract link text and URL
            let matchedString = String(remaining[match])
            if let textMatch = matchedString.range(of: #"\[([^\]]+)\]"#, options: .regularExpression),
               let urlMatch = matchedString.range(of: #"\(([^)]+)\)"#, options: .regularExpression) {
                let linkText = String(matchedString[textMatch]).dropFirst().dropLast() // Remove [ ]
                let urlString = String(matchedString[urlMatch]).dropFirst().dropLast() // Remove ( )
                
                var linkAttr = AttributedString(String(linkText))
                if let url = URL(string: String(urlString)) {
                    linkAttr.link = url
                    linkAttr.foregroundColor = .blue
                    linkAttr.underlineStyle = .single
                }
                result += linkAttr
            }
            
            remaining = String(remaining[match.upperBound...])
        }
        
        // Add any remaining text
        result += AttributedString(remaining)
        
        // Process bold: **text**
        // Process italic: *text* or _text_
        // Process code: `code`
        result = applyBoldFormatting(result)
        result = applyCodeFormatting(result)
        
        return result
    }
    
    private func applyBoldFormatting(_ input: AttributedString) -> AttributedString {
        var result = AttributedString()
        let plainText = String(input.characters)
        var remaining = plainText
        let boldPattern = #"\*\*([^*]+)\*\*"#
        
        while let match = remaining.range(of: boldPattern, options: .regularExpression) {
            let beforeBold = String(remaining[remaining.startIndex..<match.lowerBound])
            result += AttributedString(beforeBold)
            
            let matchedString = String(remaining[match])
            let boldText = String(matchedString.dropFirst(2).dropLast(2))
            var boldAttr = AttributedString(boldText)
            boldAttr.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            result += boldAttr
            
            remaining = String(remaining[match.upperBound...])
        }
        
        result += AttributedString(remaining)
        return result
    }
    
    private func applyCodeFormatting(_ input: AttributedString) -> AttributedString {
        var result = AttributedString()
        let plainText = String(input.characters)
        var remaining = plainText
        let codePattern = #"`([^`]+)`"#
        
        while let match = remaining.range(of: codePattern, options: .regularExpression) {
            let beforeCode = String(remaining[remaining.startIndex..<match.lowerBound])
            result += AttributedString(beforeCode)
            
            let matchedString = String(remaining[match])
            let codeText = String(matchedString.dropFirst().dropLast())
            var codeAttr = AttributedString(codeText)
            codeAttr.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            codeAttr.backgroundColor = .black.opacity(0.1)
            result += codeAttr
            
            remaining = String(remaining[match.upperBound...])
        }
        
        result += AttributedString(remaining)
        return result
    }
}

enum MarkdownElementType {
    case h1, h2, h3
    case paragraph
    case codeBlock
    case list
    case checkedItem, uncheckedItem
    case blockquote
    case horizontalRule
    case empty
}

#Preview {
    TodoView()
        .environment(FocusModel())
}
