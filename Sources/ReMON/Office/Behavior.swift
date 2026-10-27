import Foundation

/// 같은 사건도 매번 다르게: 변형 번호와 대사를 고르되, 직전에 쓴 것은 피한다.
final class Variety {
    nonisolated(unsafe) static let shared = Variety()
    private var last: [String: Int] = [:]
    private var generator = Generator()

    /// 평소에는 시스템 난수. 장면 시험(--scene-check)은 씨앗을 줘 매번 같은 연출을 재현한다(SplitMix64).
    struct Generator: RandomNumberGenerator {
        var state: UInt64?
        mutating func next() -> UInt64 {
            guard var value = state else { var system = SystemRandomNumberGenerator(); return system.next() }
            value &+= 0x9E37_79B9_7F4A_7C15
            state = value
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    /// 드문 배경 연출(재고 세기 순찰 등)의 확률은 따로 굴린다 — 매초 굴려도 다른 연출(대사 · 자리 · 파티)의 씨앗 순서가 밀리지 않게.
    /// 같은 씨앗에서 갈라져 나오므로 장면 시험에서는 이것도 결정적이다.
    private var rare = Generator()

    /// nil이면 시스템 난수로 돌아간다.
    func seed(_ value: UInt64?) {
        generator.state = value
        rare.state = value.map { $0 ^ 0x5DEE_CE66_D1CE_4E5B }
        last = [:]
    }

    /// 드문 배경 연출용 확률 · 고르기(본 순서와 따로 굴린다).
    func rareChance(_ probability: Double) -> Bool { Double.random(in: 0..<1, using: &rare) < probability }
    func rareElement<T>(_ items: [T]) -> T? { items.randomElement(using: &rare) }

    /// 목록에서 하나(비면 nil). 씨앗을 주면 결정적이다.
    func element<T>(_ items: [T]) -> T? { items.randomElement(using: &generator) }

    /// 0..<count 중 하나. 직전 값과 다른 것을 고른다(count가 1이면 0).
    func pick(_ key: String, _ count: Int) -> Int {
        guard count > 1 else { return 0 }
        var value = Int.random(in: 0..<count, using: &generator)
        if value == last[key] { value = (value + 1 + Int.random(in: 0..<(count - 1), using: &generator)) % count }
        last[key] = value
        return value
    }

    func line(_ key: String, _ options: [String]) -> String {
        guard !options.isEmpty else { return "" }
        return options[pick("line:" + key, options.count)]
    }

    func chance(_ probability: Double) -> Bool { Double.random(in: 0..<1, using: &generator) < probability }
    func seconds(_ range: ClosedRange<Double>) -> TimeInterval { Double.random(in: range, using: &generator) }
    func number(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &generator) }
    func integer(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &generator) }
}

