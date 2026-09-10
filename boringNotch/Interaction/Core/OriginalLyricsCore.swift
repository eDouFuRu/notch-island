import Foundation

enum OriginalLyricLanguage {
    static func containsHan(_ text: String) -> Bool {
        text.range(of: "[\\p{Han}]", options: .regularExpression) != nil
    }

    static func preservesNonChineseScript(_ text: String) -> Bool {
        // ICU script-extension matching also assigns Chinese punctuation such
        // as U+3002 to kana/Hangul. Only actual letters count as language cues.
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x3041...0x3096).contains(value) || (0x309D...0x309F).contains(value)
                || (0x30A1...0x30FA).contains(value) || (0x30FC...0x30FF).contains(value)
                || (0x31F0...0x31FF).contains(value) || (0xFF66...0xFF9F).contains(value)
                || (0x1B000...0x1B16F).contains(value) || (0xAC00...0xD7A3).contains(value)
                || (0x1100...0x11FF).contains(value) || (0x3131...0x318E).contains(value)
                || (0xA960...0xA97F).contains(value) || (0xD7B0...0xD7FF).contains(value)
        }
    }

    /// A conservative signal for choosing another provider, never a translator.
    /// Requiring Chinese metadata and a long, almost entirely syllabic document
    /// leaves ordinary English and other original languages untouched.
    static func isRomanizedMandarin(_ document: LyricsDocument, track: LyricsTrack) -> Bool {
        guard containsHan(track.title), containsHan(track.artist), !document.instrumental else { return false }
        let lines = document.cues.map(\.text).filter { !$0.isEmpty }
        let text = lines.joined(separator: " ")
        guard lines.count >= 4, !containsHan(text), !preservesNonChineseScript(text) else { return false }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let words = folded.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        guard words.count >= 24 else { return false }
        return Double(words.filter { syllables.contains($0) }.count) / Double(words.count) >= 0.92
    }

    /// Only discard a phonetic companion when it transliterates to the same
    /// Chinese sentence. English translations are not guessed from their words.
    static func withoutPhoneticDuplicates(_ lines: [String]) -> [String] {
        func letters(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .unicodeScalars.filter { CharacterSet.letters.contains($0) }.map(String.init).joined()
        }
        let phonetic = Set(lines.filter { containsHan($0) && !preservesNonChineseScript($0) }
            .compactMap { $0.applyingTransform(.toLatin, reverse: false) }.map(letters))
        return lines.filter { containsHan($0) || !phonetic.contains(letters($0)) }
    }

    private static let syllables = Set("""
    a ai an ang ao ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu
    ca cai can cang cao ce cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo
    da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo e ei en eng er
    fa fan fang fei fen feng fo fou fu ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo
    ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo
    ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo
    la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lun luo lv lve lue
    ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nuo nv nve nue
    o ou pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu
    qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun ran rang rao re ren reng ri rong rou ru ruan rui run ruo
    sa sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo
    ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tuan tui tun tuo
    wa wai wan wang wei wen weng wo wu xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun
    ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo
    """.split(whereSeparator: \.isWhitespace).map(String.init))
}

extension LyricsTrack {
    static func normalizedAlbum(_ text: String) -> String {
        normalized(text).replacingOccurrences(of: "(?<=[\\p{Han}]) +| +(?=[\\p{Han}])", with: "", options: .regularExpression)
    }
    /// A catalog credits every performer ("林俊杰 / MC HotDog 热狗") while
    /// MediaRemote usually publishes only the lead ("林俊杰"), so equality
    /// rejects every collaboration. Agreeing on the lead performer is enough
    /// here because title, album and duration are matched exactly elsewhere;
    /// artist alone never decides which recording's clock is borrowed.
    static func creditTokens(_ value: String) -> [String] {
        normalized(value)
            // Featured credits are separators, not part of a performer's name.
            .replacingOccurrences(of: "(?i)(?<![a-z])(?:feat|ft|featuring|with|vs)\\.?(?![a-z])",
                                  with: "/", options: .regularExpression)
            // Round brackets carry credits ("(Feat. MC Hotdog)"); square ones
            // carry release tags ("[PT80]") and must keep the name unsplit.
            .components(separatedBy: CharacterSet(charactersIn: "/&,;()×、，＆；（）"))
            .map { token in
                // "David Tao 陶喆" and "陶喆" are the same performer.
                token.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "^[a-z][a-z .]*[ ]+(?=[\\p{Han}])", with: "", options: .regularExpression)
            }
            .filter { !$0.isEmpty }
    }

    static func artistMatches(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalized(lhs), b = normalized(rhs)
        if !a.isEmpty && a == b { return true }
        let left = creditTokens(lhs), right = creditTokens(rhs)
        guard let leadLeft = left.first, let leadRight = right.first else { return false }
        // Either side may be the abbreviated credit, so accept when one side's
        // lead performer appears anywhere in the other's credit list.
        return right.contains(leadLeft) || left.contains(leadRight)
    }
}

struct NetEaseSearchResponse: Decodable {
    struct SearchResult: Decodable { let songs: [NetEaseSongRecord]? }
    let code: Int
    let result: SearchResult?
}

struct NetEaseSongRecord: Decodable, Sendable {
    struct Artist: Decodable, Sendable { let name: String }
    struct Album: Decodable, Sendable { let name: String }
    let id: Int
    let name: String
    let artists: [Artist]
    let album: Album
    /// The public search endpoint reports milliseconds.
    let duration: Double

    func matches(_ track: LyricsTrack) -> Bool {
        guard id > 0, LyricsTrack.normalized(name) == LyricsTrack.normalized(track.title),
              LyricsTrack.artistMatches(artists.map(\.name).joined(separator: " / "), track.artist),
              duration.isFinite, duration > 0, track.duration > 0,
              abs(duration / 1_000 - track.duration) <= (track.album.isEmpty ? 0.5 : 1.0) else { return false }
        return track.album.isEmpty || (!album.name.isEmpty && LyricsTrack.normalizedAlbum(album.name) == LyricsTrack.normalizedAlbum(track.album))
    }

    static func bestMatch(_ records: [Self], track: LyricsTrack, searchCount: Int = 30) -> Self? {
        guard !(track.album.isEmpty && records.count >= searchCount) else { return nil }
        let candidates = records.filter { $0.matches(track) }
        guard let best = candidates.min(by: { abs($0.duration / 1_000 - track.duration) < abs($1.duration / 1_000 - track.duration) }) else { return nil }
        let distance = abs(best.duration / 1_000 - track.duration)
        // A near tie between distinct song IDs can mean different releases. Do
        // not borrow an uncertain version's timing even if the title is exact.
        guard candidates.filter({ abs($0.duration / 1_000 - track.duration) <= distance + 0.05 }).allSatisfy({ $0.id == best.id }) else { return nil }
        return best
    }
}

struct NetEaseLyricResponse: Decodable {
    struct Original: Decodable { let lyric: String? }
    let code: Int
    let lrc: Original?
    let nolyric: Bool?
    var document: LyricsDocument? {
        guard code == 200 else { return nil }
        // Intentionally never decode romalrc/rlyric/tlyric: they are phonetics
        // or translations, not what the singer sings.
        let cues = LRCParser.parse(lrc?.lyric ?? "")
        return cues.isEmpty ? (nolyric == true ? LyricsDocument(cues: [], instrumental: true) : nil) : LyricsDocument(cues: cues)
    }
}
