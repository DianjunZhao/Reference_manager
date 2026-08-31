import Foundation

// MARK: - Evidence identity and physics validation

enum V3EvidenceIdentity {
    static func chunkID(paperID: Int, documentHash: String, page: Int, ordinal: Int, quoteHash: String) -> String {
        "v3pdf:\(paperID):\(documentHash):p\(page):q\(ordinal):\(quoteHash)"
    }

    static func anchorID(paperID: Int, source: EvidenceSourceKind, page: Int?, ordinal: Int, quoteHash: String, figureKey: String? = nil) -> String {
        let pagePart = page.map { "p\($0)" } ?? "metadata"
        let figurePart = figureKey.map { ":\($0)" } ?? ""
        return "v3\(source.rawValue):\(paperID):\(pagePart):q\(ordinal):\(quoteHash)\(figurePart)"
    }
}

struct V3RevisionHasher: Sendable {
    static func snapshot(for paper: Paper, syncBatchID: UUID, observedAt: Date = Date()) -> PaperRevisionSnapshot {
        let titleHash = StableHash.sha256(paper.titles.map { "\($0.source ?? "")|\($0.value)" }.joined(separator: "\n"))
        let abstractHash = StableHash.sha256(paper.abstracts.map { "\($0.source ?? "")|\($0.value)" }.joined(separator: "\n"))
        let documentsHash = StableHash.sha256(paper.documents.map { "\($0.key)|\($0.url?.absoluteString ?? "")|\($0.filename ?? "")|\($0.isFullText)" }.sorted().joined(separator: "\n"))
        let figuresHash = StableHash.sha256(paper.figures.map { "\($0.key)|\($0.url?.absoluteString ?? "")|\($0.caption ?? "")|\($0.filename ?? "")" }.sorted().joined(separator: "\n"))
        let publicationHash = StableHash.sha256("\(paper.publicationStatus ?? "")|\(paper.publicationYear.map(String.init) ?? "")|\(paper.doi ?? "")|\(paper.arxivID ?? "")")
        let recordHash = StableHash.sha256([
            titleHash, abstractHash, String(paper.citationCount ?? -1), documentsHash, figuresHash,
            publicationHash, paper.updated?.ISO8601Format() ?? ""
        ].joined(separator: "|"))
        return PaperRevisionSnapshot(id: "\(paper.literatureID):\(observedAt.ISO8601Format())", paperID: paper.literatureID,
                                     recordHash: recordHash, titleHash: titleHash, abstractHash: abstractHash,
                                     citationCount: paper.citationCount, documentsHash: documentsHash, figuresHash: figuresHash,
                                     publicationHash: publicationHash, observedAt: observedAt,
                                     sourceURL: URL(string: "https://inspirehep.net/api/literature/\(paper.literatureID)")!,
                                     syncBatchID: syncBatchID)
    }
}

struct V3RadarDiff: Sendable {
    static func events(before: PaperRevisionSnapshot?, after: PaperRevisionSnapshot, authorRecids: [Int], syncBatchID: UUID,
                       beforePaper: Paper? = nil, afterPaper: Paper? = nil) -> [RadarEvent] {
        guard let before else {
            return [RadarEvent(id: UUID(), paperID: after.paperID, authorRecids: authorRecids, eventKind: .newPaper,
                                beforeHash: nil, afterHash: after.recordHash, changedFields: ["record"], syncBatchID: syncBatchID,
                                observedAt: after.observedAt, sourceURL: after.sourceURL, isAcknowledged: false,
                                beforeCitationCount: nil, afterCitationCount: after.citationCount)]
        }
        var events: [RadarEvent] = []
        func add(_ kind: RadarEventKind, _ fields: [String]) {
            events.append(RadarEvent(id: UUID(), paperID: after.paperID, authorRecids: authorRecids,
                                     eventKind: kind, beforeHash: before.recordHash, afterHash: after.recordHash,
                                     changedFields: fields, syncBatchID: syncBatchID, observedAt: after.observedAt,
                                     sourceURL: after.sourceURL, isAcknowledged: false,
                                     beforeCitationCount: before.citationCount, afterCitationCount: after.citationCount))
        }
        var revisionFields: [String] = []
        if before.titleHash != after.titleHash { revisionFields.append("title") }
        if before.abstractHash != after.abstractHash { revisionFields.append("abstract") }
        if before.publicationHash != after.publicationHash { add(.publicationChanged, ["publication"]) }
        if before.citationCount != after.citationCount { add(.citationChanged, ["citationCount"] ) }
        if before.documentsHash != after.documentsHash { add(.newDocument, ["documents"]) }
        if before.figuresHash != after.figuresHash { add(.newFigure, ["figures"]) }
        if !revisionFields.isEmpty { add(.recordRevised, revisionFields) }
        if let beforePaper, let afterPaper {
            if beforePaper.publicationStatus != afterPaper.publicationStatus || beforePaper.publicationYear != afterPaper.publicationYear || beforePaper.doi != afterPaper.doi {
                if !events.contains(where: { $0.eventKind == .publicationChanged }) { add(.publicationChanged, ["publication"]) }
            }
        }
        return events
    }
}

enum V3PhysicsValidationError: LocalizedError, Equatable, Sendable {
    case missingAnchor
    case crossPaperAnchor
    case staleDocument
    case quoteHashMismatch
    case invalidNumericUnit
    case invalidWorkspace
    case invalidCell

    var errorDescription: String? {
        switch self {
        case .missingAnchor: "direct/inference physics cell 缺少同 paper evidence anchor。"
        case .crossPaperAnchor: "physics cell 引用了另一篇论文的 anchor；必须显式标记 cross_paper_inference。"
        case .staleDocument: "physics cell 的 source document hash 已过期。"
        case .quoteHashMismatch: "evidence quote hash 与保存的 anchor 不一致。"
        case .invalidNumericUnit: "physics cell 的数值与单位未通过本地契约。"
        case .invalidWorkspace: "Compare workspace 必须包含 2–6 篇真实存在且不重复的论文，并且名称非空。"
        case .invalidCell: "physics cell 不属于当前 workspace/paper，或 missing cell 携带了值。"
        }
    }
}

