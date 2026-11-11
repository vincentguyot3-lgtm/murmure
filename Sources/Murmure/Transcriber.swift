import CoreML
import FluidAudio
import Foundation
import os
import WhisperKit

/// Enveloppe WhisperKit (transcription) et FluidAudio (distinction des voix), 100 % locales.
actor Transcriber {
    private var whisper: WhisperKit?
    /// pyannote community-1 + regroupement VBx. Préféré à SpeakerKit, qui coupait une même voix en deux
    /// interlocuteurs dès qu'elle revenait après une réplique (3 voix trouvées pour un échange à 2).
    private var speakers: OfflineDiarizerManager?

    var isReady: Bool { whisper != nil }

    /// Avancement d'un long traitement, en clair pour la fiche (« Voix 42 % », « Transcription 12 / 60 min »).
    /// Appelé depuis n'importe quel fil.
    typealias Progress = @Sendable (String) -> Void

    /// Télécharge (au premier lancement) puis charge les modèles.
    func load() async throws {
        let config = WhisperKitConfig(
            model: Settings.whisperModel,
            downloadBase: Settings.modelsDir,
            verbose: false,
            // MURMURE_WHISPER_LOG=debug montre le journal interne de WhisperKit (morceaux, erreurs avalées).
            logLevel: ProcessInfo.processInfo.environment["MURMURE_WHISPER_LOG"] == "debug" ? .debug : .error,
            prewarm: false,
            load: true,
            download: true
        )
        let loaded = try await WhisperKit(config)
        // Découpage des dictées de plus de 30 s : au milieu du plus long silence, repéré avec notre seuil adaptatif.
        // Celui de WhisperKit (0,02, soit -34 dBFS) tient pour silence toute une voix lointaine et peut couper en plein mot.
        loaded.voiceActivityDetector = AdaptiveVAD()
        // Horodatage des mots juste même avec une amorce (voir PromptAwareSeeker).
        loaded.segmentSeeker = PromptAwareSeeker()
        // Premier horodatage borné à 1 s (voir InitialTimestampFilter).
        if let specialTokens = loaded.tokenizer?.specialTokens, ProcessInfo.processInfo.environment["MURMURE_SANS_BORNE"] == nil {
            loaded.textDecoder.logitsFilters = [InitialTimestampFilter(specialTokens: specialTokens)]
        }
        // Une première transcription à vide : la suivante, la vraie, ne paie plus l'initialisation.
        _ = try? await loaded.transcribe(audioArray: [Float](repeating: 0, count: 16_000))
        whisper = loaded

        // La distinction des voix est un plus : si elle ne se charge pas, la dictée fonctionne quand même.
        var diarization = OfflineDiarizerConfig.default
        let env = ProcessInfo.processInfo.environment
        // MURMURE_THRESHOLD et MURMURE_MIN_SEGMENT permettent d'ajuster le regroupement pour les essais.
        if let value = env["MURMURE_THRESHOLD"].flatMap(Double.init) { diarization.clusteringThreshold = value }
        // Une plage de parole plus courte que cette durée est effacée par pyannote (1 s par défaut) : un « Oui »
        // ou un « D'accord » d'une autre voix disparaissait et ses mots rejoignaient la voix voisine.
        diarization.embedding.minSegmentDurationSeconds = env["MURMURE_MIN_SEGMENT"].flatMap(Double.init) ?? 0.5
        // Les tranches sans aucun vote de voix sont ré-encodées et rattachées à la voix la plus proche, au lieu
        // d'être données d'office à la première voix.
        diarization.zeroVoteReembed = .init(enabled: env["MURMURE_SANS_REEMBED"] == nil)
        // Empreintes brutes de chaque passage, gardées pour reconnaître les voix d'une réunion à l'autre (`VoiceBook`).
        diarization.exposeChunkEmbeddings = true
        let diarizer = OfflineDiarizerManager(config: diarization)
        if (try? await diarizer.prepareModels()) != nil { speakers = diarizer }
    }

    /// Contexte du curseur donné à Whisper : termes rares du champ et fin du texte qui précède.
    struct Hint {
        var terms: [String] = []
        var tail = ""
        var isEmpty: Bool { terms.isEmpty && tail.isEmpty }
    }

    private func decodingOptions(hint: Hint = Hint()) -> DecodingOptions {
        var options = DecodingOptions(
            task: .transcribe,
            language: Settings.isAutoLanguage ? nil : Settings.language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: Settings.isAutoLanguage,
            skipSpecialTokens: true,
            // Horodatage et découpage dans les silences : sans eux, Whisper perd la phrase qui chevauche
            // chaque frontière de 30 s (banc d'essai : 13,6 % de mots faux contre 1,2 %).
            withoutTimestamps: false,
            chunkingStrategy: .vad
        )
        // Seuil sur le premier mot désactivé : sur une vraie dictée brève, il faisait rendre un texte vide
        // (« Aucune parole détectée »), avec ou sans amorce. Sans incidence sur le banc d'essai.
        options.firstTokenLogProbThreshold = nil
        // Le vocabulaire sert d'amorce au décodeur pour orienter l'orthographe des termes rares.
        // Chaque jeton d'amorce est décodé un à un (~10 ms) : d'où l'intérêt d'une liste courte.
        // Le contexte du curseur s'y ajoute : ses noms propres, puis la fin du texte qui précède, que Whisper
        // prend pour le début de la phrase et poursuit (graphie des noms, minuscule en reprise).
        // Le dictionnaire passe en entier ; le contexte a son propre plafond, partagé entre ses termes
        // (au plus la moitié, les plus proches du curseur d'abord) et la fin du texte qui précède.
        guard let tokenizer = whisper?.tokenizer else { return options }
        func encode(_ text: String) -> [Int] {
            tokenizer.encode(text: text).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let vocab = Settings.vocabulary()
        var tokens = vocab.isEmpty ? [] : encode(" " + vocab.joined(separator: ", ") + ".")
        var kept: [String] = []
        var termTokens: [Int] = []
        for term in hint.terms where !vocab.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            let candidate = encode(" " + (kept + [term]).joined(separator: ", ") + ".")
            guard candidate.count <= Self.maxPromptTokens / 2 else { break }
            kept.append(term)
            termTokens = candidate
        }
        let tailTokens = hint.tail.isEmpty ? [] : Array(encode(" " + hint.tail).suffix(Self.maxPromptTokens - termTokens.count))
        tokens += termTokens + tailTokens
        // Whisper accepte au plus 224 jetons d'amorce ; on garde la fin, la plus proche de la parole.
        if !tokens.isEmpty { options.promptTokens = Array(tokens.suffix(224)) }
        return options
    }

    /// Plafond de l'amorce tirée du contexte : chaque jeton coûte un pas de décodeur, ~6 ms. Banc `--bench-contexte` du 31/10/2026 :
    /// 15,4 % de mots faux sans contexte, 4,4 % avec, aussi bien à 80 qu'à 150 jetons (+0,5 s contre +0,7 s par dictée).
    static var maxPromptTokens: Int {
        ProcessInfo.processInfo.environment["MURMURE_PROMPT_TOKENS"].flatMap(Int.init) ?? 80
    }

    // MARK: File d'attente
    // Whisper ne traite qu'un audio à la fois. Une dictée (urgente) passe devant le traitement
    // d'une réunion, qui avance par petits morceaux : elle n'attend jamais plus d'un morceau.

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Levé quand une dictée attend son tour (ou au relâchement de la touche) : un essai en cours,
    /// marqué interruptible, s'arrête au jeton suivant au lieu d'aller au bout. Baissé à chaque prise de Whisper.
    private nonisolated let preempt = OSAllocatedUnfairLock(initialState: false)

    /// Arrête l'essai interruptible en cours, s'il y en a un.
    nonisolated func interrupt() { preempt.withLock { $0 = true } }

    private func acquire(urgent: Bool) async {
        defer { preempt.withLock { $0 = false } }
        guard busy else { busy = true; return }
        if urgent { interrupt() }
        await withCheckedContinuation { continuation in
            if urgent { waiting.insert(continuation, at: 0) } else { waiting.append(continuation) }
        }
    }

    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }

    // MARK: Distinction des voix, une à la fois
    // `OfflineDiarizerManager` n'est pas un acteur : une dictée de plus de 3 s pendant le traitement d'une
    // réunion lancerait une seconde diarisation sur les mêmes modèles Core ML. File simple, sans priorité :
    // la dictée attend la fin de la réunion (ses voix ne servent qu'à l'historique).

    private var diarizing = false
    private var diarizationWaiting: [CheckedContinuation<Void, Never>] = []

    private func acquireSpeakers() async {
        guard diarizing else { diarizing = true; return }
        await withCheckedContinuation { diarizationWaiting.append($0) }
    }

    private func releaseSpeakers() {
        if diarizationWaiting.isEmpty { diarizing = false } else { diarizationWaiting.removeFirst().resume() }
    }

    // MARK: Transcription

    /// `preemptible` : simple essai (aperçu de la dictée en flux), abandonné dès qu'une dictée demande Whisper ;
    /// lève alors `CancellationError`.
    func transcribe(_ audio: [Float], urgent: Bool = true, hint: Hint = Hint(), preemptible: Bool = false) async throws -> String {
        guard let whisper else { return "" }
        await acquire(urgent: urgent)
        defer { release() }
        // WhisperKit ignore la dernière seconde d'un audio : un « Oui » bref serait perdu, on complète par du silence.
        let minimum = 16_000 * 3 / 2
        let padded = audio.count < minimum ? audio + [Float](repeating: 0, count: minimum - audio.count) : audio
        let text = try await run(whisper, padded, decodingOptions(hint: hint), preemptible: preemptible)
        if preemptible, preempt.withLock({ $0 }) { throw CancellationError() }
        // Garde-fou : une longue amorce peut faire recopier le texte voisin au lieu d'écouter, ou rendre
        // un texte vide. Dans ce cas, on recommence avec le seul dictionnaire.
        guard !hint.isEmpty else { return text }
        let echoed = text.count >= 12 && hint.tail.localizedCaseInsensitiveContains(text)
        guard text.isEmpty || echoed else { return text }
        if ProcessInfo.processInfo.environment["MURMURE_DEBUG"] != nil { print("[whisper] amorce écartée, nouvel essai sans contexte") }
        return try await run(whisper, padded, decodingOptions(), preemptible: preemptible)
    }

    private func run(_ whisper: WhisperKit, _ audio: [Float], _ options: DecodingOptions, preemptible: Bool = false) async throws -> String {
        // WhisperKit appelle ce rappel à chaque jeton ; `false` arrête le décodage.
        let results = try await whisper.transcribe(audioArray: audio, decodeOptions: options,
                                                   callback: { [preempt] _ in preemptible && preempt.withLock { $0 } ? false : nil })
        if ProcessInfo.processInfo.environment["MURMURE_DEBUG"] != nil, let t = results.first?.timings {
            print(String(format: "[whisper] encodage %.2f s · décodage %.2f s · %d jetons · amorce %d", t.encoding, t.decodingLoop, Int(t.totalDecodingLoops), options.promptTokens?.count ?? 0))
        }
        return Self.dropCredits(results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Génériques de sous-titres que Whisper invente dans le silence ou sur une voix très faible, appris des
    /// vidéos sous-titrées (« Sous-titrage Société Radio-Canada », « Réalisé par Neo035. », vus sur de vraies
    /// dictées). Seule une phrase courte qui commence ainsi est retirée : « l'audit réalisé par… » reste.
    private static let creditOpenings = ["sous-titrage", "sous-titres", "sous-titre", "realise par", "merci d'avoir regarde",
                                         "abonnez-vous", "amara.org"]

    static func dropCredits(_ text: String) -> String {
        var sentences: [String] = [], current = ""
        for character in text {
            current.append(character)
            if ".!?…".contains(character) { sentences.append(current); current = "" }
        }
        sentences.append(current)
        let isCredit = { (sentence: String) -> Bool in
            let folded = sentence.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
                .replacingOccurrences(of: "’", with: "'")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-–— "))
            return sentence.split(separator: " ").count <= 8 && creditOpenings.contains { folded.hasPrefix($0) }
        }
        // Rien à retirer : le texte reste tel quel, espaces compris.
        guard sentences.contains(where: isCredit) else { return text }
        // Les phrases gardées sont recollées telles quelles (« … » écrit « ... » reste entier).
        return sentences.filter { !isCredit($0) }.joined().trimmingCharacters(in: .whitespaces)
    }

    /// Mot transcrit, avec son intervalle en secondes depuis le début de l'audio.
    struct TimedWord {
        var text: String
        var start: Float
        var end: Float
    }

    /// Longueur visée des morceaux de la transcription continue : chacun tient dans une fenêtre de Whisper (30 s),
    /// coupé dans un silence, et plusieurs sont transcrits à la fois (`meetingWorkers`). Un lot de morceaux est
    /// l'unité d'attente d'une dictée urgente et de l'avancement affiché.
    static var pieceSeconds: Int {
        ProcessInfo.processInfo.environment["MURMURE_MORCEAU"].flatMap(Int.init) ?? 26
    }

    /// Morceaux transcrits en même temps. Chaque morceau a son propre décodeur ; trop de morceaux à la fois saturent
    /// la puce neuronale (« ANE op async execution has timed out » avec 8 morceaux, texte perdu).
    static var meetingWorkers: Int {
        max(1, ProcessInfo.processInfo.environment["MURMURE_WORKERS"].flatMap(Int.init) ?? 2)
    }

    /// Transcrit un long enregistrement en continu, avec l'horodatage de chaque mot : par morceaux d'environ 26 s
    /// coupés dans un silence, transcrits par lots de `meetingWorkers`, sans amorce (voir plus bas : en réunion,
    /// l'amorce fait perdre du texte ; `context`, les termes à reconnaître, sert au rapprochement des noms après
    /// coup, et à l'amorce si elle est réactivée). `progress` reçoit l'avancement avant chaque lot. Le découpage
    /// par WhisperKit lui-même (`chunkingStrategy: .vad`) n'est pas utilisé ici : il lance tous les morceaux à la
    /// fois et avale les erreurs d'un morceau.
    func transcribeTimed(_ audio: [Float], context: [String] = [], cuts: [Float] = [], progress: Progress? = nil) async throws -> [TimedWord] {
        guard let whisper else { return [] }
        // Découpage préalable, pour connaître le nombre de lots. `cuts` : coupes préférées (changements de voix),
        // en secondes ; à défaut, le plus long silence.
        var pieces: [(start: Int, end: Int)] = []
        var start = 0
        while start < audio.count {
            let end = Self.cutPoint(in: audio, from: start, seconds: Self.pieceSeconds, preferred: cuts)
            pieces.append((start, end))
            start = end
        }
        let env = ProcessInfo.processInfo.environment
        let debug = env["MURMURE_DEBUG"] != nil
        let workers = Self.meetingWorkers
        var words: [TimedWord] = []
        var tail = ""
        var index = 0
        failedPieces = (0, nil)
        while index < pieces.count {
            let batch = Array(pieces[index..<min(index + workers, pieces.count)])
            progress?(Self.transcriptionLabel(done: batch[0].start, total: audio.count))
            var options = decodingOptions()
            // Pas d'amorce en réunion (MURMURE_AMORCE_REUNION=64 pour l'essayer) : banc du 03/11/2026, 8 min à deux
            // voix, 3,0 % de mots faux sans amorce contre 10,5 % avec (dictionnaire, ou suite du texte, ou les deux :
            // le modèle clôt la fenêtre au changement de voix et des mots se perdent aux reprises), et 37 s contre 56.
            // Les noms propres sont rapprochés après coup des termes du contexte et du dictionnaire (Cleaner.applyTerms).
            options.promptTokens = Self.maxMeetingPromptTokens == 0 ? nil
                : meetingPrompt(context: env["MURMURE_SANS_TERMES"] != nil ? [] : context, tail: env["MURMURE_SANS_SUITE"] != nil ? "" : tail)
            options.wordTimestamps = env["MURMURE_SANS_MOTS"] == nil
            options.chunkingStrategy = nil
            // Langue : celle du réglage, ou, en automatique, français ou anglais choisi pour chaque fenêtre par
            // `transcribeWindow` (decodePiece). Fixer le français perdait l'anglais : une présentation en anglais
            // (oral du 03/11/2026) ressortait « traduite » en un français improbable, écarté comme invention.
            options.language = Settings.isAutoLanguage ? "fr" : Settings.language
            options.detectLanguage = false
            // Deux reprises à température plus haute suffisent ; au-delà, le texte est inventé plus que reconnu.
            options.temperatureFallbackCount = env["MURMURE_REPRISES"].flatMap(Int.init) ?? 2
            await acquire(urgent: false)
            let results: [(Int, [TranscriptionSegment])]
            do {
                let shared = tail
                results = try await withThrowingTaskGroup(of: (Int, [TranscriptionSegment]).self) { group in
                    for (slot, piece) in batch.enumerated() {
                        group.addTask { [options] in
                            do {
                                return (slot, try await self.decodePiece(piece, of: audio, options: options, context: context, tail: shared))
                            } catch let failure as PieceFailure {
                                // Le morceau est perdu, pas le lot : ce qui en a été reconnu est gardé.
                                await self.notePieceFailure(failure.error)
                                return (slot, failure.segments)
                            }
                        }
                    }
                    var collected: [(Int, [TranscriptionSegment])] = []
                    for try await result in group { collected.append(result) }
                    return collected.sorted { $0.0 < $1.0 }
                }
            } catch {
                release()
                throw error
            }
            release()
            for (slot, segments) in results {
                let offset = Float(batch[slot].start) / 16_000
                var pieceText: [String] = []
                for segment in segments.sorted(by: { $0.start < $1.start }) {
                    guard Self.isCredible(segment) else {
                        if debug { print(String(format: "[whisper] segment écarté %.1f s (T %.1f, vraisemblance %.2f, répétition %.2f) : %@", offset + segment.start, segment.temperature, segment.avgLogprob, segment.compressionRatio, segment.text as NSString)) }
                        continue
                    }
                    let timed = Self.timedWords(of: segment, offset: offset)
                    if debug {
                        print(String(format: "[whisper] segment %.1f–%.1f s (T %.1f, vraisemblance %.2f), %d mots horodatés (%@) : %@", offset + segment.start, offset + segment.end,
                                     segment.temperature, segment.avgLogprob,
                                     segment.words?.count ?? 0, timed.map { String(format: "%.1f", $0.start) }.joined(separator: " ") as NSString,
                                     segment.text as NSString))
                    }
                    words += timed
                    pieceText.append(contentsOf: timed.map(\.text))
                }
                if !pieceText.isEmpty { tail = String((tail + pieceText.joined()).suffix(300)) }
            }
            index += batch.count
        }
        // Tous les morceaux en défaut : ce n'est pas un enregistrement sans parole, c'est une panne du moteur.
        if failedPieces.count == pieces.count, let error = failedPieces.last { throw error }
        if failedPieces.count > 0 { print("[whisper] \(failedPieces.count) morceau(x) sur \(pieces.count) perdu(s)") }
        return words
    }

    /// Morceaux perdus pendant la transcription en cours, et la dernière erreur.
    private var failedPieces: (count: Int, last: Error?) = (0, nil)
    private func notePieceFailure(_ error: Error) { failedPieces = (failedPieces.count + 1, error) }

    /// Décode un morceau (≤ 30 s, une fenêtre de Whisper) ; les temps des segments sont relatifs au début du morceau.
    /// Le modèle clôt parfois la fenêtre avant la fin (au changement de voix, surtout avec une amorce), et la
    /// fenêtre suivante de WhisperKit revient vide : le reste du morceau serait perdu. Le reste est donc repris ici
    /// tant qu'il fait plus de 2,5 s et contient de la parole, avec, si une amorce est en usage, le texte qui vient
    /// d'être reconnu ajouté à celle-ci.
    private func decodePiece(_ piece: (start: Int, end: Int), of audio: [Float], options: DecodingOptions,
                             context: [String], tail: String) async throws -> [TranscriptionSegment] {
        guard let whisper else { return [] }
        let debug = ProcessInfo.processInfo.environment["MURMURE_DEBUG"] != nil
        var segments: [TranscriptionSegment] = []
        var options = options
        var from = piece.start
        var spoken = tail
        while piece.end - from >= 16_000 * 3 / 2 {
            // WhisperKit ignore la dernière seconde d'un audio : un reste bref est complété par du silence.
            var slice = Array(audio[from..<piece.end])
            let minimum = 16_000 * 3 / 2
            if slice.count < minimum { slice += [Float](repeating: 0, count: minimum - slice.count) }
            var decoded: [TranscriptionSegment]
            do {
                decoded = try await transcribeWindow(slice, options: &options)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // L'horodatage des mots peut échouer sur un morceau : on le reprend sans, plutôt que de le perdre.
                if debug { print("[whisper] morceau \(from / 16_000) s repris sans horodatage des mots : \(error)") }
                var bare = options
                bare.wordTimestamps = false
                do {
                    decoded = try await whisper.transcribe(audioArray: slice, decodeOptions: bare).flatMap(\.segments)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Un morceau en défaut (puce neuronale saturée, modèle en erreur) ne doit pas perdre toute la
                    // réunion : le reste est rendu, l'échec est journalisé et compté par l'appelant.
                    print("[whisper] morceau \(from / 16_000) s perdu : \(error.localizedDescription)")
                    throw PieceFailure(segments: segments, error: error)
                }
            }
            let shift = Float(from - piece.start) / 16_000
            let duration = Float(piece.end - from) / 16_000
            // Reprise d'un reste de morceau : le dernier mot de la fenêtre close peut être relu en tête (« notamment »
            // deux fois) ; les mots de tête identiques aux derniers mots déjà reconnus sont retirés.
            if from > piece.start, let previous = segments.last?.words?.suffix(2).map({ Self.folded($0.word) }), !previous.isEmpty,
               let first = decoded.first, var words = first.words, !words.isEmpty {
                let head = words.prefix(previous.count).map { Self.folded($0.word) }
                if Array(head) == previous {
                    words.removeFirst(previous.count)
                } else if let only = head.first, only == previous.last {
                    words.removeFirst()
                }
                decoded[0].words = words
                decoded[0].text = words.map(\.word).joined()
            }
            for var segment in decoded {
                segment.start += shift
                segment.end += shift
                // Sur une fenêtre courte, l'alignement place parfois un mot bien au-delà de l'audio (29 s pour 2 s
                // de son) : ces horodatages sont abandonnés, les mots seront répartis sur le segment.
                if let words = segment.words, words.contains(where: { $0.start > duration + 0.5 }) {
                    segment.words = nil
                    segment.end = min(segment.end, shift + duration)
                }
                segment.words = segment.words?.map { word in
                    var word = word
                    word.start += shift
                    word.end += shift
                    return word
                }
                if !(segment.text.trimmingCharacters(in: .whitespaces).isEmpty) { segments.append(segment) }
            }
            // Fin de ce qui a été reconnu dans la fenêtre ; sans texte, presque à la fin, ou sans parole dans ce qui
            // reste (une pause avant la coupe), le morceau est fini.
            let last = decoded.map(\.end).max() ?? 0
            guard last >= 0.5, !decoded.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { break }
            let next = from + Int(last * 16_000)
            guard piece.end - next >= 16_000 * 5 / 2, Self.hasSpeech(audio, from: next, to: piece.end) else { break }
            if debug { print(String(format: "[whisper] fenêtre close à %.1f s, reprise du reste du morceau (%.1f s)", Float(next) / 16_000, Float(piece.end - next) / 16_000)) }
            spoken = String((spoken + decoded.map(\.text).joined()).suffix(300))
            if options.promptTokens != nil { options.promptTokens = meetingPrompt(context: context, tail: spoken) }
            from = next
        }
        return segments
    }

    /// Une fenêtre de réunion. Réglage « automatique » : français ou anglais, seules langues en concours (la
    /// détection libre de WhisperKit partait ailleurs sur un passage bruité ou téléphonique). Whisper tranche net
    /// pour le français parlé (écart anglais − français de −2,3 à −7,6 au banc), mais hésite sur un anglais à
    /// l'accent français (−1 à +2) : entre `MURMURE_ECART_BAS` (−3) et `MURMURE_ECART_HAUT` (+3), la fenêtre est
    /// décodée dans les deux langues et la lecture la plus vraisemblable est gardée. `options.language` reçoit la
    /// langue retenue, pour une reprise de la fenêtre. `MURMURE_FRANCAIS_SEUL` : français fixé, comme avant.
    private func transcribeWindow(_ slice: [Float], options: inout DecodingOptions) async throws -> [TranscriptionSegment] {
        guard let whisper else { return [] }
        let env = ProcessInfo.processInfo.environment
        guard Settings.isAutoLanguage, env["MURMURE_FRANCAIS_SEUL"] == nil, let gap = await englishGap(slice) else {
            return try await whisper.transcribe(audioArray: slice, decodeOptions: options).flatMap(\.segments)
        }
        let low = env["MURMURE_ECART_BAS"].flatMap(Float.init) ?? -3
        let high = env["MURMURE_ECART_HAUT"].flatMap(Float.init) ?? 3
        guard gap > low, gap < high else {
            options.language = gap >= high ? "en" : "fr"
            return try await whisper.transcribe(audioArray: slice, decodeOptions: options).flatMap(\.segments)
        }
        var french = options, english = options
        french.language = "fr"
        english.language = "en"
        let inFrench = try await whisper.transcribe(audioArray: slice, decodeOptions: french).flatMap(\.segments)
        let inEnglish = try await whisper.transcribe(audioArray: slice, decodeOptions: english).flatMap(\.segments)
        let (scoreFrench, scoreEnglish) = (Self.readingScore(inFrench), Self.readingScore(inEnglish))
        let keepEnglish = scoreEnglish > scoreFrench
        if env["MURMURE_DEBUG"] != nil {
            print(String(format: "[whisper] langue incertaine (%+.1f) : vraisemblance français %.2f, anglais %.2f → %@", gap, scoreFrench, scoreEnglish, keepEnglish ? "anglais" : "français"))
        }
        options.language = keepEnglish ? "en" : "fr"
        return keepEnglish ? inEnglish : inFrench
    }

    /// Vraisemblance d'une lecture : moyenne des log-probabilités de ses jetons de texte, les segments qui seraient
    /// écartés comme inventions comptant pour très improbables (une lecture « traduite » finit souvent en reprise
    /// à température plus haute). Une lecture vide ne gagne jamais.
    static func readingScore(_ segments: [TranscriptionSegment]) -> Float {
        var total: Float = 0, count = 0
        for segment in segments {
            let logProbs = segment.tokenLogProbs.flatMap(\.values)
            guard !logProbs.isEmpty else { continue }
            total += isCredible(segment) ? logProbs.reduce(0, +) : -5 * Float(logProbs.count)
            count += logProbs.count
        }
        return count == 0 ? -.infinity : total / Float(count)
    }

    /// Écart de log-probabilité entre l'anglais et le français pour le premier jeton de langue de Whisper (positif :
    /// l'anglais est plus probable). Coûte un passage de l'encodeur ; nil si la détection échoue.
    private func englishGap(_ slice: [Float]) async -> Float? {
        guard let whisper, let tokenizer = whisper.tokenizer,
              let french = tokenizer.convertTokenToId("<|fr|>"), let english = tokenizer.convertTokenToId("<|en|>"),
              let samples = whisper.audioProcessor.padOrTrim(fromArray: slice, startAt: 0, toLength: 480_000) else { return nil }
        do {
            guard let mel = try await whisper.featureExtractor.logMelSpectrogram(fromAudio: samples),
                  let encoded = try await whisper.audioEncoder.encodeFeatures(mel) as? MLMultiArray,
                  let inputs = try whisper.textDecoder.prepareDecoderInputs(withPrompt: [tokenizer.specialTokens.startOfTranscriptToken]) as? DecodingInputs
            else { return nil }
            inputs.inputIds[0] = NSNumber(value: tokenizer.specialTokens.startOfTranscriptToken)
            inputs.cacheLength[0] = 0
            let output = try await whisper.textDecoder.predictLogits(TextDecoderMLMultiArrayInputType(
                inputIds: inputs.inputIds, cacheLength: inputs.cacheLength, keyCache: inputs.keyCache,
                valueCache: inputs.valueCache, kvCacheUpdateMask: inputs.kvCacheUpdateMask,
                encoderOutputEmbeds: encoded, decoderKeyPaddingMask: inputs.decoderKeyPaddingMask))
            guard let logits = (output as? TextDecoderMLMultiArrayOutputType)?.logits else { return nil }
            let gap = logits[[0, 0, NSNumber(value: english)]].floatValue - logits[[0, 0, NSNumber(value: french)]].floatValue
            if ProcessInfo.processInfo.environment["MURMURE_DEBUG"] != nil {
                print(String(format: "[whisper] langue : anglais − français %+.1f sur %.1f s", gap, Float(slice.count) / 16_000))
            }
            return gap
        } catch {
            return nil
        }
    }

    /// Échec définitif d'un morceau : ce qui en avait déjà été reconnu, et l'erreur.
    struct PieceFailure: Error {
        let segments: [TranscriptionSegment]
        let error: Error
    }

    /// Y a-t-il de la parole entre deux échantillons (au moins 0,3 s au-dessus du seuil adaptatif du passage) ?
    static func hasSpeech(_ audio: [Float], from: Int, to: Int) -> Bool {
        let frame = 1_600
        guard to - from >= frame * 3 else { return false }
        let levels = SpeechLevels.levels(Array(audio[from..<to]), frame: frame)
        // Le seuil est calé sur un passage plus large (le reste seul n'a peut-être que du bruit, dont le seuil
        // ferait de la parole).
        let context = SpeechLevels.levels(Array(audio[max(0, from - 20 * 16_000)..<to]), frame: frame)
        return SpeechLevels.hasSpeech(levels, threshold: SpeechLevels.threshold(context))
    }

    /// Mot sans accents, casse, espaces ni ponctuation, pour comparer deux lectures d'un même mot.
    static func folded(_ word: String) -> String {
        word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Amorce d'un bloc de réunion, 64 jetons au plus : les termes du contexte (participants, objet) puis le
    /// dictionnaire, et la fin du texte du bloc précédent pour ce qui reste. Plus longue, elle prendrait sur les
    /// 223 jetons d'une fenêtre de 30 s et la fin d'un morceau dense serait tronquée.
    private func meetingPrompt(context: [String], tail: String) -> [Int]? {
        guard let tokenizer = whisper?.tokenizer else { return nil }
        func encode(_ text: String) -> [Int] {
            tokenizer.encode(text: text).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let limit = Self.maxMeetingPromptTokens
        var terms: [String] = []
        let vocabulary = ProcessInfo.processInfo.environment["MURMURE_SANS_TERMES"] != nil ? [] : Settings.vocabulary()
        for term in context + vocabulary where !terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            terms.append(term)
        }
        var tokens: [Int] = []
        var kept: [String] = []
        for term in terms {
            let candidate = encode(" " + (kept + [term]).joined(separator: ", ") + ".")
            guard candidate.count <= limit * 2 / 3 else { break }
            kept.append(term)
            tokens = candidate
        }
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { tokens += encode(" " + trimmed).suffix(limit - tokens.count) }
        return tokens.isEmpty ? nil : tokens
    }

    static var maxMeetingPromptTokens: Int {
        ProcessInfo.processInfo.environment["MURMURE_AMORCE_REUNION"].flatMap(Int.init) ?? 0
    }

    /// Un segment Whisper est gardé sauf s'il ressemble à une invention : troisième essai de température, jetons
    /// très improbables, texte qui boucle (même mot cinq fois de suite, même paire quatre fois), débit impossible,
    /// mots presque tous improbables, ou rien d'autre qu'un générique de sous-titres. WhisperKit ne calcule pas la
    /// probabilité de silence (toujours 0) et son taux de compression porte sur les jetons de toute la fenêtre :
    /// ni l'un ni l'autre ne servent.
    static func isCredible(_ segment: TranscriptionSegment) -> Bool {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !dropCredits(text).isEmpty else { return false }
        // Troisième essai (T 0,4) : le texte est déjà en partie tiré au sort.
        if segment.temperature > 0.3 { return false }
        // Vraisemblance du segment lui-même (celle que WhisperKit recopie dans `avgLogprob` est celle de la fenêtre
        // entière, prefill compris) : moyenne des jetons de texte.
        let logProbs = segment.tokenLogProbs.flatMap(\.values)
        if logProbs.count >= 3, logProbs.reduce(0, +) / Float(logProbs.count) < -1.5 { return false }
        // Boucle : un mot répété cinq fois de suite, ou une paire quatre fois (« non, non, non » reste une phrase).
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: .punctuationCharacters) }
        if words.count >= 5 {
            var repeats = 1
            for i in 1..<words.count {
                repeats = words[i] == words[i - 1] ? repeats + 1 : 1
                if repeats >= 5 { return false }
            }
            if words.count >= 8 {
                var pairs = 1
                for i in stride(from: 2, to: words.count - 1, by: 2) {
                    pairs = words[i] == words[i - 2] && words[i + 1] == words[i - 1] ? pairs + 1 : 1
                    if pairs >= 4 { return false }
                }
            }
        }
        let duration = segment.end - segment.start
        // Débit impossible : plus de dix mots par seconde (une phrase vive peut en faire six, et l'alignement
        // raccourcit parfois un segment ; une boucle en met des dizaines).
        if duration > 2, Float(words.count) / duration > 10 { return false }
        if let timed = segment.words, timed.count >= 3, timed.filter({ $0.probability < 0.15 }).count * 2 > timed.count { return false }
        return true
    }

    /// Mots d'un segment, horodatés : ceux de WhisperKit (alignement sur l'attention) quand il les donne, sinon
    /// les mots du texte répartis uniformément sur le segment.
    static func timedWords(of segment: TranscriptionSegment, offset: Float) -> [TimedWord] {
        if let words = segment.words, !words.isEmpty {
            return words.compactMap { word in
                let text = word.word
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return TimedWord(text: text, start: offset + word.start, end: offset + max(word.end, word.start))
            }
        }
        let pieces = segment.text.split(separator: " ").map { " " + $0 }
        guard !pieces.isEmpty else { return [] }
        let step = (segment.end - segment.start) / Float(pieces.count)
        return pieces.enumerated().map { index, piece in
            TimedWord(text: piece, start: offset + segment.start + Float(index) * step,
                      end: offset + segment.start + Float(index + 1) * step)
        }
    }

    /// Transcrit un long enregistrement (une seule voix) : texte de la transcription continue.
    func transcribeLong(_ audio: [Float], context: [String] = [], progress: Progress? = nil) async throws -> String {
        let words = try await transcribeTimed(audio, context: context, progress: progress)
        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        return Cleaner.applyTerms(text, terms: Self.correctionTerms(context: context))
    }

    /// Termes rapprochés des mots transcrits (voir `Cleaner.applyTerms`) : ceux du contexte, puis le dictionnaire.
    /// MURMURE_SANS_RAPPROCHEMENT=1 désactive ce rapprochement pour les essais.
    static func correctionTerms(context: [String]) -> [String] {
        guard ProcessInfo.processInfo.environment["MURMURE_SANS_RAPPROCHEMENT"] == nil else { return [] }
        var terms: [String] = []
        for term in context + Settings.vocabulary() where !terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            terms.append(term)
        }
        return terms
    }

    /// « Transcription 12 / 60 min » (en secondes sous deux minutes), à partir de comptes d'échantillons.
    static func transcriptionLabel(done: Int, total: Int) -> String {
        let rate = 16_000
        guard total >= 120 * rate else { return "Transcription \(done / rate) / \(total / rate) s" }
        let minutes = max(1, (total + 30 * rate) / (60 * rate))
        return "Transcription \(min(minutes, done / (60 * rate))) / \(minutes) min"
    }

    /// Fin du bloc : le passage le plus calme dans les 8 s qui précèdent `seconds` après `start` (ou la fin de
    /// l'audio, si elle est à moins de `seconds` + 3 s).
    private static func cutPoint(in audio: [Float], from start: Int, seconds: Int, preferred: [Float] = []) -> Int {
        let rate = 16_000
        guard audio.count - start > (seconds + 3) * rate else { return audio.count }
        // Une coupe préférée (changement de voix) dans les 12 dernières secondes : la plus tardive. Un morceau qui
        // ne mêle pas deux voix est mieux reconnu (banc : les dictées d'une vraie voix au milieu d'une voix de
        // synthèse perdaient des mots).
        let low = Float(start) / Float(rate) + Float(seconds - 12), high = Float(start) / Float(rate) + Float(seconds)
        if let cut = preferred.filter({ $0 >= low && $0 <= high }).max() { return Int(cut * Float(rate)) }
        // Au milieu du plus long silence (tranches de 100 ms sous le seuil adaptatif de la parole, calculé sur le
        // morceau entier) dans les 10 dernières secondes : une coupe entre deux mots d'une même phrase faisait
        // perdre un mot au début du morceau suivant. À défaut de silence, la tranche la plus calme.
        let frame = rate / 10
        let levels = SpeechLevels.levels(Array(audio[start..<(start + seconds * rate)]), frame: frame)
        let threshold = SpeechLevels.threshold(levels)
        let first = (seconds - 10) * rate / frame
        var best: (index: Int, length: Int)?
        var runStart: Int?
        for index in first...levels.count {
            let quiet = index < levels.count && levels[index] <= threshold
            if quiet {
                if runStart == nil { runStart = index }
            } else if let from = runStart {
                if index - from > (best?.length ?? 0) { best = (from, index - from) }
                runStart = nil
            }
        }
        if let best, best.length >= 2 {
            return start + (best.index * frame) + best.length * frame / 2
        }
        let quietest = (first..<levels.count).min { levels[$0] < levels[$1] } ?? levels.count - 1
        return start + quietest * frame + frame / 2
    }

    /// Plage de parole d'une voix, en secondes depuis le début de l'audio.
    struct VoiceSpan {
        let voice: String
        var start: Float
        var end: Float
    }

    /// Distingue les voix : plages de parole par voix, dans l'ordre du temps, les segments consécutifs d'une même
    /// voix regroupés (pauses de moins d'une seconde). Renvoie nil s'il n'y a qu'une voix ou si la distinction
    /// n'est pas disponible.
    func diarize(_ audio: [Float], progress: Progress? = nil) async throws -> [VoiceSpan]? {
        guard let voices = try await voices(audio, progress: progress), Set(voices.spans.map(\.voice)).count >= 2 else { return nil }
        return voices.spans
    }

    /// Voix trouvées dans un audio : plages de parole (comme `diarize`) et empreinte de chaque voix.
    struct Voices {
        let spans: [VoiceSpan]
        let prints: [String: Voiceprint]
    }

    /// Comme `diarize`, mais aussi pour une seule voix, avec l'empreinte de chacune. Nil si la distinction des voix
    /// n'est pas disponible.
    func voices(_ audio: [Float], progress: Progress? = nil) async throws -> Voices? {
        guard let speakers else { return nil }
        await acquireSpeakers()
        defer { releaseSpeakers() }
        progress?("Voix 0 %")
        var voices: (@Sendable (Int, Int) -> Void)?
        if let progress { voices = { @Sendable done, total in progress("Voix \(100 * done / max(total, 1)) %") } }
        let diarization = try await speakers.process(audio: audio, progressCallback: voices)
        let segments = diarization.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        if ProcessInfo.processInfo.environment["MURMURE_DEBUG"] != nil {
            print("[voix] \(Set(segments.map(\.speakerId)).count) voix")
            for segment in segments {
                print(String(format: "[voix] %5.1f–%5.1f s  %@", segment.startTimeSeconds, segment.endTimeSeconds, segment.speakerId))
            }
        }
        var spans: [VoiceSpan] = []
        for segment in segments {
            if let last = spans.last, last.voice == segment.speakerId, segment.startTimeSeconds - last.end < 1 {
                spans[spans.count - 1].end = max(last.end, segment.endTimeSeconds)
            } else {
                spans.append(VoiceSpan(voice: segment.speakerId, start: segment.startTimeSeconds, end: segment.endTimeSeconds))
            }
        }
        return Voices(spans: spans, prints: Voiceprint.byVoice(chunks: diarization.chunkEmbeddings ?? [], spans: spans))
    }

    /// Distingue les voix, puis transcrit chaque tour de parole séparément (avec le vocabulaire).
    /// Renvoie nil s'il n'y a qu'une voix (dictée ordinaire) ou si la distinction n'est pas disponible.
    func speakerTurns(_ audio: [Float]) async throws -> [Turn]? {
        guard let turns = try await speakerTurns(audio, micShare: nil)?.turns, Set(turns.map(\.speaker)).count >= 2 else { return nil }
        return turns
    }

    /// Variante pour une réunion enregistrée au micro et au son de l'ordinateur : `micShare(début, fin)` donne
    /// la part de l'énergie venue du micro entre deux échantillons. La voix entendue surtout au micro est celle
    /// de l'utilisateur (les autres arrivent par le son de l'ordinateur) : elle est renvoyée dans `own`.
    /// `progress` reçoit l'avancement : la distinction des voix en pourcentage, puis la transcription en minutes.
    /// `context` : termes à reconnaître (participants, objet de la réunion).
    ///
    /// Jusqu'au 03/11/2026, chaque plage de parole d'une voix était transcrite isolément : Whisper perdait le fil
    /// de la conversation (« contrat de session »), inventait sur les plages courtes (« Wow, we're not home with a
    /// bug ») et un passage entier disparaissait quand une plage était mal découpée. Désormais l'audio est transcrit
    /// en continu, chaque mot horodaté, puis attribué à la voix qui parle à ce moment-là.
    func speakerTurns(_ audio: [Float], micShare: ((Int, Int) -> Float)?, context: [String] = [],
                      progress: Progress? = nil) async throws -> SpeakerTurns? {
        guard let voices = try await voices(audio, progress: progress), Set(voices.spans.map(\.voice)).count >= 2 else { return nil }
        let spans = voices.spans
        // Coupes préférées des morceaux : au milieu des pauses entre deux plages de voix différentes (0,25 s au moins).
        var cuts: [Float] = []
        for (previous, next) in zip(spans, spans.dropFirst()) where next.voice != previous.voice && next.start - previous.end >= 0.25 {
            cuts.append((previous.end + next.start) / 2)
        }
        let words = try await transcribeTimed(audio, context: context, cuts: cuts, progress: progress)
        let attributed = Self.attribute(words, to: spans)
        return Self.buildTurns(attributed, spans: spans, sampleCount: audio.count, micShare: micShare,
                               terms: Self.correctionTerms(context: context), prints: voices.prints)
    }

    /// Tours de parole d'une réunion, l'interlocuteur « Moi » s'il est reconnu au micro, et l'empreinte de chaque
    /// interlocuteur (par numéro) pour le reconnaître d'une réunion à l'autre.
    typealias SpeakerTurns = (turns: [Turn], own: Int?, prints: [Int: Voiceprint])

    /// Tours de parole à partir des mots attribués aux voix : voix numérotées dans l'ordre où elles prennent la
    /// parole (1, 2, 3…), mots consécutifs d'une même voix réunis, règles fixes et rapprochement des noms par tour ;
    /// puis « Moi » : la seule voix nettement plus forte au micro qu'au son de l'ordinateur sur ses plages.
    /// Partagé par la transcription sur ce Mac et la transcription en ligne (`OnlineTranscription`).
    /// `prints` : empreinte de chaque voix (par nom de voix), renvoyée par numéro d'interlocuteur.
    static func buildTurns(_ attributed: [(TimedWord, String)], spans: [VoiceSpan], sampleCount: Int,
                           micShare: ((Int, Int) -> Float)?, terms: [String],
                           prints: [String: Voiceprint] = [:]) -> SpeakerTurns {
        var numbering: [String: Int] = [:]
        var turns: [Turn] = []
        var pending: (voice: String, text: String)?
        func flush() {
            guard let turn = pending else { return }
            let text = Cleaner.applyTerms(Cleaner.applyCommands(turn.text), terms: terms)
            pending = nil
            guard !text.isEmpty else { return }
            if numbering[turn.voice] == nil { numbering[turn.voice] = numbering.count + 1 }
            let speaker = numbering[turn.voice]!
            if turns.last?.speaker == speaker {
                turns[turns.count - 1].text += " " + text
            } else {
                turns.append(Turn(speaker: speaker, text: text))
            }
        }
        for (word, voice) in attributed {
            if pending?.voice == voice {
                pending?.text += word.text
            } else {
                flush()
                pending = (voice, word.text)
            }
        }
        flush()
        guard !turns.isEmpty else { return ([], nil, [:]) }
        var printsByNumber: [Int: Voiceprint] = [:]
        for (voice, number) in numbering { printsByNumber[number] = prints[voice] }

        // Part de chaque voix au micro (contre le son de l'ordinateur), sur toutes ses plages de parole.
        var shares: [Int: (weighted: Float, duration: Float)] = [:]
        if let micShare {
            for span in spans {
                guard let speaker = numbering[span.voice] else { continue }
                let from = max(0, Int(span.start * 16_000)), to = min(sampleCount, Int(span.end * 16_000))
                guard to > from else { continue }
                let duration = span.end - span.start
                let share = shares[speaker] ?? (0, 0)
                shares[speaker] = (share.weighted + micShare(from, to) * duration, share.duration + duration)
            }
        }
        // Une seule voix nettement plus forte au micro qu'à l'ordinateur : c'est l'utilisateur.
        // Plusieurs (collègues dans la même pièce) : on ne devine pas.
        let micVoices = shares.filter { $0.value.weighted / max($0.value.duration, 0.001) > 0.7 }.map(\.key)
        if ProcessInfo.processInfo.environment["MURMURE_DEBUG"] != nil {
            for (speaker, share) in shares.sorted(by: { $0.key < $1.key }) {
                print(String(format: "[voix] interlocuteur %d : %.0f %% au micro", speaker, 100 * share.weighted / max(share.duration, 0.001)))
            }
        }
        return (turns, micVoices.count == 1 ? micVoices[0] : nil, printsByNumber)
    }

    /// Attribue chaque mot à une voix : celle dont la plage de parole recouvre le plus l'intervalle du mot ;
    /// sans recouvrement, la plage la plus proche à moins d'une seconde, sinon la voix du mot précédent.
    /// Un mot isolé entre deux mots d'une même voix, dont le recouvrement est faible, rejoint cette voix :
    /// l'horodatage d'un mot n'est précis qu'à quelques dixièmes de seconde.
    static func attribute(_ words: [TimedWord], to spans: [VoiceSpan]) -> [(TimedWord, String)] {
        let spans = spans.sorted { $0.start < $1.start }
        guard !spans.isEmpty, !words.isEmpty else { return [] }
        let words = words.sorted { $0.start < $1.start }
        var voices: [String] = []
        var ratios: [Float] = []
        var cursor = 0
        for word in words {
            // Les plages commençant avant la fin du mot ; `cursor` avance avec le temps.
            while cursor < spans.count, spans[cursor].end < word.start - 1 { cursor += 1 }
            var best: (voice: String, overlap: Float)?
            var nearest: (voice: String, gap: Float)?
            var index = cursor
            while index < spans.count, spans[index].start < word.end + 1 {
                let span = spans[index]
                let overlap = min(span.end, word.end) - max(span.start, word.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) { best = (span.voice, overlap) }
                let gap = max(span.start - word.end, word.start - span.end, 0)
                if nearest == nil || gap < nearest!.gap { nearest = (span.voice, gap) }
                index += 1
            }
            let duration = max(word.end - word.start, 0.05)
            if let best {
                voices.append(best.voice)
                ratios.append(min(best.overlap / duration, 1))
            } else if let nearest, nearest.gap <= 1 {
                voices.append(nearest.voice)
                ratios.append(0)
            } else {
                voices.append(voices.last ?? spans[min(cursor, spans.count - 1)].voice)
                ratios.append(0)
            }
        }
        if voices.count >= 3 {
            for i in 1..<(voices.count - 1) where voices[i - 1] == voices[i + 1] && voices[i] != voices[i - 1] && ratios[i] < 0.5 {
                voices[i] = voices[i - 1]
            }
        }
        // Un changement de voix tombe de préférence sur une fin de phrase : l'horodatage d'un mot n'est précis
        // qu'à quelques dixièmes de seconde, et un ou deux mots frontières au recouvrement faible suivent la
        // ponctuation la plus proche (« …les comptes. | Multiplayer ? » plutôt que « …les | comptes. Multiplayer ? »).
        if ProcessInfo.processInfo.environment["MURMURE_SANS_PONCTUATION"] == nil {
            func endsSentence(_ word: TimedWord) -> Bool {
                let text = word.text.trimmingCharacters(in: .whitespaces)
                guard let last = text.last, ".!?…".contains(last) else { return false }
                // « M. », « Me. », « cf. » : une abréviation, pas une fin de phrase.
                return !(last == "." && text.dropLast().filter(\.isLetter).count <= 3 && text.dropLast().allSatisfy(\.isLetter))
            }
            var i = 1
            while i < voices.count {
                guard voices[i] != voices[i - 1] else { i += 1; continue }
                // Coupe entre i-1 et i. La ponctuation est-elle un ou deux mots plus loin, les mots entre étant peu sûrs ?
                if i + 1 < voices.count, !endsSentence(words[i - 1]), ratios[i] < 0.7, endsSentence(words[i]), voices[i + 1] == voices[i] {
                    voices[i] = voices[i - 1]; i += 2; continue
                }
                if i + 2 < voices.count, !endsSentence(words[i - 1]), ratios[i] < 0.7, ratios[i + 1] < 0.7, endsSentence(words[i + 1]),
                   voices[i + 2] == voices[i], voices[i + 1] == voices[i] {
                    voices[i] = voices[i - 1]; voices[i + 1] = voices[i - 1]; i += 3; continue
                }
                // Ou un ou deux mots plus tôt ?
                if endsSentence(words[i - 2 < 0 ? 0 : i - 2]), i >= 2, ratios[i - 1] < 0.7, voices[i - 2] == voices[i - 1], !endsSentence(words[i - 1]) {
                    voices[i - 1] = voices[i]
                } else if i >= 3, endsSentence(words[i - 3]), ratios[i - 1] < 0.7, ratios[i - 2] < 0.7, voices[i - 3] == voices[i - 1],
                          voices[i - 2] == voices[i - 1], !endsSentence(words[i - 1]), !endsSentence(words[i - 2]) {
                    voices[i - 1] = voices[i]; voices[i - 2] = voices[i]
                }
                i += 1
            }
        }
        return Array(zip(words, voices))
    }
}

