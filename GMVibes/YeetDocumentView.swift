import SwiftUI

// MARK: - FocusedValues for cmd+F / cmd+G plumbing

struct FocusYeetFindKey: FocusedValueKey { typealias Value = () -> Void }
struct FocusYeetFindNextKey: FocusedValueKey { typealias Value = () -> Void }
struct FocusYeetFindPrevKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
    var yeetFind: (() -> Void)? {
        get { self[FocusYeetFindKey.self] }
        set { self[FocusYeetFindKey.self] = newValue }
    }
    var yeetFindNext: (() -> Void)? {
        get { self[FocusYeetFindNextKey.self] }
        set { self[FocusYeetFindNextKey.self] = newValue }
    }
    var yeetFindPrev: (() -> Void)? {
        get { self[FocusYeetFindPrevKey.self] }
        set { self[FocusYeetFindPrevKey.self] = newValue }
    }
}

// MARK: - Anchor IDs

private enum YeetAnchor {
    static let header = "header"
    static func section(_ id: String) -> String { "section:\(id)" }
    static func anEnum(sectionID: String, enumID: String) -> String { "enum:\(sectionID):\(enumID)" }
    static func aStruct(sectionID: String, structID: String) -> String { "struct:\(sectionID):\(structID)" }
    static func field(sectionID: String, structID: String, fieldID: String) -> String {
        "field:\(sectionID):\(structID):\(fieldID)"
    }
    static func enumCase(sectionID: String, enumID: String, caseText: String) -> String {
        "case:\(sectionID):\(enumID):\(caseText)"
    }
}

private func computeYeetAnchors(doc: YeetDocument, query: String) -> [String] {
    guard !query.isEmpty else { return [] }
    var anchors: [String] = []
    if doc.header.matches(query: query) { anchors.append(YeetAnchor.header) }
    for section in doc.sections where section.anyMatch(query: query) {
        if section.matches(query: query) { anchors.append(YeetAnchor.section(section.id)) }
        for e in section.enums where e.anyMatch(query: query) {
            if e.matches(query: query) {
                anchors.append(YeetAnchor.anEnum(sectionID: section.id, enumID: e.id))
            }
            for c in e.cases where c.localizedStandardContains(query) {
                anchors.append(YeetAnchor.enumCase(sectionID: section.id, enumID: e.id, caseText: c))
            }
        }
        for s in section.structs where s.anyMatch(query: query) {
            if s.matches(query: query) {
                anchors.append(YeetAnchor.aStruct(sectionID: section.id, structID: s.id))
            }
            for f in s.fields where f.matches(query: query) {
                anchors.append(YeetAnchor.field(sectionID: section.id, structID: s.id, fieldID: f.id))
            }
        }
    }
    return anchors
}

// MARK: - Highlight helpers

private func yeetHighlight(_ source: String, query: String, isActive: Bool) -> AttributedString {
    var attr = AttributedString(source)
    guard !query.isEmpty, !source.isEmpty else { return attr }
    var range = source.startIndex..<source.endIndex
    while let found = source.range(
        of: query,
        options: [.caseInsensitive, .diacriticInsensitive],
        range: range
    ) {
        if let attrRange = Range(found, in: attr) {
            attr[attrRange].backgroundColor = Color.yellow.opacity(0.55)
            if isActive {
                attr[attrRange].foregroundColor = Color.accentColor
            }
        }
        range = found.upperBound..<source.endIndex
    }
    return attr
}

private struct YeetSearchContext {
    let query: String
    let activeAnchorID: String?

    var hasQuery: Bool { !query.isEmpty }

    func highlight(_ source: String, owningAnchorID: String? = nil) -> AttributedString {
        let isActive = owningAnchorID.map { $0 == activeAnchorID } ?? false
        return yeetHighlight(source, query: query, isActive: isActive)
    }
}

// MARK: - Document View

struct YeetDocumentView: View {
    let url: URL

    @State private var query: String = ""
    @State private var activeMatchIndex: Int = 0
    @State private var searchPresented: Bool = true

    private var parseResult: Result<YeetDocument, YeetParseError> {
        do {
            let doc = try YeetLanguageEngine.parse(url: url)
            return .success(doc)
        } catch let error as YeetParseError {
            return .failure(error)
        } catch {
            return .failure(.readFailed(error.localizedDescription))
        }
    }