struct V3PhysicsContractValidator: Sendable {
    static func validate(_ cell: PhysicsContractCell, snapshot: LibrarySnapshot) throws {
        switch cell.status {
        case .missing:
            guard cell.evidenceAnchorIDs.isEmpty, cell.value == nil, cell.unit == nil else { throw V3PhysicsValidationError.invalidCell }
            return
        case .caveat:
            guard cell.value != nil || cell.unit == nil else { throw V3PhysicsValidationError.invalidCell }
            if cell.value == nil, cell.evidenceAnchorIDs.isEmpty { return }
            guard !cell.evidenceAnchorIDs.isEmpty else { throw V3PhysicsValidationError.missingAnchor }
        case .stale:
            throw V3PhysicsValidationError.staleDocument
        case .direct, .inference, .crossPaperInference:
            guard !cell.evidenceAnchorIDs.isEmpty else { throw V3PhysicsValidationError.missingAnchor }
        }
        var hasValidAnchor = false
        var hasCrossPaperAnchor = false
        for id in cell.evidenceAnchorIDs {
            guard let anchor = snapshot.evidenceAnchors[id] else { throw V3PhysicsValidationError.missingAnchor }
            guard anchor.paperID == cell.paperID else {
                guard cell.status == .crossPaperInference else { throw V3PhysicsValidationError.crossPaperAnchor }
                hasCrossPaperAnchor = true
                continue
            }
            guard StableHash.sha256(anchor.quote) == anchor.quoteHash else { throw V3PhysicsValidationError.quoteHashMismatch }
            if let expectedDocument = cell.sourceDocumentHash, anchor.sourceKind == .pdf {
                guard anchor.id.hasPrefix("v3pdf:\(cell.paperID):\(expectedDocument):") else { throw V3PhysicsValidationError.staleDocument }
                guard snapshot.fullTextDocuments.values.contains(where: { $0.paperID == cell.paperID && $0.sha256 == expectedDocument && $0.extractionState == .extracted }) else {
                    throw V3PhysicsValidationError.staleDocument
                }
            }
            hasValidAnchor = true
        }
        guard hasValidAnchor || hasCrossPaperAnchor else { throw V3PhysicsValidationError.missingAnchor }
        if cell.status == .crossPaperInference, !hasCrossPaperAnchor { throw V3PhysicsValidationError.crossPaperAnchor }
        if let value = cell.value { try PhysicsNumericValidator.validate(value: value, unit: cell.unit) }
    }

    static func rubricRowsMissing(from cells: [PhysicsContractCell]) -> [String] {
        let present = Set(cells.map(\.rowKey))
        return PhysicsContract.defaultRows.filter { !present.contains($0) }
    }
}

enum PhysicsNumericValidator {
    static let numericPattern = "[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?(?:\\s*\\([^)]*\\))?(?:\\s*(?:%|GeV|MeV|keV|fm|a|L|T))?"
    static let allowedUnitPattern = "^(?:%|GeV(?:\\^[-+]?[0-9]+)?|MeV(?:\\^[-+]?[0-9]+)?|keV(?:\\^[-+]?[0-9]+)?|fm(?:\\^[-+]?[0-9]+|\\^{-?[0-9]+\\})?|a(?:\\^[-+]?[0-9]+|\\^{-?[0-9]+\\})?|L(?:\\^[-+]?[0-9]+)?|T(?:\\^[-+]?[0-9]+)?|L\\^3[×x*]T|L\\^3xT)$"

    static func validate(value: String, unit: String?) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 1_000 else { throw V3PhysicsValidationError.invalidNumericUnit }
        let containsNumber = trimmed.range(of: "[0-9]", options: .regularExpression) != nil
        let symbolicGeometry = trimmed.range(of: "^L\\^3[×x*]T$", options: .regularExpression) != nil
        guard containsNumber || !symbolicGeometry else { return }
        if containsNumber && unit == nil {
            // An explicitly embedded unit is acceptable (e.g. `2.1 GeV`),
            // but a bare number is not a physics contract cell.
            guard trimmed.range(of: "(?:%|GeV|MeV|keV|fm|a(?:\\^|\\{|$)|L(?:\\^|$)|T(?:\\^|$))", options: .regularExpression) != nil else {
                throw V3PhysicsValidationError.invalidNumericUnit
            }
        }
        if let unit {
            guard unit.range(of: allowedUnitPattern, options: .regularExpression) != nil else {
                throw V3PhysicsValidationError.invalidNumericUnit
            }
        }
    }
}

// MARK: - Notebook/export/import

struct V3NotebookExportRequest: Sendable {
    let paperIDs: [Int]
    let format: V3ExportFormat
    let includeLocalPDFPath: Bool
    let destinationCategory: String
}

enum V3NotebookExportError: LocalizedError, Equatable, Sendable {
    case paperMissing(Int)
    case unsupportedImport
    case conflictRequiresReview

    var errorDescription: String? {
        switch self {
        case .paperMissing(let id): "论文 \(id) 不在本地 library。"
        case .unsupportedImport: "仅接受本地 BibTeX/RIS/CSL JSON 文件。"
        case .conflictRequiresReview: "导入记录与 INSPIRE record 冲突，需要用户确认。"
        }
    }
}

struct V3ImportedBibliography: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let format: V3ExportFormat
    let importedAt: Date
    let sourceCategory: String
    let recid: Int?
    let doi: String?
    let arxivID: String?
    let title: String?
    let authors: [String]
    let rawHash: String
    let matchedPaperID: Int?
    let sourceURL: URL?
}

enum V3ImportReviewStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case accepted
    case rejected

    var displayNameZH: String {
        switch self {
        case .pending: "待审阅"
        case .accepted: "已接受"
        case .rejected: "已拒绝"
        }
    }
}

struct V3ImportConflict: Codable, Hashable, Sendable, Identifiable {
    let importedID: UUID
    let paperID: Int
    let fields: [String]
    var status: V3ImportReviewStatus
    /// Field-level consent is durable evidence: `.accepted` alone must not
    /// imply that every conflicting field overwrote a source record.
    var acceptedFields: [String]
    var id: UUID { importedID }

    init(importedID: UUID, paperID: Int, fields: [String], status: V3ImportReviewStatus,
         acceptedFields: [String] = []) {
        self.importedID = importedID
        self.paperID = paperID
        self.fields = fields.sorted()
        self.status = status
        self.acceptedFields = acceptedFields.sorted()
    }

    private enum CodingKeys: String, CodingKey { case importedID, paperID, fields, status, acceptedFields }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(importedID: try values.decode(UUID.self, forKey: .importedID),
                  paperID: try values.decode(Int.self, forKey: .paperID),
                  fields: try values.decode([String].self, forKey: .fields),
                  status: try values.decode(V3ImportReviewStatus.self, forKey: .status),
                  acceptedFields: try values.decodeIfPresent([String].self, forKey: .acceptedFields) ?? [])
    }
}

struct V3ImportResult: Sendable {
    let records: [V3ImportedBibliography]
    let conflicts: [V3ImportConflict]
}

enum V3NotebookImporter {
    static let maximumBytes = 5 * 1024 * 1024
    static let maximumEntries = 1_000
    static let maximumFieldScalars = 40_000