/// Horodatage des mots de WhisperKit 1.1.1 corrigé pour les décodages avec amorce (issue argmaxinc/WhisperKit#542) :
/// le décodeur range les poids d'attention de chaque jeton à son rang dans la séquence complète, amorce comprise
/// (`<|startofprev|>` + jetons d'amorce + `<|startoftranscript|>`…), alors que l'alignement les lit à partir de
/// `<|startoftranscript|>`. Avec le dictionnaire en amorce, tous les mots se retrouvaient à la même seconde.
/// Ici les lignes sont décalées d'autant avant l'alignement ; sans amorce, rien ne change.
final class PromptAwareSeeker: SegmentSeeking {
    private let inner = SegmentSeeker()

    func findSeekPointAndSegments(decodingResult: DecodingResult, options: DecodingOptions, allSegmentsCount: Int,
                                  currentSeek: Int, segmentSize: Int, sampleRate: Int, timeToken: Int, specialToken: Int,
                                  tokenizer: WhisperTokenizer) -> (Int, [TranscriptionSegment]?) {
        inner.findSeekPointAndSegments(decodingResult: decodingResult, options: options, allSegmentsCount: allSegmentsCount,
                                       currentSeek: currentSeek, segmentSize: segmentSize, sampleRate: sampleRate,
                                       timeToken: timeToken, specialToken: specialToken, tokenizer: tokenizer)
    }

