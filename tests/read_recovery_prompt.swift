//
//  read_recovery_prompt.swift
//  AI Arena · 只读重建负载的定向检查
//
//  目标：G1/G3。原生只有在**确实持久化过发送意图**（submit 已发出，
//  结果可能已到页面：inflight / uncertain / submitted）时，才可以把原文
//  作为 `verifiedReadPrompt` 随只读 `read` 发出。`prepared` 表示提交命令还
//  没发出，不能授权任何“已送达”判断；缺失意图也没有证据。
//
//  同时检查 SitePane 对 `verifiedReadPrompt` 的形状校验：只接受非空、有界、
//  无 NUL 的字符串，且该值永远不会进入输入框或点击路径。
//
//  由 tests/read_recovery_prompt.py 编译并运行。
//

import Foundation

@main
struct ReadRecoveryPromptCheck {
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

        let original = "互评：请说明你在什么条件下改变立场。" + String(repeating: "长", count: 80)
        check(
            "submitted intent carries the exact prompt",
            ArenaEngine.readRecoveryPrompt(phase: .submitted, prompt: original) == original
        )
        check(
            "inflight intent carries the exact prompt",
            ArenaEngine.readRecoveryPrompt(phase: .inflight, prompt: original) == original
        )
        check(
            "uncertain intent carries the exact prompt",
            ArenaEngine.readRecoveryPrompt(phase: .uncertain, prompt: original) == original
        )
        check(
            "prepared intent never authorises a rebuild",
            ArenaEngine.readRecoveryPrompt(phase: .prepared, prompt: original) == nil
        )
        check(
            "missing intent never authorises a rebuild",
            ArenaEngine.readRecoveryPrompt(phase: nil, prompt: original) == nil
        )
        check(
            "missing prompt is refused",
            ArenaEngine.readRecoveryPrompt(phase: .submitted, prompt: nil) == nil
        )
        check(
            "blank prompt is refused",
            ArenaEngine.readRecoveryPrompt(phase: .submitted, prompt: " \n\t ") == nil
        )
        check(
            "NUL prompt is refused",
            ArenaEngine.readRecoveryPrompt(phase: .submitted, prompt: "a\u{0}b") == nil
        )
        check(
            "over-long prompt is refused",
            ArenaEngine.readRecoveryPrompt(phase: .submitted, prompt: String(repeating: "x", count: 100_001)) == nil
        )

        check(
            "SitePane accepts a plain string",
            (try? SitePane.validatedReadRecoveryPrompt(original)) == original
        )
        check(
            "SitePane ignores an absent value",
            (try? SitePane.validatedReadRecoveryPrompt(nil)) == nil
        )
        check(
            "SitePane rejects a non-string",
            (try? SitePane.validatedReadRecoveryPrompt(42)) == nil
        )
        check(
            "SitePane rejects an empty string",
            (try? SitePane.validatedReadRecoveryPrompt(" \n ")) == nil
        )
        check(
            "SitePane rejects NUL",
            (try? SitePane.validatedReadRecoveryPrompt("a\u{0}b")) == nil
        )

        if failures > 0 {
            exit(1)
        }
    }
}
