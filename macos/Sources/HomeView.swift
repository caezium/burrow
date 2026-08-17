//
//  HomeView.swift
//  Burrow
//
//  Home — the live dashboard, reached by clicking the Burrow mark. It folds
//  the three "watch your Mac" views into one place behind a segmented switch:
//
//    Overview  — live metric cards + the process table (the old Status tab)
//    History   — long-range charts over the SQLite history
//    Activity  — Mole's cleanup session log
//
//  The Explain (AI) entry point lives here too, so it can speak to whatever
//  you're looking at — or the whole picture.
//

import SwiftUI

struct HomeView: View {
    let db: DB
    let live: LiveFeed
    let feeds: FeedHub
    var onNavigate: (Pane) -> Void

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case tuneup = "Tune-Up"
        case history = "History"
        case activity = "Activity"
        case doctor = "Doctor"
        var id: String { rawValue }
    }

    @State private var section: Section = .overview
    @State private var showExplain = false
    @ObservedObject private var featureFlags = FeatureFlags.shared

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 10)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showExplain) {
            ExplainView(db: db,
                        onNavigate: { showExplain = false; onNavigate($0) },
                        onClose: { showExplain = false })
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            segmented
            Spacer()
            if Store.aiEnabled { explainButton }
        }
    }

    private var segmented: some View {
        HStack(spacing: 2) {
            ForEach(Section.allCases) { s in
                let on = s == section
                Button { withAnimation(.easeOut(duration: 0.14)) { section = s } } label: {
                    HStack(spacing: 5) {
                        Text(NSLocalizedString(s.rawValue, comment: ""))
                        if s == .tuneup, featureFlags.boolValue(.tuneUpBadge) {
                            Circle()
                                .fill(Tool.tuneup.accent)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .font(Brand.mono(12, on ? .semibold : .regular))
                    .foregroundStyle(on ? Brand.base : Brand.textSecondary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background { if on { Capsule().fill(Brand.textPrimary) } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Brand.chipFill))
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private var explainButton: some View {
        Button { showExplain = true } label: {
            Label(NSLocalizedString("Explain", comment: ""), systemImage: "sparkles")
                .font(Brand.mono(11, .semibold)).foregroundStyle(Tool.status.accent)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Tool.status.accent.opacity(0.12)))
                .overlay(Capsule().strokeBorder(Tool.status.accent.opacity(0.30), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .overview: StatusView(db: db, live: live, feeds: feeds)
        case .tuneup:   TuneUpView()
        case .history:  HistoryView(db: db, live: live, feeds: feeds)
        case .activity: ActivityView(feeds: feeds)
        case .doctor:   DoctorView(db: db)
        }
    }
}