    func addWordTimestamps(segments: [TranscriptionSegment], alignmentWeights: MLMultiArray, tokenizer: WhisperTokenizer,
                           seek: Int, segmentSize: Int, prependPunctuations: String, appendPunctuations: String,
                           lastSpeechTimestamp: Float, options: DecodingOptions, timings: TranscriptionTimings) throws -> [TranscriptionSegment]? {
        var weights = alignmentWeights
        if options.usePrefillPrompt, let prompt = options.promptTokens {
            // Même troncature que le décodeur : les 111 derniers jetons, sans jetons spéciaux.
            let kept = Array(prompt.suffix(Constants.maxTokenContext / 2 - 1)).filter { $0 < tokenizer.specialTokens.specialTokenBegin }.count
            if kept > 0 { weights = try Self.shifted(alignmentWeights, by: kept + 1) }
        }
        return try inner.addWordTimestamps(segments: segments, alignmentWeights: weights, tokenizer: tokenizer, seek: seek,
                                           segmentSize: segmentSize, prependPunctuations: prependPunctuations,
                                           appendPunctuations: appendPunctuations, lastSpeechTimestamp: lastSpeechTimestamp,
                                           options: options, timings: timings)
    }

    /// Copie du tableau (jetons × trames) où la ligne r reçoit la ligne r + `offset` ; les dernières lignes restent à zéro.
    static func shifted(_ weights: MLMultiArray, by offset: Int) throws -> MLMultiArray {
        let rows = weights.shape[0].intValue
        let result = try MLMultiArray(shape: weights.shape, dataType: weights.dataType)
        let rowStride = weights.strides[0].intValue
        let elementSize: Int
        switch weights.dataType {
        case .float16: elementSize = 2
        case .float32: elementSize = 4
        case .double: elementSize = 8
        default: elementSize = 4
        }
        let rowBytes = rowStride * elementSize
        weights.withUnsafeBytes { source in
            result.withUnsafeMutableBytes { destination, _ in
                memset(destination.baseAddress!, 0, destination.count)
                guard rows > offset else { return }
                memcpy(destination.baseAddress!, source.baseAddress! + offset * rowBytes, (rows - offset) * rowBytes)
            }
        }
        return result
    }
}

