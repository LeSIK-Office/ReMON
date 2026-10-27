import Foundation
import ReMONCore

// 방 안 짐 장부(RoomClutter): 메인 작업 공간·기본/보호 브랜치·체크아웃된 브랜치는 세지 않고, 무게 → 단계가 맞는지.
func roomClutterCheck() {
    func worktree(_ path: String, main: Bool, cleanable: Bool, bytes: UInt64) -> WorktreeLeftover {
        WorktreeLeftover(repo: "/r", project: "P", path: path, branch: "b", head: "abc", merged: cleanable, bytes: bytes,
                         verdict: cleanable ? .cleanable(.removeWorktree) : .keep("작업 중"), isMain: main)
    }
    func branch(_ name: String, isDefault: Bool = false, isProtected: Bool = false, checkedOut: String? = nil, cleanable: Bool = false) -> BranchLeftover {
        BranchLeftover(repo: "/r", project: "P", name: name, merged: cleanable, checkedOutAt: checkedOut, isDefault: isDefault,
                       verdict: cleanable ? .cleanable(.deleteMergedBranch) : .keep("미병합"), head: "def", isProtected: isProtected)
    }
    let project = ProjectLeftovers(project: "P", repos: ["/r"],
                                   worktrees: [worktree("/r", main: true, cleanable: false, bytes: 10), worktree("/w1", main: false, cleanable: true, bytes: 100), worktree("/w2", main: false, cleanable: false, bytes: 50)],
                                   branches: [branch("main", isDefault: true), branch("develop", isProtected: true), branch("wt/b", checkedOut: "/w2"), branch("feat/a", cleanable: true), branch("feat/b")])
    let clutter = RoomClutter(project, papers: 2)
    check(clutter.worktrees == 2 && clutter.branches == 2 && clutter.cleanableWorktrees == 1 && clutter.cleanableBranches == 1 && clutter.bytes == 150 && clutter.papers == 2,
          "짐 장부: 워크트리 2(메인 제외) · 브랜치 2(기본·보호·체크아웃 제외) · 치울 수 있음 1/1 · 150B · 서류 2")
    check(clutter.load == 2 * 3 + 2 + 2 && clutter.level == 3, "무게 \(clutter.load) → 3단계(바닥에 상자들)")
    check(RoomClutter().level == 0 && RoomClutter(branches: 2).level == 1 && RoomClutter(worktrees: 2).level == 2 && RoomClutter(worktrees: 5, branches: 3).level == 4 && RoomClutter(worktrees: 20).level == 5,
          "단계: 0 · 브랜치 2 → 1 · 워크트리 2 → 2 · 워크트리 5+브랜치 3 → 4 · 워크트리 20 → 5")
}