    /// Parse only a user-selected local file.  Missing bibliographic fields
    /// stay nil; no journal/year/page/DOI is inferred from a title or URL.
    static func parse(data: Data, format: V3ExportFormat, snapshot: LibrarySnapshot,
                      importedAt: Date = Date(), sourceCategory: String = "local-user-selected") throws -> V3ImportResult {
        guard format == .bibtex || format == .ris || format == .cslJSON else { throw V3NotebookExportError.unsupportedImport }
        guard !data.isEmpty, data.count <= maximumBytes else { throw LatticeLensError.schemaViolation("import 文件为空或超过 5 MiB 本地上限") }
        guard String(decoding: data, as: UTF8.self).unicodeScalars.count <= maximumBytes else {
            throw LatticeLensError.schemaViolation("import 文本超过本地字符上限")
        }
        let rawHash = StableHash.sha256(data)
        let entries: [[String: String]]
        switch format {
        case .bibtex: entries = parseBibTeX(String(decoding: data, as: UTF8.self))
        case .ris: entries = parseRIS(String(decoding: data, as: UTF8.self))
        case .cslJSON: entries = try parseCSL(data)
        default: entries = []
        }
        guard entries.count <= maximumEntries else { throw LatticeLensError.schemaViolation("import record 数超过 1,000 条本地上限") }
        guard entries.allSatisfy({ $0.values.allSatisfy { $0.unicodeScalars.count <= maximumFieldScalars } }) else {
            throw LatticeLensError.schemaViolation("import 包含超过本地字段上限的文本")
        }
        let values = entries.map { fields -> V3ImportedBibliography in
            let recid = fields["recid"].flatMap(Int.init)
            let doi = fields["doi"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let arxiv = fields["arxiv"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = fields["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let match = snapshot.papers.values.first { paper in
                (recid != nil && paper.literatureID == recid) ||
                (doi != nil && doi?.lowercased() == paper.doi?.lowercased()) ||
                (arxiv != nil && arxiv?.lowercased() == paper.arxivID?.lowercased())
            }
            return V3ImportedBibliography(id: UUID(), format: format, importedAt: importedAt,
                                          sourceCategory: sourceCategory, recid: recid, doi: doi, arxivID: arxiv,
                                          title: title, authors: fields["authors"].map { $0.split(separator: "|").map(String.init) } ?? [],
                                          rawHash: rawHash, matchedPaperID: match?.literatureID,
                                          sourceURL: fields["url"].flatMap(URL.init(string:)))
        }
        let conflicts = values.compactMap { imported -> V3ImportConflict? in
            guard let paperID = imported.matchedPaperID, let paper = snapshot.papers[paperID] else { return nil }
            var fields = [String]()
            if let importedTitle = imported.title, !importedTitle.isEmpty, importedTitle != paper.displayTitle { fields.append("title") }
            if let importedDOI = imported.doi, let currentDOI = paper.doi,
               importedDOI.caseInsensitiveCompare(currentDOI) != .orderedSame { fields.append("doi") }
            return fields.isEmpty ? nil : V3ImportConflict(importedID: imported.id, paperID: paperID, fields: fields, status: .pending)
        }
        return V3ImportResult(records: values, conflicts: conflicts)
    }

    private static func parseBibTeX(_ text: String) -> [[String: String]] {
        let blocks = text.components(separatedBy: "@") .dropFirst()
        return blocks.compactMap { block in
            var fields = [String: String]()
            let body = block.components(separatedBy: "{").dropFirst().joined(separator: "{")
            for line in body.components(separatedBy: ",") {
                let pieces = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard pieces.count == 2 else { continue }
                let key = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                var value = pieces[1].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "{}\"")))
                value = value.replacingOccurrences(of: "}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                switch key {
                case "title": fields["title"] = value
                case "doi": fields["doi"] = value
                case "eprint", "arxiv": fields["arxiv"] = value
                case "url": fields["url"] = value
                case "author": fields["authors"] = value.replacingOccurrences(of: " and ", with: "|")
                case "recid", "inspire": fields["recid"] = value
                default: break
                }
            }
            return fields.isEmpty ? nil : fields
        }
    }

    private static func parseRIS(_ text: String) -> [[String: String]] {
        var entries = [[String: String]](), current = [String: String](), authors = [String]()
        for line in text.components(separatedBy: .newlines) {
            guard line.count >= 2 else { continue }
            let tag = String(line.prefix(2)), value = String(line.dropFirst(min(6, line.count))).trimmingCharacters(in: .whitespacesAndNewlines)
            if tag == "TY" { current = [:]; authors = [] }
            switch tag {
            case "TI": current["title"] = value
            case "ID": current["recid"] = value
            case "DO": current["doi"] = value
            case "UR":
                current["url"] = value
                if value.contains("arxiv.org/abs/") { current["arxiv"] = value.components(separatedBy: "arxiv.org/abs/").last }
                else if value.contains("inspirehep.net/literature/") { current["recid"] = value.components(separatedBy: "inspirehep.net/literature/").last }
            case "AU": authors.append(value)
            case "ER":
                current["authors"] = authors.joined(separator: "|")
                if !current.isEmpty { entries.append(current) }
                current = [:]; authors = []
            default: break
            }
        }
        return entries
    }

    private static func parseCSL(_ data: Data) throws -> [[String: String]] {
        let raw = try JSONSerialization.jsonObject(with: data)
        let array = (raw as? [[String: Any]]) ?? (raw as? [String: Any]).map { [$0] } ?? []
        return array.map { item in
            var result = [String: String]()
            if let title = item["title"] as? String { result["title"] = title }
            if let doi = item["DOI"] as? String { result["doi"] = doi }
            if let url = item["URL"] as? String, url.contains("arxiv.org/abs/") { result["arxiv"] = url.components(separatedBy: "arxiv.org/abs/").last }
            if let url = item["URL"] as? String { result["url"] = url }
            if let id = item["id"] as? String, let recid = Int(id) { result["recid"] = String(recid) }
            if let authors = item["author"] as? [[String: Any]] { result["authors"] = authors.compactMap { ($0["family"] as? String) ?? ($0["literal"] as? String) }.joined(separator: "|") }
            return result
        }
    }
}