/// Premier horodatage d'une fenêtre borné à 1 s, comme chez OpenAI (`max_initial_timestamp`) ; WhisperKit 1.1.1 a
/// cette règle en commentaire. Sans elle, dès qu'une amorce est donnée, le modèle peut ouvrir la fenêtre à
/// <|0.00|><|12.80|> et tenir les douze premières secondes pour déjà transcrites : sur le banc, un morceau de
/// réunion sur trois perdait sa première phrase. Le filtre n'agit que tant qu'aucun mot n'a été produit après
/// `<|transcribe|>`, où il interdit les horodatages au-delà de la borne.
final class InitialTimestampFilter: LogitsFiltering {
    private let tokens: SpecialTokens
    private let lastAllowed: Int

    init(specialTokens: SpecialTokens, maxInitialSeconds: Float = 1) {
        tokens = specialTokens
        lastAllowed = specialTokens.timeTokenBegin + Int(maxInitialSeconds / WhisperKit.secondsPerTimeToken)
    }

    func filterLogits(_ logits: MLMultiArray, withTokens current: [Int]) -> MLMultiArray {
        // Tant que rien que des horodatages (deux au plus) ont suivi <|transcribe|>, le prochain horodatage est borné :
        // le modèle ouvre la fenêtre par <|0.00|> puis peut encore sauter par un second horodatage.
        guard let task = current.lastIndex(of: tokens.transcribeToken) else { return logits }
        let after = current[(task + 1)...]
        guard after.count <= 2, after.allSatisfy({ $0 >= tokens.timeTokenBegin }) else { return logits }
        let count = logits.shape.last?.intValue ?? 0
        guard lastAllowed + 1 < count else { return logits }
        logits.fillLastDimension(indexes: (lastAllowed + 1)..<count, with: -FloatType.infinity)
        return logits
    }
}

/// Détection de voix pour le découpage de WhisperKit, en tranches de 100 ms, au seuil de `SpeechLevels`.
final class AdaptiveVAD: VoiceActivityDetector, @unchecked Sendable {
    init() { super.init(sampleRate: 16_000, frameLengthSamples: 1_600) }

    override func voiceActivity(in waveform: [Float]) -> [Bool] {
        let frame = frameLengthSamples
        let levels = stride(from: 0, to: waveform.count, by: frame).map { start in
            SpeechLevels.levels(Array(waveform[start..<min(start + frame, waveform.count)]), frame: min(frame, waveform.count - start)).first ?? 0
        }
        let threshold = SpeechLevels.threshold(levels)
        return levels.map { $0 > threshold }
    }
}
