//
//  pre_click_send_repair.swift
//  AI Arena · 发送前一次性自修复的定向检查
//
//  目标：G1/G3。真实 Gemini 表决回合曾连续约 90 秒都停在
//  `send-pending`（发送键 missing/hidden，全程未点击），而重新打开同一
//  已确认会话后立刻发送成功。原生只在发送前的重试分支里做一次受控自修复：
//
//    * 只有 Gemini；
//    * 只有驱动明确回报 `phase=pre-click` 且 `clickAttempted=false`；
//    * 只有 missing/hidden 的发送键状态；
//    * 同一任务只做一次，且已过 20 秒或连续 3 次拒绝；
//    * 重载前必须确认输入框为空或正好是本轮完整提示，且没有活跃 Stop。
//
//  同时检查只读 probe 载荷 `expectedPrompt` 的形状校验：它只用于比较，
//  不会被写入输入框，也不授权点击。由 tests/pre_click_send_repair.py 编译运行。
//

import Foundation

@main
struct PreClickSendRepairCheck {
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

        func candidate(
            provider: String = "gemini",
            phase: ArenaDeliveryIntent.Phase? = .prepared,
            reportedPhase: String? = "pre-click",
            clickAttempted: Bool? = false,
            reason: String? = "hidden",
            alreadyReloaded: Bool = false,
            elapsed: TimeInterval = 20,
            refusals: Int = 1
        ) -> Bool {
            ArenaModel.isPreClickReloadCandidate(
                provider: provider,
                phase: phase,
                reportedPhase: reportedPhase,
                clickAttempted: clickAttempted,
                reason: reason,
                alreadyReloaded: alreadyReloaded,
                elapsed: elapsed,
                refusals: refusals
            )
        }

        // --- Positive: the two agreed triggers -----------------------------
        check(
            "elapsed trigger: 20s after one hidden refusal",
            candidate(elapsed: 20, refusals: 1)
        )
        check(
            "elapsed trigger: 25s after two missing refusals",
            candidate(reason: "missing", elapsed: 25, refusals: 2)
        )
        check(
            "refusal trigger: 3 successive refusals well before 20s",
            candidate(elapsed: 3, refusals: 3)
        )

        // --- Negative: still inside the window ------------------------------
        check(
            "19s and two refusals waits",
            !candidate(elapsed: 19, refusals: 2)
        )
        check(
            "14s and two refusals waits",
            !candidate(elapsed: 14, refusals: 2)
        )

        // --- Negative: only Gemini, only this exact pre-click answer --------
        check("other providers never repair", !candidate(provider: "chatgpt"))
        check("deepseek never repairs", !candidate(provider: "deepseek"))
        check("submitted phase never repairs", !candidate(phase: .submitted))
        check("inflight phase never repairs", !candidate(phase: .inflight))
        check("uncertain phase never repairs", !candidate(phase: .uncertain))
        check("missing intent never repairs", !candidate(phase: nil))
        check(
            "a reply without phase=pre-click never repairs",
            !candidate(reportedPhase: nil)
        )
        check(
            "a post-click phase never repairs",
            !candidate(reportedPhase: "after-click")
        )
        check(
            "a reply without clickAttempted=false never repairs",
            !candidate(clickAttempted: nil)
        )
        check(
            "an attempted click never repairs",
            !candidate(clickAttempted: true)
        )
        check(
            "a disabled send control never repairs",
            !candidate(reason: "disabled")
        )
        check(
            "a composer-changed refusal never repairs",
            !candidate(reason: "composer-changed")
        )
        check(
            "a not-clickable refusal never repairs",
            !candidate(reason: "not-clickable")
        )
        check(
            "a refusal without a reason never repairs",
            !candidate(reason: nil)
        )
        check(
            "the one repair is spent once per task",
            !candidate(alreadyReloaded: true, elapsed: 60, refusals: 6)
        )

        // --- Composer gate: empty or exactly our prompt, no live Stop ------
        check(
            "an empty composer may be reloaded",
            ArenaModel.isPreClickComposerSafe(
                draftEmpty: true,
                matchesExpectedPrompt: false,
                stopActive: false
            )
        )
        check(
            "exactly this round's prompt may be reloaded",
            ArenaModel.isPreClickComposerSafe(
                draftEmpty: false,
                matchesExpectedPrompt: true,
                stopActive: false
            )
        )
        check(
            "a human draft is never reloaded over",
            !ArenaModel.isPreClickComposerSafe(
                draftEmpty: false,
                matchesExpectedPrompt: false,
                stopActive: false
            )
        )
        check(
            "a live Stop blocks even an empty composer",
            !ArenaModel.isPreClickComposerSafe(
                draftEmpty: true,
                matchesExpectedPrompt: false,
                stopActive: true
            )
        )
        check(
            "a live Stop blocks even our own prompt",
            !ArenaModel.isPreClickComposerSafe(
                draftEmpty: false,
                matchesExpectedPrompt: true,
                stopActive: true
            )
        )

        // --- Probe payload shape: comparison only, never a write -----------
        let prompt = "本轮完整提示：请比较两个方案。" + String(repeating: "长", count: 60)
        check(
            "SitePane accepts the probe comparison prompt",
            (try? SitePane.validatedProbeExpectedPrompt(prompt)) == prompt
        )
        check(
            "SitePane ignores an absent probe comparison prompt",
            (try? SitePane.validatedProbeExpectedPrompt(nil)) == nil
        )
        check(
            "SitePane rejects a non-string probe comparison prompt",
            (try? SitePane.validatedProbeExpectedPrompt(42)) == nil
        )
        check(
            "SitePane rejects a blank probe comparison prompt",
            (try? SitePane.validatedProbeExpectedPrompt(" \n\t ")) == nil
        )
        check(
            "SitePane rejects a NUL probe comparison prompt",
            (try? SitePane.validatedProbeExpectedPrompt("a\u{0}b")) == nil
        )
        check(
            "SitePane rejects an over-long probe comparison prompt",
            (try? SitePane.validatedProbeExpectedPrompt(String(repeating: "x", count: 100_001))) == nil
        )

        if failures == 0 {
            print("pre-click send repair: all checks passed")
            exit(0)
        }
        print("pre-click send repair: \(failures) check(s) failed")
        exit(1)
    }
}