struct V3NotebookExporter: Sendable {
    static func render(request: V3NotebookExportRequest, snapshot: LibrarySnapshot) throws -> String {
        let papers = request.paperIDs.compactMap { snapshot.papers[$0] }
        guard papers.count == request.paperIDs.count else {
            let missing = request.paperIDs.first { snapshot.papers[$0] == nil } ?? -1
            throw V3NotebookExportError.paperMissing(missing)
        }
        switch request.format {
        case .bibtex:
            return papers.compactMap { snapshot.bibTeXRecords[$0.literatureID]?.contents }.joined(separator: "\n")
        case .ris:
            return papers.map { paper in
                // `GEN` avoids inventing a journal/article type when INSPIRE
                // metadata does not provide one.
                var lines = ["TY  - GEN", "ID  - \(paper.literatureID)", "TI  - \(paper.displayTitle)"]
                if let abstract = paper.preferredAbstract { lines.append("AB  - \(abstract)") }
                for contributor in paper.contributors.sorted(by: { $0.position < $1.position }) { lines.append("AU  - \(contributor.fullName)") }
                if let doi = paper.doi { lines.append("DO  - \(doi)") }
                if let arxiv = paper.arxivID { lines.append("UR  - https://arxiv.org/abs/\(arxiv)") }
                lines.append("UR  - https://inspirehep.net/literature/\(paper.literatureID)")
                lines.append("ER  -")
                return lines.joined(separator: "\n")
            }.joined(separator: "\n\n") + "\n"
        case .cslJSON:
            let values: [[String: Any]] = papers.map { paper in
                var value: [String: Any] = ["id": String(paper.literatureID), "title": paper.displayTitle,
                                            "URL": "https://inspirehep.net/literature/\(paper.literatureID)"]
                if let abstract = paper.preferredAbstract { value["abstract"] = abstract }
                if let doi = paper.doi { value["DOI"] = doi }
                if !paper.contributors.isEmpty {
                    value["author"] = paper.contributors.sorted(by: { $0.position < $1.position }).map { ["literal": $0.fullName] }
                }
                if let issued = paper.timelineDate { value["issued"] = ["date-parts": [[Calendar(identifier: .gregorian).component(.year, from: issued)]]] }
                return value
            }
            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            return String(decoding: data, as: UTF8.self) + "\n"
        case .provenanceJSON:
            let values: [[String: Any]] = papers.map { paper in
                var item: [String: Any] = ["paper_id": paper.literatureID,
                                           "source_url": "https://inspirehep.net/api/literature/\(paper.literatureID)",
                                           "source_scope": ProductContract.sourceScope]
                if let document = snapshot.fullTextDocuments.values.first(where: { $0.paperID == paper.literatureID }) {
                    item["document_hash"] = document.sha256
                    item["document_source_url"] = document.sourceURL.absoluteString
                }
                item["anchor_ids"] = snapshot.evidenceAnchors.values.filter { $0.paperID == paper.literatureID }.map(\.id).sorted()
                item["annotation_ids"] = snapshot.userEvidenceAnchors.values.filter { $0.paperID == paper.literatureID }.map { $0.id.uuidString }.sorted()
                item["imported_provenance"] = snapshot.importedBibliographies.values.filter { $0.matchedPaperID == paper.literatureID }.sorted { $0.importedAt < $1.importedAt }.map {
                    var record: [String: Any] = ["id": $0.id.uuidString, "format": $0.format.rawValue, "imported_at": $0.importedAt.ISO8601Format(), "raw_hash": $0.rawHash, "source_category": $0.sourceCategory]
                    if let sourceURL = $0.sourceURL { record["source_url"] = sourceURL.absoluteString }
                    if let conflict = snapshot.importConflicts[$0.id] { record["conflict_status"] = conflict.status.rawValue; record["conflict_fields"] = conflict.fields }
                    return record
                }
                return item
            }
            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            return String(decoding: data, as: UTF8.self) + "\n"
        case .markdownNotebook:
            return papers.map { paper in
                var lines = ["# \(paper.displayTitle)", "", "- INSPIRE: https://inspirehep.net/literature/\(paper.literatureID)"]
                if let arxiv = paper.arxivID { lines.append("- arXiv: https://arxiv.org/abs/\(arxiv)") }
                if let doi = paper.doi { lines.append("- DOI: \(doi)") }
                let tags = Set(snapshot.paperTags.filter { $0.paperID == paper.literatureID }.compactMap { snapshot.tags[$0.tagID]?.name }).sorted()
                if !tags.isEmpty { lines.append("- Local tags: \(tags.joined(separator: ", "))") }
                if let document = snapshot.fullTextDocuments.values.first(where: { $0.paperID == paper.literatureID }) {
                    if request.includeLocalPDFPath, let filename = document.localFilename {
                        lines.append("- Local PDF: \(filename)")
                    } else {
                        lines.append("- Public PDF source: \(document.sourceURL.absoluteString)")
                    }
                }
                let anchors = snapshot.evidenceAnchors.values.filter { $0.paperID == paper.literatureID }.sorted { $0.id < $1.id }
                if !anchors.isEmpty {
                    lines += ["", "## Evidence anchors"]
                    for anchor in anchors {
                        let document = snapshot.fullTextDocuments.values.first { document in
                            document.paperID == paper.literatureID && anchor.id.hasPrefix("v3pdf:\(paper.literatureID):\(document.sha256):")
                        }
                        let sourceURL = document?.sourceURL.absoluteString ?? "https://inspirehep.net/literature/\(paper.literatureID)"
                        let hash = document?.sha256 ?? "metadata"
                        let state = snapshot.quarantinedEvidenceIDs.contains(anchor.id) ? "quarantined" : "valid"
                        lines.append("[^\(anchor.id)]: \(anchor.sourceKind.rawValue) \(anchor.page.map { "p\($0)" } ?? "metadata") [\(state)] — \(anchor.quote) — source: \(sourceURL) — document: \(hash) — quote_hash: \(anchor.quoteHash)")
                    }
                }
                let annotations = snapshot.userEvidenceAnchors.values.filter { $0.paperID == paper.literatureID }.sorted { $0.id.uuidString < $1.id.uuidString }
                if !annotations.isEmpty {
                    lines += ["", "## Local annotations"]
                    for annotation in annotations {
                        lines.append("- [\(annotation.status.rawValue)] \(annotation.label): \(annotation.quote) — \(annotation.note)")
                    }
                }
                if let evidence = snapshot.evidenceInsights.values.filter({ $0.paperID == paper.literatureID }).sorted(by: { $0.createdAt > $1.createdAt }).first {
                    let claims = [evidence.insight.physics.researchQuestion] + evidence.insight.physics.methodAndDataFlow +
                        evidence.insight.physics.mainResults + evidence.insight.physics.reasonableInferences +
                        evidence.insight.physics.missingInformation + evidence.insight.physics.caveats
                    lines += ["", "## Evidence-backed claims"]
                    for claim in claims {
                        let refs = claim.evidenceIDs.map { "[^\($0)]" }.joined(separator: " ")
                        lines.append("- [\(claim.epistemicStatus.rawValue)] \(claim.textZH) \(refs)")
                    }
                }
                for note in snapshot.notes.values.filter({ $0.paperID == paper.literatureID }).sorted(by: { $0.updatedAt < $1.updatedAt }) {
                    lines += ["", "## Local note", "", note.body]
                }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n\n") + "\n"
        }
    }
}

// MARK: - Bounded graph and CloudKit boundary

struct V3GraphLimits: Sendable, Equatable {
    let maximumNodes: Int
    let maximumEdges: Int
    let maximumPages: Int
    let maximumBytes: Int

