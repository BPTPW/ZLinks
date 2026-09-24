//
//  GPSLiveActivityController.swift
//  ZLinks
//

import ActivityKit
import Foundation

@MainActor
final class GPSLiveActivityController {
    private var activity: Activity<GPSLiveActivityAttributes>?
    private var updateTask: Task<Void, Never>?

    func start(with contentState: GPSLiveActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if let existingActivity = Activity<GPSLiveActivityAttributes>.activities.first {
            activity = existingActivity
            update(with: contentState)
            return
        }

        do {
            activity = try Activity.request(
                attributes: GPSLiveActivityAttributes(sessionTitle: "GPS 同步"),
                content: ActivityContent(state: contentState, staleDate: nil),
                pushType: nil
            )
        } catch {
            activity = nil
        }
    }

    func update(with contentState: GPSLiveActivityAttributes.ContentState) {
        guard let activity else { return }
        updateTask?.cancel()
        updateTask = Task {
            await activity.update(ActivityContent(state: contentState, staleDate: nil))
        }
    }

    func end(with contentState: GPSLiveActivityAttributes.ContentState) {
        guard let activity else { return }
        self.activity = nil
        updateTask?.cancel()
        updateTask = Task {
            await activity.end(
                ActivityContent(state: contentState, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
    }
}
