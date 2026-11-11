import Foundation

/// Écho des haut-parleurs dans le micro, pendant une visio sans casque.
///
/// Le micro du Mac entend aussi les participants à distance : quelques dizaines de millisecondes après le son de
/// l'ordinateur, réverbérés par la pièce. Additionnées, les deux pistes donnaient chaque phrase de la visio en double,
/// décalée, comme dans une salle très réverbérante ; et la part « au micro » des voix à distance montait, ce qui
/// brouille la reconnaissance de « Moi ». Le son de l'ordinateur sert de référence : là où le micro n'entend que
/// l'écho attendu, il est retiré du mélange ; là où il entend nettement plus (l'utilisateur parle, même par-dessus
/// la visio), il reste. Avec un casque, aucun écho n'est trouvé et le mélange reste celui d'avant.
///
/// Essais : `MURMURE_SANS_ECHO=1` désactive le retrait ; `MURMURE_ECHO_MARGE`, `MURMURE_ECHO_SEUIL` ajustent les seuils.
enum EchoGate {
    /// Tranches de 10 ms à 16 kHz.
    static let frame = 160
    /// Retard le plus long cherché entre le son de l'ordinateur et son écho au micro (enceintes Bluetooth comprises).
    static let maxDelay = 60
    /// Décroissance de la réverbération par tranche (environ 0,4 s pour 60 dB).
    static let decay: Float = 0.84
    /// Blocs de 30 s : le retard est recherché bloc par bloc, il peut changer en cours de réunion (sortie changée).
    static let block = 3000

    struct Analysis {
        /// Poids du micro dans le mélange, par tranche de 10 ms (0 : écho seul, retiré ; 1 : gardé).
        let weights: [Float]
        /// Retard de l'écho le plus fréquent, en millisecondes.
        let delayMs: Int
        /// Corrélation entre le son de l'ordinateur et le micro à ce retard (0 à 1).
        let correlation: Float
        /// Niveau de l'écho rapporté au son de l'ordinateur.
        let coupling: Float
        /// Part des tranches où l'ordinateur parle dont le micro a été retiré.
        let removed: Float
    }