    static let `default` = V3GraphLimits(maximumNodes: 100, maximumEdges: 200, maximumPages: 10, maximumBytes: 2_000_000)
}

struct V3GraphSnapshot: Sendable, Equatable {
    let paperIDs: Set<Int>
    let authorRecids: Set<Int>
    let citationEdges: [CitationEdge]
    let coauthorEdges: [CoauthorEdge]
    let truncated: Bool
}

struct V3GraphBuilder: Sendable {
    static func build(snapshot: LibrarySnapshot, rootPaperID: Int?, rootAuthorRecid: Int?, limits: V3GraphLimits = .default) -> V3GraphSnapshot {
        var papers = Set<Int>()
        var authors = Set<Int>()
        if let rootPaperID { papers.insert(rootPaperID) }
        if let rootAuthorRecid { authors.insert(rootAuthorRecid) }
        let edgeBudget = min(max(0, limits.maximumEdges), max(0, limits.maximumPages) * 50)
        var bytes = 0
        let citationCandidates = snapshot.citationEdges.values.filter { edge in
            guard let rootPaperID else { return false }
            return (edge.fromPaperID == rootPaperID || edge.toPaperID == rootPaperID) && edge.sourceURL.scheme?.lowercased() == "https" && edge.sourceURL.host?.lowercased() == "inspirehep.net"
        }.sorted { $0.id < $1.id }
        let citations = Array(citationCandidates.prefix(edgeBudget).filter { edge in
            let estimate = edge.id.utf8.count + edge.sourceURL.absoluteString.utf8.count + edge.query.utf8.count + 96
            guard bytes + estimate <= limits.maximumBytes else { return false }
            bytes += estimate
            return true
        })
        for edge in citations { papers.insert(edge.fromPaperID); papers.insert(edge.toPaperID) }
        let coauthorCandidates = snapshot.coauthorEdges.values.filter { edge in
            guard let rootAuthorRecid else { return false }
            return (edge.authorRecid == rootAuthorRecid || edge.coauthorRecid == rootAuthorRecid) && edge.sourceURL.scheme?.lowercased() == "https" && edge.sourceURL.host?.lowercased() == "inspirehep.net"
        }.sorted { $0.id < $1.id }
        let coauthors = Array(coauthorCandidates.prefix(edgeBudget).filter { edge in
            let estimate = edge.id.utf8.count + edge.sourceURL.absoluteString.utf8.count + edge.query.utf8.count + 96
            guard bytes + estimate <= limits.maximumBytes else { return false }
            bytes += estimate
            return true
        })
        for edge in coauthors { authors.insert(edge.authorRecid); authors.insert(edge.coauthorRecid) }
        let orderedPapers = papers.sorted()
        let orderedAuthors = authors.sorted()
        let nodeBudget = max(0, limits.maximumNodes)
        let paperLimit = min(orderedPapers.count, nodeBudget)
        let remaining = max(0, nodeBudget - paperLimit)
        let authorLimit = min(orderedAuthors.count, remaining)
        let truncated = papers.count + authors.count > nodeBudget || citationCandidates.count > citations.count || coauthorCandidates.count > coauthors.count || bytes >= limits.maximumBytes
        let paperSet = Set(orderedPapers.prefix(paperLimit))
        let authorSet = Set(orderedAuthors.prefix(authorLimit))
        let visibleCitations = citations.filter { paperSet.contains($0.fromPaperID) && paperSet.contains($0.toPaperID) }
        let visibleCoauthors = coauthors.filter { authorSet.contains($0.authorRecid) && authorSet.contains($0.coauthorRecid) }
        return V3GraphSnapshot(paperIDs: paperSet, authorRecids: authorSet,
                               citationEdges: visibleCitations, coauthorEdges: visibleCoauthors, truncated: truncated || visibleCitations.count < citations.count || visibleCoauthors.count < coauthors.count)
    }
}

struct V3CloudSyncEngine: Sendable {
    static let allowedTypes: Set<String> = ["readingState", "note", "tag", "collection", "workspace", "annotation"]

    static func mergeNote(local: UserNote, remote: UserNote) -> (note: UserNote?, conflict: ConflictCopy?) {
        guard local.id == remote.id, local.paperID == remote.paperID else { return (nil, nil) }
        if local.body == remote.body { return (local, nil) }
        let conflict = ConflictCopy(id: UUID(), recordID: local.id.uuidString,
                                    originalFieldHash: StableHash.sha256(local.body), conflictingFieldHash: StableHash.sha256(remote.body),
                                    payload: remote.body, createdAt: Date())
        return (local, conflict)
    }
}

struct V3CloudSyncOperation: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let recordID: String
    let recordType: String
    let payloadHash: String
    var attempt: Int
    var nextAttemptAt: Date
    var lastError: String?

    init(id: UUID = UUID(), recordID: String, recordType: String, payloadHash: String,
         attempt: Int = 0, nextAttemptAt: Date = Date(), lastError: String? = nil) {
        self.id = id; self.recordID = recordID; self.recordType = recordType; self.payloadHash = payloadHash
        self.attempt = attempt; self.nextAttemptAt = nextAttemptAt; self.lastError = lastError
    }
}

/// Deterministic, credential-free CloudKit boundary used by local tests. It
/// models offline queueing, bounded retry and idempotent record application;
/// no bytes or secrets are sent anywhere.
actor V3CloudSyncMockEngine {
    private var queue: [UUID: V3CloudSyncOperation] = [:]
    private var applied: Set<String> = []
    private var failureBudget: [String: Int] = [:]

    func setTransientFailures(recordID: String, count: Int) { failureBudget[recordID] = max(0, count) }
    func enqueue(_ operation: V3CloudSyncOperation) throws {
        guard V3CloudSyncEngine.allowedTypes.contains(operation.recordType) else { throw LatticeLensError.schemaViolation("CloudSync record type 不在 allowlist") }
        guard queue[operation.id] == nil, !applied.contains("\(operation.recordType):\(operation.recordID):\(operation.payloadHash)") else { return }
        queue[operation.id] = operation
    }
    func pendingCount() -> Int { queue.count }
    func process(now: Date = Date(), maxAttempts: Int = 3) -> (succeeded: Int, retried: Int, failed: Int) {
        var succeeded = 0, retried = 0, failed = 0
        for id in queue.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var operation = queue[id], operation.nextAttemptAt <= now else { continue }
            if let remaining = failureBudget[operation.recordID], remaining > 0 {
                failureBudget[operation.recordID] = remaining - 1
                operation.attempt += 1
                if operation.attempt >= maxAttempts {
                    operation.lastError = "transient failure budget exhausted"
                    queue.removeValue(forKey: id); failed += 1
                } else {
                    operation.nextAttemptAt = now.addingTimeInterval(Double(operation.attempt) * 0.25)
                    queue[id] = operation; retried += 1
                }
                continue
            }
            applied.insert("\(operation.recordType):\(operation.recordID):\(operation.payloadHash)")
            queue.removeValue(forKey: id); succeeded += 1
        }
        return (succeeded, retried, failed)
    }

    func appliedCount() -> Int { applied.count }
}

// MARK: - v2→v3 migration and persistence coordinator

struct V3MigrationReport: Codable, Hashable, Sendable {
    let sourceSchema: Int
    let targetSchema: Int
    let preCount: Int
    let postCount: Int
    let quarantinedCount: Int
    let preHash: String
    let postHash: String
    let durationMilliseconds: Int
}

