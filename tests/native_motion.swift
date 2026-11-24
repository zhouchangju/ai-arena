//
//  native_motion.swift
//  AI Arena · 统一动效的减少动态效果检查
//
//  目标：G4，R06/R07。只验证 ArenaMotion 的公开契约，不启动应用、不创建
//  窗口。由 tests/native_motion.py 编译运行。
//

import Foundation
import SwiftUI

@main
struct NativeMotionCheck {
    static func main() {
        var failures = 0

        func check(_ name: String, _ value: Bool) {
            if value {
                print("ok   \(name)")
            } else {
                failures += 1
                print("FAIL \(name)")
            }
        }

        check("a press uses quick motion when motion is allowed",
              ArenaMotion.quick(false) != nil)
        check("a press becomes an immediate state under Reduce Motion",
              ArenaMotion.quick(true) == nil)
        check("a state change animates when motion is allowed",
              ArenaMotion.change(false) != nil)
        check("a state change becomes immediate under Reduce Motion",
              ArenaMotion.change(true) == nil)
        check("press feedback is shorter than a state change",
              ArenaMotion.quickDuration < ArenaMotion.changeDuration)
        check("both durations stay short enough to feel direct",
              ArenaMotion.changeDuration <= 0.25 && ArenaMotion.quickDuration > 0)

        if failures == 0 {
            print("native motion: all checks passed")
            exit(0)
        }
        print("native motion: \(failures) check(s) failed")
        exit(1)
    }
}