/// 대사 모음. 상황을 바꾸지 않는 '말'만 담는다 — 판정·이유(종료하면 안 되는 이유 등)는 데이터에서 온다.
enum Lines {
    static let arrive = ["출근!", "왔습니다!", "문이 왜 이렇게 무거워", "오늘도 달려 보자", "커피부터", "지각 아님!", "저 부르셨죠?", "자리 어디예요?"]
    static let arriveSneak = ["살금살금…", "아무도 못 봤지?", "조용히 들어갑니다", "늦은 건 아니고요"]
    static let arriveDash = ["늦었다!!", "비켜요 비켜!", "급해요 급해!", "뛰어왔어요"]
    static let depart = ["퇴근~", "내일 봐요", "수고하셨습니다", "집 가자!", "먼저 가볼게요", "오늘 할당량 끝!"]
    static let departDance = ["칼퇴다!", "자유다~", "집에 간다 집에!", "오예 퇴근"]
    static let guardLines = ["나가시죠", "협조 부탁드립니다", "대표님 지시입니다", "저도 먹고살아야 해서…", "들어보니 알겠는데, 나가셔야 해요"]
    static let evicted = ["저 아직 할 일이…!", "억울합니다!", "스왑에서 봅시다", "로그는 남겨 줘요", "제 토큰…"]
    static let trainerEnter = ["운동 시간!", "메모리 다이어트!", "푸시업 20개!", "숨 쉬세요, 숨!", "앉아서 뭐 해요!", "일어나! 일어나!"]
    static let trainerDone = ["정리 끝!", "상쾌하죠?", "다음에 또 봐요", "다들 수고!"]
    static let idleFun = ["수영 최고", "이 맛에 쉰다", "아무도 날 안 부르네", "한 바퀴만 더", "책 읽는 척", "선탠 중", "물 좋다~", "해먹 흔들흔들"]
    static let hallSad = ["할 일이 없어요…", "저 아직 안 잘렸죠?", "누가 저 좀 써 주세요", "스왑으로 갈까 봐", "메모리만 축내는 중", "다음 지시 기다리는 중", "오늘 몇 시간째지", "…", "집에 가고 싶다"]
    static let orphanLines = ["누가 날 만들었더라", "부모가 없어요…", "터미널이 사라졌어", "여긴 어디 나는 누구"]
    static let auditorEnter = ["감사 나왔습니다", "다들 뭐 하고 계셨죠?", "일하는 사람 손 들어", "장부 가져와", "오늘 다 정리합니다"]
    static let auditorScold = ["이게 일이야?", "메모리 값은 누가 내나", "집에 가세요", "재교육 대상!", "그 자세 뭐야", "로그가 비었어"]
    static let auditorPraise = ["잘하고 있어", "보너스는 없어", "계속 그렇게", "모범 사원!", "이 친구 봐라", "흐뭇하군"]
    static let auditorDone = ["감사 끝. 다들 일해", "정리됐군", "다음 달에 또 봅시다", "비서, 기록해"]
    static let secretary = ["명단 가져왔습니다", "다음 분이요", "기록해 둘게요", "체크, 체크", "이분은 6일째 쉬셨어요", "대표님께 보고하겠습니다"]
    static let reeducate = ["정신 차려!", "다시 시작", "초심으로", "집중, 집중", "지시가 왔어요", "일어나서 작업장으로!"]
    static let reeducated = ["정신 차렸습니다!", "다시 열심히!", "죄송합니다!", "갑니다 갑니다"]
    static let janitorEnter = ["청소합니다~", "이거 버려도 되죠?", "먼지 봐라", "워크트리가 왜 이렇게 많아", "브랜치 정리 들어갑니다", "비켜 주세요, 쓸게요"]
    static let janitorDone = ["깨끗해졌죠?", "브랜치 정리 끝!", "다음에 또 어지르면 혼나요", "휴지통 비우는 건 대표님이"]
    static let overheat = ["뜨거!", "팬 돌려!", "CPU 녹겠다", "아 열 받아", "선풍기 어디 갔어"]
    static let shoutPrefix = ["잠깐만요!", "안 돼요!", "아직이요!", "제 말 좀!"]
    static let swapIn = ["상자 또 왔네", "창고 꽉 찼어요", "이거 누구 거예요"]
    static let swapOut = ["상자 하나 나갔다", "숨통 트인다", "창고 정리!"]
    static let diskIn = ["파일 또 들어왔네", "선반 채웁니다", "자리 남았나…"]
    static let diskOut = ["지운 파일 빼 갑니다", "선반 비었다", "디스크 숨 쉰다"]
    static let diskLow = ["창고가 꽉 찼어요!", "저장 공간 비상", "디스크 좀 비워요"]
    static let machineHot = ["엔진 과열!", "팬 최대 출력!", "열 받았다!"]
    static let praiseWorking = ["오늘 컨디션 좋다", "집중 모드", "이거 금방 끝나요", "타자 소리 들리시죠"]
    // 감사 순찰: 감사관이 일하는 직원의 모니터를 들여다볼 때(직원의 반응). 감사관 말풍선은 그 세션의 실제 값이다.
    static let peeked = ["열심히 하고 있습니다!", "보고 계셨어요?", "지금 바빠요…", "거의 다 됐어요"]
    // 재교육: 비서가 데리러 갈 때 · 강사의 훈계 · 상담 · 학생 대답 · 어르기 · 달래기 · 지시 보내기(실제 전송 순간)
    static let secretaryFetch = ["교육실로 가실게요", "잠깐 같이 가시죠", "강사님이 기다리세요", "따라오세요"]
    static let lessonLecture = ["자, 칠판 보세요", "맡은 일은 끝까지 마칩니다", "쉬는 동안에도 메모리는 나가요", "지시는 기다리지 말고 확인하세요"]
    static let lessonCounsel = ["무슨 일 있었어요?", "어디서 막혔어요?", "왜 멈췄는지 말해 볼래요?", "힘든 일 있었어요?"]
    static let studentReply = ["지시를 기다렸어요…", "다음 할 일을 몰랐어요", "깜빡 잠들었어요", "터미널이 조용해서요"]
    static let lessonCoax = ["조금만 더 하면 끝나요", "할 수 있어요", "하던 거 마무리만 해요", "다시 해 봐요"]
    static let lessonSoothe = ["괜찮아요, 다시 하면 돼요", "다들 잘할 거예요", "천천히 하나씩", "실수해도 괜찮아요"]
    static let lessonClimax = ["지시 보냅니다! 터미널 확인!", "자, 작업 재개!", "다들 자리로!"]
    // 퇴출: 강당 연설 · 실제로 정리되지 않은(드라이런·결정 뒤 상태 변화) 직원의 안도
    static let auditorSpeech = ["회사 메모리는 공짜가 아닙니다", "자리만 차지하면 곤란해요", "이름 불리면 나오세요", "오늘 정리합니다"]
    static let evictSpared = ["살았다…", "휴…", "다시 일할게요!", "감사합니다!"]
    // 스왑 내가기(메모리 최적화로 실제로 비운 양) · 비운 게 없을 때
    static let swapUnload = ["비운 만큼 빼 갑니다", "창고 숨통 트이네", "상자 나갑니다", "가볍다 가벼워"]
    static let swapEmpty = ["뺄 상자가 없네요", "창고 그대로예요", "비운 게 없네…"]
    // 깃 사건 축하(그 방 직원들이 벌떡 일어나 뛰며 외친다): 배포 · 푸시 · 커밋
    static let cheerDeploy = ["배포~~!", "배포 완료!", "프로덕션 간다!", "드디어 나간다!", "오늘 퇴근각!", "배포 성공 짠!"]
    static let cheerPush = ["푸시 완료!", "올렸다!", "원격에 박제!", "푸시 성공~", "깃 간다!"]
    static let cheerCommit = ["커밋!", "저장 완료", "한 줄 더 남김", "커밋 찍었다", "기록 완료!"]
    // 청소 특공대: 서류 더미 치우기 · 물청소
    static let paperCollect = ["서류 정리!", "이거 다 치울게요", "종이가 산더미네", "배포 서류 회수~"]
    static let mopping = ["물청소 들어갑니다", "바닥 반짝반짝", "미끄러우니 조심!", "광 좀 내 볼까"]
    // 옥상 웰니스 풀(Rooftop.swift): 겨울 온수풀에서 헤엄치는 직원 · DJ 파티(춤추는 직원 · 디제이 세팅 · 띄우기 · 마침 인사)
    static let hotSpring = ["따뜻해~", "온천이다", "몸이 사르르 녹는다", "겨울엔 역시 온수풀", "김 봐, 김!", "나가기 싫다…", "여기가 천국이네"]
    static let partyCheer = ["파티다!", "DJ 최고!", "한 곡 더!", "오늘 밤은 쉰다~", "베이스 좋다!", "손 머리 위로!", "이 맛에 쉰다", "춤추는 중입니다"]
    static let djSetup = ["장비 세팅 중…", "마이크 체크, 원 투", "턴테이블 연결 완료", "오늘 밤 달립니다"]
    static let djHype = ["옥상 파티 시작합니다!", "손 머리 위로!", "볼륨 올려!", "다음 곡 갑니다!", "쉬는 분들 다 모여요!"]
    static let djBye = ["오늘 파티 끝!", "다들 수고했어요~", "다음 저녁에 또 봐요", "장비 접습니다"]
}
