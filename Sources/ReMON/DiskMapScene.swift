import Combine
import ReMONCore
import SwiftUI

// 디스크 지도 ↔ 사무실 재고 조사 연출 연결(10-25 대표 안): 지도 페이지를 열면 재고팀이 내려와 묶음을 내리고, 꼬리표 하나로 거르면 그 묶음을
// 탁자에 펼치고, 체크하면 '폐기' 스티커, 조치가 끝나면 보관은 선반으로·휴지통행은 금고 수레·영구 삭제는 압축기, 다시 재면 "실측 +X"를 외친다.
// 사무실 창이 닫혀 있으면 연출 없이 지도만 동작한다(scene이 nil).

extension AppModel {
    func connectDiskMapScene() {
        diskMap.onActionsStarted = { [weak self] _, _ in
            guard let self else { return }
            // 실측 기준점: 조치 직전의 디스크 여유. 휴지통행은 공간이 돌아오지 않으니 실측 0이 정상이다.
            if inventoryFreeBefore == nil { inventoryFreeBefore = system.disk.available }
        }
        diskMap.onActionsPerformed = { [weak self] action, nodes in
            guard let self else { return }
            let paths = nodes.map(\.path)
            switch action {
            case .trash: scene?.inventoryExecute(trash: paths, delete: [], prune: [])
            case .deletePermanently: scene?.inventoryExecute(trash: [], delete: paths, prune: [])
            case .prune: scene?.inventoryExecute(trash: [], delete: [], prune: Array(Set(nodes.flatMap { $0.tags }).intersection([.docker, .homebrew, .gitByproduct])))
            case .reveal, .none: return
            }
            // 실제로 끝난 뒤 다시 잰다: 디스크 수치 갱신(2초 주기) → 지도 다시 조사 → 구성(선반) 갱신 → 실측 외침.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                monitor.refreshNow()
                diskMap.rescan()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard let self else { return }
                    let before = inventoryFreeBefore ?? system.disk.available
                    let freed = system.disk.available > before ? system.disk.available - before : 0
                    inventoryFreeBefore = nil
                    scene?.setDiskStock(diskStockGroups)
                    scene?.inventoryFinish(measuredFreed: freed)
                    append(.cleanup, "디스크 정비 실측 · 여유 \(Fmt.gb(before)) → \(Fmt.gb(system.disk.available))" + (freed > 0 ? " (+\(Fmt.gb(freed)))" : " (휴지통행은 비울 때 돌아옵니다)"))
                }
            }
        }
        // 지도 페이지 열림/닫힘 → 재고팀 투입/철수. 구성·필터·체크는 그때그때 연출로.
        diskMapObservers = [
            $page.removeDuplicates().sink { [weak self] page in
                guard let self else { return }
                if page == .diskMap { scene?.inventoryBegin(groups: diskStockGroups) } else if inventoryFreeBefore == nil { scene?.inventoryCancel() }
            },
            $diskMapComposition.removeDuplicates().sink { [weak self] _ in
                guard let self else { return }
                scene?.setDiskStock(diskStockGroups)
            },
            diskMap.$filter.combineLatest(diskMap.$displayed).receive(on: DispatchQueue.main).sink { [weak self] filter, displayed in
                guard let self, page == .diskMap, filter.count == 1, let tag = filter.first else { return }
                let checked = self.diskMap.checked
                let items = displayed.map(\.node).sorted { $0.bytes > $1.bytes }.prefix(60).map {
                    DiskStockItem(path: $0.path, name: $0.name, bytes: $0.bytes, tag: $0.tags.contains(tag) ? tag : ($0.tags.first ?? tag), marked: checked.contains($0.path))
                }
                scene?.inventoryOpen(group: tag, items: Array(items))
            },
            diskMap.$checked.removeDuplicates().sink { [weak self] checked in
                guard let self, page == .diskMap else { return }
                for path in checked.subtracting(lastInventoryChecked) { scene?.inventoryMark(path: path, marked: true) }
                for path in lastInventoryChecked.subtracting(checked) { scene?.inventoryMark(path: path, marked: false) }
                lastInventoryChecked = checked
            },
        ]
    }

    /// 선반 묶음: 지도 조사 결과(없으면 지금 아는 구성) → 꼬리표별 바이트·치울 수 있는 양.
    var diskStockGroups: [DiskStockGroup] {
        diskComposition.map { DiskStockGroup(tag: $0.tag, bytes: $0.total, reclaimable: $0.reclaimable) }
    }
}