    /// Analyse des deux pistes ; nil s'il n'y a pas d'écho (casque, son de l'ordinateur muet) ou trop peu d'audio.
    static func analyze(mic: [Float], system: [Float]) -> Analysis? {
        let env = ProcessInfo.processInfo.environment
        guard env["MURMURE_SANS_ECHO"] == nil else { return nil }
        let micLevels = SpeechLevels.levels(mic, frame: frame)
        let systemLevels = SpeechLevels.levels(system, frame: frame)
        let count = min(micLevels.count, systemLevels.count)
        guard count > 1000 else { return nil }
        let systemThreshold = SpeechLevels.threshold(Array(systemLevels[0..<count]))
        let logMic = micLevels.map { log10(max($0, 1e-5)) }
        let logSystem = systemLevels.map { log10(max($0, 1e-5)) }

        // 1. Retard : corrélation des niveaux (en décibels) du micro décalé et de l'ordinateur, sur les seules
        // tranches où l'ordinateur parle. L'écho suit les syllabes de la visio ; la voix de l'utilisateur, non.
        struct Sums {
            // En double précision : sur une réunion de plusieurs heures, les sommes en Float perdaient la variance.
            var n: Double = 0, x: Double = 0, y: Double = 0, xx: Double = 0, yy: Double = 0, xy: Double = 0
            mutating func add(_ fa: Float, _ fb: Float) {
                let a = Double(fa), b = Double(fb)
                n += 1; x += a; y += b; xx += a * a; yy += b * b; xy += a * b
            }
            func merged(_ r: Sums) -> Sums {
                Sums(n: n + r.n, x: x + r.x, y: y + r.y, xx: xx + r.xx, yy: yy + r.yy, xy: xy + r.xy)
            }
            var correlation: Float {
                guard n > 50 else { return 0 }
                let cov = xy / n - (x / n) * (y / n)
                let vx = xx / n - (x / n) * (x / n), vy = yy / n - (y / n) * (y / n)
                return vx > 1e-6 && vy > 1e-6 ? Float(cov / (vx * vy).squareRoot()) : 0
            }
        }
        let blocks = (count + block - 1) / block
        var sums = [[Sums]](repeating: [Sums](repeating: Sums(), count: maxDelay + 1), count: blocks)
        for i in 0..<count where systemLevels[i] > systemThreshold {
            let b = i / block
            for lag in 0...maxDelay where i + lag < count {
                sums[b][lag].add(logSystem[i], logMic[i + lag])
            }
        }
        let total = (0...maxDelay).map { lag in sums.reduce(Sums()) { $0.merged($1[lag]) } }
        let globalCurve = total.map(\.correlation)
        guard let globalLag = globalCurve.indices.max(by: { globalCurve[$0] < globalCurve[$1] }) else { return nil }
        let minimum = env["MURMURE_ECHO_SEUIL"].flatMap(Float.init) ?? 0.4
        let correlation = globalCurve[globalLag]
        if env["MURMURE_DEBUG"] != nil {
            print(String(format: "[écho] corrélation %.2f à %d ms (seuil %.2f)", correlation, globalLag * 10, minimum))
        }
        guard correlation >= minimum else { return nil }
        let lags = sums.map { curve -> Int in
            let values = curve.map(\.correlation)
            guard let best = values.indices.max(by: { values[$0] < values[$1] }), values[best] >= minimum,
                  curve[best].n >= 200 else { return globalLag }
            return best
        }

        // 2. Écho attendu à chaque tranche : le son de l'ordinateur au retard trouvé, prolongé par la réverbération.
        var tail = [Float](repeating: 0, count: count)
        var previous: Float = 0
        for i in 0..<count {
            let lag = lags[i / block]
            let reference = i >= lag ? systemLevels[i - lag] : 0
            previous = max(reference, previous * decay)
            tail[i] = previous
        }
        // Niveau de l'écho : médiane du rapport micro / écho attendu là où l'ordinateur parle. L'utilisateur qui
        // parle en même temps ne déplace que le haut de la distribution.
        var ratios: [Float] = []
        for i in 0..<count where tail[i] > systemThreshold { ratios.append(micLevels[i] / tail[i]) }
        guard ratios.count > 200 else { return nil }
        ratios.sort()
        let coupling = ratios[ratios.count / 2]
        if env["MURMURE_DEBUG"] != nil {
            let q = [0.1, 0.25, 0.75, 0.9, 0.95, 0.98].map { String(format: "%.2f", ratios[Int(Double(ratios.count - 1) * $0)] / coupling) }
            print("[écho] rapport micro / écho attendu (centiles 10 25 75 90 95 98) : " + q.joined(separator: " "))
        }

        // 3. Micro retiré là où il ne dépasse pas nettement l'écho attendu (marge en amplitude : 2,5, soit 8 dB),
        // y compris entre deux syllabes de la visio, où l'ordinateur passe sous son seuil mais où la pièce résonne
        // encore. La voix de l'utilisateur : au-dessus de l'écho attendu ET au-dessus du seuil de parole du micro ;
        // élargie de 30 ms avant et 80 ms après, pour ne couper ni attaque ni fin de mot.
        let margin = env["MURMURE_ECHO_MARGE"].flatMap(Float.init) ?? 2.5
        let micThreshold = SpeechLevels.threshold(Array(micLevels[0..<count]))
        var removable = [Bool](repeating: false, count: count)
        var voice = [Bool](repeating: false, count: count)
        var systemFrames = 0, removedFrames = 0
        for i in 0..<count {
            removable[i] = micLevels[i] < margin * coupling * tail[i]
            voice[i] = !removable[i] && micLevels[i] > micThreshold
            if tail[i] > systemThreshold {
                systemFrames += 1
                if removable[i] { removedFrames += 1 }
            }
        }
        // Une tranche isolée au-dessus de la marge n'est pas une voix : l'écho seul y monte une fois sur cinquante
        // (le rapport micro / écho attendu varie d'une tranche à l'autre). Il faut 30 ms d'affilée.
        let run = env["MURMURE_ECHO_DUREE"].flatMap(Int.init) ?? 3
        var start = 0
        while start < count {
            guard voice[start] else { start += 1; continue }
            var end = start
            while end < count, voice[end] { end += 1 }
            // Ces tranches-là sont retirées comme l'écho qui les entoure.
            if end - start < run { for i in start..<end { voice[i] = false; removable[i] = true } }
            start = end
        }
        var weights = [Float](repeating: 1, count: count)
        var lastVoice = -1_000
        for i in 0..<count {
            if voice[i] { lastVoice = i }
            if removable[i], i - lastVoice > 8 { weights[i] = 0 }
        }
        var nextVoice = Int.max / 2
        for i in stride(from: count - 1, through: 0, by: -1) {
            if voice[i] { nextVoice = i }
            if weights[i] == 0, nextVoice - i <= 3 { weights[i] = 1 }
        }
        let analysis = Analysis(weights: weights, delayMs: globalLag * 10, correlation: correlation, coupling: coupling,
                                removed: Float(removedFrames) / Float(max(systemFrames, 1)))
        if env["MURMURE_DEBUG"] != nil {
            print(String(format: "[écho] niveau %.2f, micro retiré sur %.0f %% des passages de l'ordinateur",
                         coupling, 100 * analysis.removed))
        }
        return analysis
    }
}

extension EchoGate.Analysis {
    /// Poids du micro pour l'échantillon `index`, fondu d'une tranche à l'autre (pas de clic). Au-delà de la fin du
    /// son de l'ordinateur, le micro est gardé.
    func weight(at index: Int) -> Float {
        let position = Float(index) / Float(EchoGate.frame) - 0.5
        let first = Int(position.rounded(.down))
        guard first >= 0 else { return weights.first ?? 1 }
        guard first + 1 < weights.count else { return first < weights.count ? weights[first] : 1 }
        let a = weights[first], b = weights[first + 1]
        return a == b ? a : a + (b - a) * (position - Float(first))
    }
}