struct V3MigrationService: Sendable {
    static func migrate(_ input: LibrarySnapshot, now: Date = Date()) -> (snapshot: LibrarySnapshot, report: V3MigrationReport) {
        let hasLegacyEvidence = input.evidenceChunks.values.contains { chunk in
            !chunk.id.hasPrefix("v3pdf:\(chunk.paperID):\(chunk.documentHash):")
        }
        if input.v3SchemaVersion >= 3 && !hasLegacyEvidence {
            let encoded = (try? JSONEncoder.latticeLens.encode(input)) ?? Data()
            let hash = StableHash.sha256(encoded)
            return (input, V3MigrationReport(sourceSchema: input.schemaVersion, targetSchema: 3,
                                              preCount: input.papers.count + input.evidenceChunks.count,
                                              postCount: input.papers.count + input.evidenceChunks.count,
                                              quarantinedCount: input.quarantinedEvidenceIDs.count, preHash: hash,
                                              postHash: hash, durationMilliseconds: 0))
        }
        var output = input
        let start = Date()
        let preData = (try? JSONEncoder.latticeLens.encode(input)) ?? Data()
        var idMap: [String: String] = [:]
        var quarantined = Set<String>()
        // Legacy v2 PDF IDs did not carry paper/document scope.  A conversion
        // is allowed only when the source chunk itself names one paper and one
        // document hash; otherwise the old record remains readable but is
        // explicitly quarantined for user-triggered re-extraction.
        for chunk in input.evidenceChunks.values {
            let canonical = V3EvidenceIdentity.chunkID(paperID: chunk.paperID, documentHash: chunk.documentHash,
                                                       page: chunk.page, ordinal: legacyOrdinal(from: chunk.id, fallback: 1),
                                                       quoteHash: chunk.textHash)
            if chunk.id == canonical || chunk.id.hasPrefix("v3pdf:\(chunk.paperID):\(chunk.documentHash):") {
                idMap[chunk.id] = chunk.id
            } else if input.papers[chunk.paperID] != nil,
                      input.fullTextDocuments.values.filter({ $0.paperID == chunk.paperID && $0.sha256 == chunk.documentHash }).count == 1 {
                idMap[chunk.id] = canonical
            } else {
                quarantined.insert(chunk.id)
            }
        }
        for chunk in input.evidenceChunks.values {
            guard let mapped = idMap[chunk.id], mapped != chunk.id else { continue }
            output.evidenceChunks.removeValue(forKey: chunk.id)
            let migrated = EvidenceChunk(id: mapped, paperID: chunk.paperID, documentHash: chunk.documentHash, page: chunk.page,
                                         section: chunk.section, characterRangeStart: chunk.characterRangeStart,
                                         characterRangeEnd: chunk.characterRangeEnd, text: chunk.text, textHash: chunk.textHash,
                                         byteCount: chunk.byteCount, scalarCount: chunk.scalarCount, tokenEstimate: chunk.tokenEstimate)
            output.evidenceChunks[mapped] = migrated
            if let anchor = output.evidenceAnchors.removeValue(forKey: chunk.id) {
                output.evidenceAnchors[mapped] = EvidenceAnchor(id: mapped, paperID: anchor.paperID, sourceKind: anchor.sourceKind,
                                                                page: anchor.page, section: anchor.section, quote: anchor.quote,
                                                                quoteHash: anchor.quoteHash, figureKey: anchor.figureKey)
            }
        }
        output.quarantinedEvidenceIDs.formUnion(quarantined)
        // Keep old v2 artifacts read-only, but rewrite a fully deterministic
        // chunk list when every referenced ID was converted.  Partial/unknown
        // lists are marked stale instead of being silently repaired.
        for (key, artifact) in input.evidenceInsights {
            let mapped = artifact.chunkIDs.map { idMap[$0] }
            let stale = mapped.contains(where: { $0 == nil || quarantined.contains($0!) })
            let rewritten = EvidenceInsightArtifact(cacheKey: artifact.cacheKey, paperID: artifact.paperID,
                                                     documentHash: artifact.documentHash,
                                                     chunkIDs: mapped.compactMap { $0 }, insight: artifact.insight,
                                                     createdAt: artifact.createdAt, retrievalQuery: artifact.retrievalQuery,
                                                     rankerVersion: artifact.rankerVersion, selectedChunkIDs: artifact.selectedChunkIDs.map { idMap[$0] ?? $0 },
                                                     promptVersion: artifact.promptVersion, schemaVersion: artifact.schemaVersion,
                                                     payloadHash: artifact.payloadHash, payloadByteCount: artifact.payloadByteCount,
                                                     payloadScalarCount: artifact.payloadScalarCount, isStale: artifact.isStale || stale)
            output.evidenceInsights[key] = rewritten
        }
        output.v3SchemaVersion = 3
        let journal = V3MigrationJournalEntry(id: UUID(), sourceSchema: input.schemaVersion, targetSchema: 3,
                                              startedAt: now, completedAt: now, phase: "completed", preCount: input.papers.count + input.evidenceChunks.count,
                                              postCount: output.papers.count + output.evidenceChunks.count,
                                              preHash: StableHash.sha256(preData), postHash: nil, quarantinedCount: quarantined.count, errorCategory: nil)
        let postData = (try? JSONEncoder.latticeLens.encode(output)) ?? Data()
        output.migrationJournal[journal.id] = V3MigrationJournalEntry(id: journal.id, sourceSchema: journal.sourceSchema,
                                                                       targetSchema: journal.targetSchema, startedAt: journal.startedAt,
                                                                       completedAt: journal.completedAt, phase: journal.phase,
                                                                       preCount: journal.preCount, postCount: journal.postCount,
                                                                       preHash: journal.preHash, postHash: StableHash.sha256(postData),
                                                                       quarantinedCount: journal.quarantinedCount, errorCategory: journal.errorCategory)
        let elapsed = Int(Date().timeIntervalSince(start) * 1_000)
        let report = V3MigrationReport(sourceSchema: input.schemaVersion, targetSchema: 3,
                                       preCount: input.papers.count + input.evidenceChunks.count,
                                       postCount: output.papers.count + output.evidenceChunks.count,
                                       quarantinedCount: quarantined.count, preHash: StableHash.sha256(preData),
                                       postHash: StableHash.sha256((try? JSONEncoder.latticeLens.encode(output)) ?? postData), durationMilliseconds: elapsed)
        return (output, report)
    }

    private static func legacyOrdinal(from id: String, fallback: Int) -> Int {
        let pieces = id.split(separator: ":")
        if let q = pieces.first(where: { $0.first == "q" }), let value = Int(q.dropFirst()) { return max(1, value) }
        return fallback
    }
}