    private var doc: YeetDocument? {
        if case .success(let d) = parseResult { return d }
        return nil
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var anchors: [String] {
        guard let doc, !trimmedQuery.isEmpty else { return [] }
        return computeYeetAnchors(doc: doc, query: trimmedQuery)
    }

    private var activeAnchorID: String? {
        guard !anchors.isEmpty,
              activeMatchIndex >= 0,
              activeMatchIndex < anchors.count
        else { return nil }
        return anchors[activeMatchIndex]
    }

    private var searchContext: YeetSearchContext {
        YeetSearchContext(query: trimmedQuery, activeAnchorID: activeAnchorID)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                GlassEffectContainer(spacing: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        switch parseResult {
                        case .success(let doc):
                            HeaderCard(header: doc.header, url: url, ctx: searchContext)
                            ForEach(visibleSections(of: doc)) { section in
                                SectionCard(section: section, ctx: searchContext)
                            }
                            if doc.sections.isEmpty {
                                EmptySectionsCard()
                            }
                            if searchContext.hasQuery && anchors.isEmpty {
                                NoMatchesCard(query: trimmedQuery)
                            }
                        case .failure(let error):
                            ErrorCard(error: error, url: url)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .background(YeetBackground())
            .searchable(
                text: $query,
                isPresented: $searchPresented,
                placement: .toolbar,
                prompt: "Find in document"
            )
            .navigationTitle(url.lastPathComponent)
            .onChange(of: query) { _, _ in
                handleQueryChange(proxy: proxy)
            }
            .focusedSceneValue(\.yeetFind, makeFindAction())
            .focusedSceneValue(\.yeetFindNext, { stepMatch(+1, proxy: proxy) })
            .focusedSceneValue(\.yeetFindPrev, { stepMatch(-1, proxy: proxy) })
            .toolbar {
                if searchContext.hasQuery {
                    ToolbarItem(placement: .automatic) {
                        ResultCountChip(current: activeMatchIndex, total: anchors.count)
                    }
                }
                ToolbarSpacer(.flexible)
                ToolbarItem {
                    ShareLink(item: url)
                }
                ToolbarSpacer(.fixed)
                ToolbarItem {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                }
            }
        }
    }

    private func visibleSections(of doc: YeetDocument) -> [YeetSection] {
        guard searchContext.hasQuery else { return doc.sections }
        return doc.sections.filter { $0.anyMatch(query: trimmedQuery) }
    }

    private func handleQueryChange(proxy: ScrollViewProxy) {
        activeMatchIndex = 0
        guard let doc else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let newAnchors = computeYeetAnchors(doc: doc, query: trimmed)
        if let firstID = newAnchors.first {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(firstID, anchor: .center)
            }
        }
    }

    private func stepMatch(_ delta: Int, proxy: ScrollViewProxy) {
        guard !anchors.isEmpty else { return }
        let n = anchors.count
        let next = ((activeMatchIndex + delta) % n + n) % n
        activeMatchIndex = next
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(anchors[next], anchor: .center)
        }
    }

    private func makeFindAction() -> () -> Void {
        // Capture the @State binding so the closure can mutate state held by SwiftUI.
        let presented = $searchPresented
        return {
            presented.wrappedValue = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                presented.wrappedValue = true
            }
        }
    }
}

// MARK: - Background

private struct YeetBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.10),
                Color.accentColor.opacity(0.02),
                Color.clear
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

// MARK: - Result Count Chip

private struct ResultCountChip: View {
    let current: Int
    let total: Int

    var body: some View {
        Text(label)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
    }

    private var label: String {
        if total == 0 { return "No matches" }
        return "\(current + 1) of \(total)"
    }
}

// MARK: - Header Card

private struct HeaderCard: View {
    let header: YeetHeader
    let url: URL
    let ctx: YeetSearchContext

    private var anchorID: String { YeetAnchor.header }

    private var showImports: Bool {
        guard !header.imports.isEmpty else { return false }
        if !ctx.hasQuery { return true }
        return header.imports.contains { $0.localizedStandardContains(ctx.query) }
    }

    private var showDescription: Bool {
        guard let d = header.description, !d.isEmpty else { return false }
        if !ctx.hasQuery { return true }
        return d.localizedStandardContains(ctx.query)
    }

