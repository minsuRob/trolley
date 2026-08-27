#!/usr/bin/env swift
//
// 창 하나만 찍는다. 다른 창이 위에 겹쳐 있어도, 뒤에 가려져 있어도 상관없다 --
// `screencapture -l` 은 그 창의 버퍼를 직접 가져오기 때문이다. 영역(-R)으로 찍던 방식은
// 실측으로 두 번 실패했다: 앞으로 꺼내는 데 실패해 다른 앱이 찍혔고, macOS 동의 창이 그
// 위를 덮은 채로 찍혔다.
//
//   Scripts/window-shot.swift 위키 /tmp/wiki.png
//
// 첫 인자는 창 제목에 들어 있는 말, 둘째는 저장 경로. 여럿이 걸리면 목록의 앞쪽(대개 가장
// 최근에 만들어진 창)을 찍는다.
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(
        "사용법: window-shot.swift <창 제목 일부> <저장 경로>\n".data(using: .utf8)!
    )
    exit(2)
}
let needle = arguments[1]
let output = arguments[2]

let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let match = windows.first { window in
    guard let name = window[kCGWindowName as String] as? String else { return false }
    return name.contains(needle)
}
guard let match, let number = match[kCGWindowNumber as String] as? Int else {
    let titles = windows.compactMap { $0[kCGWindowName as String] as? String }.filter { !$0.isEmpty }
    let message = "\"\(needle)\" 이 들어간 창이 없다. "
        + "지금 열려 있는 창: \(titles.prefix(20).joined(separator: ", "))\n"
    FileHandle.standardError.write(message.data(using: .utf8)!)
    exit(1)
}

let capture = Process()
capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
// -x 소리 없이, -o 그림자 없이, -l 그 창만.
capture.arguments = ["-x", "-o", "-l", String(number), output]
try capture.run()
capture.waitUntilExit()
guard capture.terminationStatus == 0 else {
    // 화면 기록 허락이 없으면 여기서 걸린다. 그 허락은 이 스크립트를 부른 터미널의 것이다.
    FileHandle.standardError.write("screencapture 실패 (화면 기록 허락을 확인할 것)\n".data(using: .utf8)!)
    exit(capture.terminationStatus)
}
print(output)
