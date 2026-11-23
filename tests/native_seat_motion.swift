//
//  native_seat_motion.swift
//  AI Arena · 席位微交互触发边界检查
//
//  目标：G1/G2/G4，R02/R03/R06/R07。只验证纯策略，不启动应用、不创建
//  窗口、不加载网页、不访问真实账号。
//
//  由 tests/native_seat_motion.py 编译运行。
//

import Foundation

@main
struct NativeSeatMotionCheck {
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

        check("a verified user turn permits the receipt animation",
              ArenaSeatMotionPolicy.shouldAnimateVerifiedReceipt(
                  turnVerified: true, paused: false, readOnly: false, takenOver: false
              ))
        check("a click without a verified user turn never animates",
              !ArenaSeatMotionPolicy.shouldAnimateVerifiedReceipt(
                  turnVerified: false, paused: false, readOnly: false, takenOver: false
              ))
        check("a paused seat never animates a receipt",
              !ArenaSeatMotionPolicy.shouldAnimateVerifiedReceipt(
                  turnVerified: true, paused: true, readOnly: false, takenOver: false
              ))
        check("a taken-over seat never animates a receipt",
              !ArenaSeatMotionPolicy.shouldAnimateVerifiedReceipt(
                  turnVerified: true, paused: false, readOnly: false, takenOver: true
              ))
        check("restored or history reconciliation never animates a receipt",
              !ArenaSeatMotionPolicy.shouldAnimateVerifiedReceipt(
                  turnVerified: true, paused: false, readOnly: true, takenOver: false
              ))
        check("a durably saved answer permits the check",
              ArenaSeatMotionPolicy.shouldAnimateSavedAnswer(saved: true, readOnly: false))
        check("an unsaved answer never shows the check",
              !ArenaSeatMotionPolicy.shouldAnimateSavedAnswer(saved: false, readOnly: false))
        check("a history render never animates the check",
              !ArenaSeatMotionPolicy.shouldAnimateSavedAnswer(saved: true, readOnly: true))

        if failures == 0 {
            print("native seat motion: all checks passed")
            exit(0)
        }
        print("native seat motion: \(failures) check(s) failed")
        exit(1)
    }
}