    private var matchingImports: [String] {
        guard ctx.hasQuery else { return header.imports }
        return header.imports.filter { $0.localizedStandardContains(ctx.query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ctx.highlight(headerTitle, owningAnchorID: anchorID))
                    .font(.system(.largeTitle, design: .serif).weight(.bold))
                metadataRow
            }

            if showImports {
                FlowLayout(spacing: 6) {
                    ForEach(matchingImports, id: \.self) { item in
                        Chip(icon: "tray.and.arrow.down",
                             text: ctx.highlight(item, owningAnchorID: anchorID))
                    }
                }
            }

            if showDescription, let d = header.description {
                DescriptionView(source: d, ctx: ctx, owningAnchorID: anchorID)
                    .padding(.top, 4)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.title2)
                .foregroundStyle(.tertiary)
                .padding(18)
        }
        .backgroundExtensionEffect()
        .id(anchorID)
    }

    private var headerTitle: String {
        header.name ?? url.deletingPathExtension().deletingPathExtension().lastPathComponent
    }

    @ViewBuilder
    private var metadataRow: some View {
        HStack(spacing: 14) {
            if let package = header.package, !ctx.hasQuery || package.localizedStandardContains(ctx.query) {
                MetaPill(systemImage: "shippingbox",
                         text: ctx.highlight(package, owningAnchorID: anchorID))
            }
            if let version = header.yeetVersion, !ctx.hasQuery || "yeet \(version)".localizedStandardContains(ctx.query) {
                MetaPill(systemImage: "number",
                         text: ctx.highlight("yeet \(version)", owningAnchorID: anchorID))
            }
            if let uuid = header.uuid, !ctx.hasQuery || uuid.localizedStandardContains(ctx.query) {
                MetaPill(systemImage: "fingerprint",
                         text: ctx.highlight(shortUUID(uuid), owningAnchorID: anchorID),
                         monospaced: true)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func shortUUID(_ uuid: String) -> String {
        guard uuid.count > 13 else { return uuid }
        let head = uuid.prefix(8)
        let tail = uuid.suffix(4)
        return "\(head)…\(tail)"
    }
}

private struct MetaPill: View {
    let systemImage: String
    let text: AttributedString
    var monospaced: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(text)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Section Card

private struct SectionCard: View {
    let section: YeetSection
    let ctx: YeetSearchContext

    private var anchorID: String { YeetAnchor.section(section.id) }

    private var visibleStructs: [YeetStructDecl] {
        if !ctx.hasQuery || section.matches(query: ctx.query) { return section.structs }
        return section.structs.filter { $0.anyMatch(query: ctx.query) }
    }

    private var visibleEnums: [YeetEnumDecl] {
        if !ctx.hasQuery || section.matches(query: ctx.query) { return section.enums }
        return section.enums.filter { $0.anyMatch(query: ctx.query) }
    }

    private var showDescription: Bool {
        guard let d = section.description, !d.isEmpty else { return false }
        if !ctx.hasQuery { return true }
        return d.localizedStandardContains(ctx.query) || section.matches(query: ctx.query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label {
                    Text(ctx.highlight(section.name, owningAnchorID: anchorID))
                } icon: {
                    Image(systemName: "square.stack.3d.up")
                }
                .font(.title2.weight(.semibold))
                Spacer()
                Text("\(visibleStructs.count) struct\(visibleStructs.count == 1 ? "" : "s") · \(visibleEnums.count) enum\(visibleEnums.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if showDescription, let d = section.description {
                DescriptionView(source: d, ctx: ctx, owningAnchorID: anchorID)
            }

            ForEach(visibleEnums) { decl in
                EnumCard(decl: decl, sectionID: section.id, ctx: ctx)
            }

            ForEach(visibleStructs) { decl in
                StructCard(decl: decl, sectionID: section.id, ctx: ctx)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .id(anchorID)
    }
}

// MARK: - Struct Card

private struct StructCard: View {
    let decl: YeetStructDecl
    let sectionID: String
    let ctx: YeetSearchContext

    private var anchorID: String {
        YeetAnchor.aStruct(sectionID: sectionID, structID: decl.id)
    }

    private var visibleFields: [YeetField] {
        if !ctx.hasQuery || decl.matches(query: ctx.query) { return decl.fields }
        return decl.fields.filter { $0.matches(query: ctx.query) }
    }

    private var showDescription: Bool {
        guard let d = decl.description, !d.isEmpty else { return false }
        if !ctx.hasQuery { return true }
        return d.localizedStandardContains(ctx.query) || decl.matches(query: ctx.query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "curlybraces")
                    .foregroundStyle(Color.accentColor)
                Text(ctx.highlight(decl.name, owningAnchorID: anchorID))
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                Spacer()
                Text("struct")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
            }

            if showDescription, let d = decl.description {
                DescriptionView(source: d, ctx: ctx, owningAnchorID: anchorID)
                    .font(.callout)
            }

            if !visibleFields.isEmpty {
                FieldsTable(
                    fields: visibleFields,
                    sectionID: sectionID,
                    structID: decl.id,
                    ctx: ctx
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .id(anchorID)
    }
}

// MARK: - Enum Card

private struct EnumCard: View {
    let decl: YeetEnumDecl
    let sectionID: String
    let ctx: YeetSearchContext

    private var anchorID: String {
        YeetAnchor.anEnum(sectionID: sectionID, enumID: decl.id)
    }

    private var visibleCases: [String] {
        if !ctx.hasQuery || decl.matches(query: ctx.query) { return decl.cases }
        return decl.cases.filter { $0.localizedStandardContains(ctx.query) }
    }

    private var showDescription: Bool {
        guard let d = decl.description, !d.isEmpty else { return false }
        if !ctx.hasQuery { return true }
        return d.localizedStandardContains(ctx.query) || decl.matches(query: ctx.query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(.purple)
                Text(ctx.highlight(decl.name, owningAnchorID: anchorID))
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                Spacer()
                Text("enum")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
            }

            if showDescription, let d = decl.description {
                DescriptionView(source: d, ctx: ctx, owningAnchorID: anchorID)
                    .font(.callout)
            }

            if !visibleCases.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(visibleCases, id: \.self) { item in
                        let caseAnchorID = YeetAnchor.enumCase(
                            sectionID: sectionID, enumID: decl.id, caseText: item
                        )
                        let isActive = ctx.activeAnchorID == caseAnchorID
                        Chip(icon: "circle.fill",
                             text: yeetHighlight(item, query: ctx.query, isActive: isActive))
                            .id(caseAnchorID)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .id(anchorID)
    }
}

// MARK: - Fields Table

private struct FieldsTable: View {
    let fields: [YeetField]
    let sectionID: String
    let structID: String
    let ctx: YeetSearchContext

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(fields.enumerated()), id: \.element.id) { idx, field in
                let anchorID = YeetAnchor.field(
                    sectionID: sectionID, structID: structID, fieldID: field.id
                )
                let isActive = ctx.activeAnchorID == anchorID

                if idx > 0 { Divider().opacity(0.4) }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(yeetHighlight(field.name, query: ctx.query, isActive: isActive))
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .frame(minWidth: 180, alignment: .leading)
                    Spacer(minLength: 8)
                    typeView(field, isActive: isActive)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .id(anchorID)
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func typeView(_ field: YeetField, isActive: Bool) -> some View {
        if field.isUnwrap, let inner = field.unwrappedType {
            HStack(spacing: 6) {
                Text("Unwrap")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                Text(yeetHighlight(inner, query: ctx.query, isActive: isActive))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.primary)
            }
        } else {
            Text(yeetHighlight(field.rawType, query: ctx.query, isActive: isActive))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Chip primitive (used by both imports and enum cases)

private struct Chip: View {
    let icon: String
    let text: AttributedString

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .monospaced))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
    }
}

// MARK: - Flow layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth && rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Description view (markdown when idle, highlighted plain text when searching)

private struct DescriptionView: View {
    let source: String
    let ctx: YeetSearchContext
    let owningAnchorID: String?

    var body: some View {
        if ctx.hasQuery {
            Text(ctx.highlight(source, owningAnchorID: owningAnchorID))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        } else {
            // Native block rendering (headings/lists/code/tables) via the shared
            // markdown renderer — the same upgrade the Memories reader uses.
            MarkdownBlocksView(source: source)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Empty / Error

private struct EmptySectionsCard: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No sections found in this yeet file.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(30)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

private struct NoMatchesCard: View {
    let query: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No matches for \u{201C}\(query)\u{201D}")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(30)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

private struct ErrorCard: View {
    let error: YeetParseError
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Could not parse this file", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(error.localizedDescription)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Text(url.path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(error.localizedDescription, forType: .string)
                } label: {
                    Label("Copy Message", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}