actor V3WorkbenchService {
    let store: any LibraryStoring
    let client: InspireClient

    init(store: any LibraryStoring, client: InspireClient = InspireClient()) { self.store = store; self.client = client }

    func acknowledgeRadarEvent(_ id: UUID) async throws { try await store.applyV3(.acknowledgeRadarEvent(id)) }

    func createWorkspace(name: String, paperIDs: [Int]) async throws -> PaperWorkspace {
        let snapshot = await store.snapshot()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<Int>()
        let uniqueIDs = paperIDs.filter { seen.insert($0).inserted }
        guard (2...6).contains(uniqueIDs.count), uniqueIDs.allSatisfy({ snapshot.papers[$0] != nil }), !trimmedName.isEmpty,
              trimmedName.unicodeScalars.count <= 120 else { throw V3PhysicsValidationError.invalidWorkspace }
        let validIDs = uniqueIDs
        let now = Date()
        let workspace = PaperWorkspace(id: UUID(), name: trimmedName, createdAt: now,
                                       updatedAt: now, sortOrder: validIDs, note: "", frozenExportHash: nil)
        try await store.applyV3(.saveWorkspace(workspace))
        for (index, paperID) in validIDs.enumerated() {
            try await store.applyV3(.saveWorkspaceLink(WorkspacePaperLink(workspaceID: workspace.id, paperID: paperID, addedAt: now, sortIndex: index)))
        }
        let contract = PhysicsContract(id: UUID(), workspaceID: workspace.id, rowKeys: PhysicsContract.defaultRows, createdAt: now, updatedAt: now)
        try await store.applyV3(.savePhysicsContract(contract))
        // Every selected paper receives an explicit missing cell.  Compare can
        // therefore distinguish “not reported” from a guessed value, and a
        // later extractor can replace a cell only after validating anchors.
        for paperID in validIDs {
            for rowKey in PhysicsContract.defaultRows {
                let cell = PhysicsContractCell(id: UUID(), workspaceID: workspace.id, rowKey: rowKey,
                                                paperID: paperID, value: nil, unit: nil, status: .missing,
                                                evidenceAnchorIDs: [], extractionVersion: "v3-empty-contract",
                                                sourceDocumentHash: nil, updatedAt: now)
                try await store.applyV3(.savePhysicsCell(cell))
            }
        }
        return workspace
    }

    func updatePhysicsCell(_ cell: PhysicsContractCell) async throws {
        let snapshot = await store.snapshot()
        guard let workspace = snapshot.workspaces[cell.workspaceID], workspace.sortOrder.contains(cell.paperID),
              snapshot.physicsContracts.values.contains(where: { $0.workspaceID == cell.workspaceID && $0.rowKeys.contains(cell.rowKey) }) else {
            throw V3PhysicsValidationError.invalidCell
        }
        // v4 adds the stronger same-anchor value+unit proof.  Retain the v3
        // ownership checks above, but never let the legacy validator accept a
        // cell whose value and unit were assembled from unrelated quotes.
        try V4PhysicsValidator.validate(cell, snapshot: snapshot)
        try await store.applyV3(.savePhysicsCell(cell))
    }

    /// Runs the deterministic, local-only extractor over the workspace's
    /// existing evidence.  It intentionally returns `missing` where a rule
    /// cannot identify an explicit value, rather than inferring action,
    /// ensemble, Fourier convention, or renormalization details.
    func extractLocalCompareMatrix(workspaceID: UUID) async throws -> [PhysicsContractCell] {
        let snapshot = await store.snapshot()
        guard let workspace = snapshot.workspaces[workspaceID],
              let contract = snapshot.physicsContracts.values.first(where: { $0.workspaceID == workspaceID }) else {
            throw V3PhysicsValidationError.invalidWorkspace
        }
        let expected = Set(workspace.sortOrder.flatMap { paperID in contract.rowKeys.map { "\(paperID)|\($0)" } })
        guard expected.count == workspace.sortOrder.count * contract.rowKeys.count else {
            throw V3PhysicsValidationError.invalidWorkspace
        }
        let existing = Dictionary(uniqueKeysWithValues: snapshot.physicsContractCells.values
            .filter { $0.workspaceID == workspaceID }
            .map { ("\($0.paperID)|\($0.rowKey)", $0) })
        let extracted = V4CompareExtractor.extract(workspace: workspace, snapshot: snapshot)
        guard Set(extracted.map { "\($0.paperID)|\($0.rowKey)" }) == expected else {
            throw V3PhysicsValidationError.invalidCell
        }
        let now = Date()
        let proposed = extracted.map { value -> PhysicsContractCell in
            let key = "\(value.paperID)|\(value.rowKey)"
            let prior = existing[key]
            let documentHash: String? = value.anchorID.flatMap { id in
                let parts = id.split(separator: ":")
                guard parts.count >= 3, parts[0] == "v3pdf", Int(parts[1]) == value.paperID else { return nil }
                return String(parts[2])
            }
            return PhysicsContractCell(id: prior?.id ?? UUID(), workspaceID: workspaceID, rowKey: value.rowKey,
                                       paperID: value.paperID, value: value.value, unit: value.unit, status: value.status,
                                       evidenceAnchorIDs: value.anchorID.map { [$0] } ?? [], extractionVersion: value.extractionVersion,
                                       sourceDocumentHash: documentHash, updatedAt: now)
        }
        try await replacePhysicsMatrix(workspace: workspace, contract: contract, proposed: proposed, snapshot: snapshot)
        return proposed
    }

    /// The only Compare replacement path.  All structural and evidence checks
    /// run against one immutable snapshot before the store mutation, so the
    /// old matrix survives any rejection without partial writes.
    func replacePhysicsMatrix(workspaceID: UUID, proposed: [PhysicsContractCell]) async throws {
        let snapshot = await store.snapshot()
        guard let workspace = snapshot.workspaces[workspaceID],
              let contract = snapshot.physicsContracts.values.first(where: { $0.workspaceID == workspaceID }) else {
            throw V3PhysicsValidationError.invalidWorkspace
        }
        try await replacePhysicsMatrix(workspace: workspace, contract: contract, proposed: proposed, snapshot: snapshot)
    }

    private func replacePhysicsMatrix(workspace: PaperWorkspace, contract: PhysicsContract,
                                      proposed: [PhysicsContractCell], snapshot: LibrarySnapshot) async throws {
        let expected = Set(workspace.sortOrder.flatMap { paperID in contract.rowKeys.map { "\(paperID)|\($0)" } })
        let received = proposed.map { "\($0.paperID)|\($0.rowKey)" }
        guard proposed.count == expected.count, Set(received).count == proposed.count, Set(received) == expected else {
            throw V3PhysicsValidationError.invalidCell
        }
        for cell in proposed {
            guard cell.workspaceID == workspace.id else { throw V3PhysicsValidationError.invalidCell }
            try V4PhysicsValidator.validate(cell, snapshot: snapshot)
        }
        // `applyV3` encodes and saves the entire replacement as one snapshot
        // mutation for JSON/SwiftData compatibility stores.
        try await store.applyV3(.replacePhysicsMatrix(workspaceID: workspace.id, cells: proposed))
    }

    func importBibliography(data: Data, format: V3ExportFormat, sourceCategory: String) async throws -> V3ImportResult {
        let snapshot = await store.snapshot()
        let result = try V3NotebookImporter.parse(data: data, format: format, snapshot: snapshot,
                                                  sourceCategory: sourceCategory)
        for record in result.records { try await store.applyV3(.saveImportedBibliography(record)) }
        for conflict in result.conflicts { try await store.applyV3(.saveImportConflict(conflict)) }
        return result
    }

    func setImportConflictStatus(importedID: UUID, status: V3ImportReviewStatus) async throws {
        try await store.applyV3(.setImportConflictStatus(importedID: importedID, status: status))
    }

    /// Applies only the explicitly selected conflict fields.  The import is
    /// already bounded/dry-run parsed; this method still validates ownership,
    /// pending state, and the exact field allowlist before a single durable
    /// merge so a stale sheet cannot overwrite a different paper.
    func acceptImportConflict(importedID: UUID, acceptedFields: Set<String>) async throws {
        let snapshot = await store.snapshot()
        guard var conflict = snapshot.importConflicts[importedID], conflict.status == .pending,
              let imported = snapshot.importedBibliographies[importedID], imported.matchedPaperID == conflict.paperID,
              var paper = snapshot.papers[conflict.paperID] else {
            throw LatticeLensError.schemaViolation("导入冲突已过期或不属于当前本地 paper")
        }
        let allowed = Set(conflict.fields)
        guard !acceptedFields.isEmpty, acceptedFields.isSubset(of: allowed) else {
            throw LatticeLensError.schemaViolation("必须显式选择至少一个当前冲突字段")
        }
        for field in acceptedFields.sorted() {
            switch field {
            case "title":
                guard let title = imported.title, !title.isEmpty else { throw LatticeLensError.schemaViolation("导入 title 缺失") }
                // Preserve the original INSPIRE title as a separate source
                // value.  The accepted import becomes the explicit primary
                // bibliographic display value rather than silently erasing
                // its provenance.
                paper.titles.removeAll { $0.source == "user-accepted-import" }
                paper.titles.insert(PaperTitle(value: title, source: "user-accepted-import"), at: 0)
            case "doi":
                guard let doi = imported.doi, !doi.isEmpty else { throw LatticeLensError.schemaViolation("导入 DOI 缺失") }
                paper.doi = doi
            case "arxivID":
                guard let arxivID = imported.arxivID, !arxivID.isEmpty else { throw LatticeLensError.schemaViolation("导入 arXiv ID 缺失") }
                paper.arxivID = arxivID
            default:
                throw LatticeLensError.schemaViolation("导入字段不在受控 merge allowlist：\(field)")
            }
        }
        conflict.status = .accepted
        conflict.acceptedFields = acceptedFields.sorted()
        try await store.commitAcceptedImport(paper: paper, conflict: conflict)
    }

    func saveNotebookEntry(id: UUID? = nil, paperID: Int, title: String, body: String,
                           anchorIDs: [String]) async throws -> NotebookEntry {
        let snapshot = await store.snapshot()
        guard snapshot.papers[paperID] != nil else { throw LatticeLensError.schemaViolation("Notebook paper 不存在") }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, trimmedTitle.unicodeScalars.count <= 240,
              body.unicodeScalars.count <= 200_000 else {
            throw LatticeLensError.schemaViolation("Notebook title/body 超出本地上限")
        }
        var seen = Set<String>()
        let uniqueIDs = anchorIDs.filter { seen.insert($0).inserted }
        for anchorID in uniqueIDs {
            if let anchor = snapshot.evidenceAnchors[anchorID] {
                guard anchor.paperID == paperID, !snapshot.quarantinedEvidenceIDs.contains(anchorID),
                      StableHash.sha256(anchor.quote) == anchor.quoteHash else {
                    throw LatticeLensError.schemaViolation("Notebook evidence anchor 无效或不属于该 paper")
                }
            } else if let uuid = UUID(uuidString: anchorID), let annotation = snapshot.userEvidenceAnchors[uuid] {
                guard annotation.paperID == paperID, annotation.status == .valid,
                      StableHash.sha256(annotation.quote) == annotation.quoteHash else {
                    throw LatticeLensError.schemaViolation("Notebook annotation 无效或不属于该 paper")
                }
            } else {
                throw LatticeLensError.schemaViolation("Notebook anchor 不存在")
            }
        }
        let now = Date()
        let entryID = id ?? UUID()
        let entry = NotebookEntry(id: entryID, paperID: paperID, title: trimmedTitle, body: body,
                                  createdAt: snapshot.notebookEntries[entryID]?.createdAt ?? now, updatedAt: now)
        let links = uniqueIDs.enumerated().map { NotebookAnchorLink(entryID: entryID, anchorID: $0.element, sortIndex: $0.offset) }
        try await store.commitNotebookEntry(entry, links: links)
        return entry
    }

    func deleteNotebookEntry(_ id: UUID) async throws {
        try await store.applyV3(.deleteNotebookEntry(id))
    }

    func refreshSavedQuery(_ query: SavedInspireQuery, maximumPages: Int = 10) async throws -> SyncBatchV3 {
        guard !query.isPaused else { throw LatticeLensError.schemaViolation("Radar query 已暂停") }
        let batchID = UUID()
        let jobID = "radar-query:\(query.id.uuidString)"
        let generationID = "radar:\(query.id.uuidString):\(batchID.uuidString)"
        let started = Date()
        var batch = SyncBatchV3(id: batchID, jobID: jobID, generationID: generationID, startedAt: started,
                                completedAt: nil, state: .active, newRecords: 0, metadataUpdated: 0,
                                citationChanged: 0, unchanged: 0, failed: 0, durationMilliseconds: nil)
        try await store.applyV3(.saveBatch(batch))
        var nextURL: URL?
        var page = 0
        var beforeSnapshot = await store.snapshot()
        do {
            repeat {
                try Task.checkCancellation()
                guard page < maximumPages else { throw LatticeLensError.paginationLimitExceeded }
                let response = try await client.literaturePage(query: query.query, nextURL: nextURL)
                page += 1
                for paper in response.papers {
                    let revision = V3RevisionHasher.snapshot(for: paper, syncBatchID: batchID)
                    let authorRecids = beforeSnapshot.paperAuthorLinks.filter { $0.paperID == paper.literatureID }.map(\.authorRecid).sorted()
                    let beforePaper = beforeSnapshot.papers[paper.literatureID]
                    let events = V4RadarDiff.events(before: beforePaper, after: paper, authorRecids: authorRecids,
                                                     batchID: batchID, observedAt: revision.observedAt)
                    if beforePaper == nil { batch.newRecords += 1 }
                    else if events.isEmpty { batch.unchanged += 1 }
                    else {
                        batch.metadataUpdated += events.contains { $0.changedFields.compactMap(V4RadarFieldChange.decodeStorageMarker).contains { $0.field != "citationCount" } } ? 1 : 0
                        batch.citationChanged += events.filter { event in
                            event.changedFields.compactMap(V4RadarFieldChange.decodeStorageMarker).contains { $0.field == "citationCount" }
                        }.count
                    }
                    try await store.upsert(detail: paper)
                    try await store.applyV3(.saveRevision(revision))
                    for event in events { try await store.applyV3(.saveRadarEvent(event)) }
                    beforeSnapshot.papers[paper.literatureID] = paper
                }
                nextURL = response.nextURL
            } while nextURL != nil
            let finished = Date()
            batch.completedAt = finished; batch.state = .completed
            batch.durationMilliseconds = Int(finished.timeIntervalSince(started) * 1_000)
            try await store.applyV3(.saveBatch(batch))
            var updated = query
            updated.lastRunAt = finished
            updated.nextRunAt = Self.nextRun(after: finished, policy: query.refreshPolicy)
            try await store.applyV3(.saveQuery(updated))
            return batch
        } catch is CancellationError {
            batch.state = .cancelled; batch.completedAt = Date(); batch.durationMilliseconds = Int(Date().timeIntervalSince(started) * 1_000)
            try? await store.applyV3(.saveBatch(batch))
            throw CancellationError()
        } catch {
            batch.state = .failed; batch.failed += 1; batch.completedAt = Date(); batch.durationMilliseconds = Int(Date().timeIntervalSince(started) * 1_000)
            try? await store.applyV3(.saveBatch(batch))
            throw error
        }
    }

    private static func nextRun(after date: Date, policy: SavedQueryRefreshPolicy) -> Date? {
        switch policy {
        case .manual: nil
        case .onLaunch: date
        case .daily: Calendar.current.date(byAdding: .day, value: 1, to: date)
        case .weekly: Calendar.current.date(byAdding: .day, value: 7, to: date)
        }
    }

    func export(_ request: V3NotebookExportRequest) async throws -> (contents: String, record: ExportRecord) {
        let snapshot = await store.snapshot()
        let contents = try V3NotebookExporter.render(request: request, snapshot: snapshot)
        let hash = StableHash.sha256(contents)
        let record = ExportRecord(id: UUID(), format: request.format, paperIDs: request.paperIDs,
                                  destinationCategory: request.destinationCategory, sourceHashes: request.paperIDs.compactMap { snapshot.papers[$0]?.updated?.ISO8601Format() },
                                  createdAt: Date(), payloadHash: hash, succeeded: true, errorCategory: nil)
        try await store.applyV3(.saveExport(record))
        return (contents, record)
    }
}
