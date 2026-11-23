//
//  ArenaSeatMotion.swift
//  AI Arena desktop (G1/G2/G4, R02/R03/R06/R07)
//
//  Pure policy for the live-only seat microinteractions. Keeping the rules here
//  makes the safety boundaries checkable without a web view:
//    * a paper plane needs a page-verified user turn from an active send;
//    * a saved-answer check needs a durable answer write;
//    * pause, takeover, history and restoration never animate.
//

import Foundation

enum ArenaSeatMotionPolicy {
    /// Receipt animation is permitted only for an active automatic send whose
    /// page verified the matching user turn. A click alone, a paused or
    /// taken-over seat, read-only history and any restored reconciliation are
    /// excluded.
    static func shouldAnimateVerifiedReceipt(
        turnVerified: Bool,
        paused: Bool,
        readOnly: Bool,
        takenOver: Bool
    ) -> Bool {
        turnVerified && !paused && !readOnly && !takenOver
    }

    /// The saved-answer check is shown only after the accepted answer was
    /// durably written. Invalid stance, skipped tasks and unsaved answers never
    /// reach this rule; history renders pass `readOnly`.
    static func shouldAnimateSavedAnswer(saved: Bool, readOnly: Bool) -> Bool {
        saved && !readOnly
    }
}
