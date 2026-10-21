import Foundation

/// Michael Paul Johnson's Sapphire II stream cipher (public domain), which
/// SWORD uses to lock modules sold by publishers. A locked module's text is
/// enciphered a buffer at a time, each from the state the key sets up.
struct SapphireCipher {
    private var cards = [UInt8](repeating: 0, count: 256)
    private var rotor: UInt8 = 0
    private var ratchet: UInt8 = 0
    private var avalanche: UInt8 = 0
    private var lastPlain: UInt8 = 0
    private var lastCipher: UInt8 = 0

    /// SWORD hands the cipher the key after `personalizedKey`, and its key
    /// length is a byte: a longer key wraps.
    init(key: [UInt8]) {
        let keySize = UInt8(truncatingIfNeeded: key.count)
        guard keySize > 0 else {
            // An empty key gives the cipher's hashing state.
            rotor = 1; ratchet = 3; avalanche = 5; lastPlain = 7; lastCipher = 11
            for index in 0..<256 { cards[index] = UInt8(255 - index) }
            return
        }
        for index in 0..<256 { cards[index] = UInt8(index) }
        var keyPosition = 0
        var runningSum: UInt8 = 0
        for index in stride(from: 255, through: 0, by: -1) {
            let toSwap = Int(keyRandom(limit: index, key: key, keySize: keySize, runningSum: &runningSum, keyPosition: &keyPosition))
            cards.swapAt(index, toSwap)
        }
        rotor = cards[1]
        ratchet = cards[3]
        avalanche = cards[5]
        lastPlain = cards[7]
        lastCipher = cards[Int(runningSum)]
    }

    /// A value from 0 through `limit`, drawn from the key.
    private func keyRandom(limit: Int, key: [UInt8], keySize: UInt8, runningSum: inout UInt8, keyPosition: inout Int) -> UInt8 {
        guard limit > 0 else { return 0 }
        var mask = 1
        while mask < limit { mask = (mask << 1) + 1 }
        var retries = 0
        var value: Int
        repeat {
            runningSum = cards[Int(runningSum)] &+ key[keyPosition]
            keyPosition += 1
            if keyPosition >= Int(keySize) {
                keyPosition = 0
                runningSum = runningSum &+ keySize
            }
            value = mask & Int(runningSum)
            retries += 1
            if retries > 11 { value %= limit }
        } while value > limit
        return UInt8(value)
    }

    mutating func decrypt(_ byte: UInt8) -> UInt8 {
        let plain = byte ^ step()
        lastPlain = plain
        lastCipher = byte
        return plain
    }

    mutating func encrypt(_ byte: UInt8) -> UInt8 {
        let cipher = byte ^ step()
        lastCipher = cipher
        lastPlain = byte
        return cipher
    }

    /// Shuffles the cards and gives the byte that masks the next one.
    private mutating func step() -> UInt8 {
        ratchet = ratchet &+ cards[Int(rotor)]
        rotor = rotor &+ 1
        let swap = cards[Int(lastCipher)]
        cards[Int(lastCipher)] = cards[Int(ratchet)]
        cards[Int(ratchet)] = cards[Int(lastPlain)]
        cards[Int(lastPlain)] = cards[Int(rotor)]
        cards[Int(rotor)] = swap
        avalanche = avalanche &+ cards[Int(swap)]
        let first = cards[Int(cards[Int(ratchet)] &+ cards[Int(rotor)])]
        let second = cards[Int(cards[Int(cards[Int(lastPlain)] &+ cards[Int(lastCipher)] &+ cards[Int(avalanche)])])]
        return first ^ second
    }

    /// Deciphers a whole buffer, as SWORD does each block or verse.
    func decrypt(_ data: Data) -> Data {
        var cipher = self
        return Data(data.map { cipher.decrypt($0) })
    }

    func encrypt(_ data: Data) -> Data {
        var cipher = self
        return Data(data.map { cipher.encrypt($0) })
    }

    // MARK: - Unlock keys

    private static let alphabet: [Character] = Array("bceafgijklhmpqBrHostTuwxyAdCDzEFIJKGLNO7PQMRSUVWXY9012Z364n8v5")
    private static let alphabetIndex: [Character: Int] = Dictionary(
        uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) }
    )

    /// SWORD sells some keys in a checksummed form, five segments joined by
    /// hyphens, which it decodes before use; any other key is used as typed.
    static func personalizedKey(_ key: String) -> [UInt8] {
        var segments = [[Character]](repeating: [], count: 5)
        var segment = 0
        for character in key where segment < 5 {
            if character == "-" {
                segment += 1
            } else if segment < 5 {
                segments[segment].append(character)
            }
        }
        let checksum = segments[4]
        var computed = Array(segments[4].prefix(max(4, segments[4].count)))
        while computed.count < 4 { computed.append("\0") }
        var decoded = ""
        for index in 0..<4 {
            var sum = 0
            let count = min(segments[index].count, segments[0].count)
            for position in 0..<count {
                let value = alphabetIndex[segments[index][position]] ?? 0
                let mask = alphabetIndex[segments[0][position % segments[0].count]] ?? 0
                if index > 0 {
                    segments[index][position] = alphabet[(value + mask) % 62]
                }
                sum += value
            }
            computed[index] = alphabet[sum % 62]
            // The first segment only scrambles the others; a hyphen goes
            // in only once something precedes it.
            if index > 0 {
                if !decoded.isEmpty { decoded += "-" }
                decoded += String(segments[index])
            }
        }
        guard checksum == computed else { return Array(key.utf8) }
        return Array(decoded.utf8)
    }
}
