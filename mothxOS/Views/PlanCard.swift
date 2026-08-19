import SwiftUI

struct PlanCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let plan: MothxPlan
    let isRunning: Bool

    @State private var visibleSteps: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.blue)

                Text(plan.title.isEmpty ? "任务计划" : plan.title)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                if isRunning {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.blue)
                            .frame(width: 6, height: 6)
                            .opacity(blinkOpacity)
                        Text("执行中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("已完成")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Steps
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                    if visibleSteps.contains(step.id) {
                        PlanStepRow(step: step)
                            .transition(
                                .move(edge: .bottom).combined(with: .opacity)
                            )
                            .animation(
                                .easeOut(duration: 0.3).delay(Double(index) * 0.08),
                                value: visibleSteps
                            )

                        if index < plan.steps.count - 1 {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
            }

            // Note
            if let note = plan.note, !note.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .background(
            colorScheme == .light
                ? Color.blue.opacity(0.04)
                : Color.blue.opacity(0.08)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.blue.opacity(0.2), lineWidth: 1)
        )
        .onAppear {
            revealSteps()
        }
        .onChange(of: plan.steps.map(\.id)) { _, _ in
            revealSteps()
        }
    }

    @State private var blinkOpacity: Double = 1.0

    private func revealSteps() {
        visibleSteps = []
        for (index, step) in plan.steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.08) {
                withAnimation(.easeOut(duration: 0.3)) {
                    _ = visibleSteps.insert(step.id)
                }
            }
        }
    }
}

// MARK: - Plan Step Row

struct PlanStepRow: View {
    let step: MothxPlanStep

    var body: some View {
        HStack(spacing: 10) {
            stepIcon
                .font(.system(size: 13, weight: .medium))
                .frame(width: 20)

            Text(step.title)
                .font(.subheadline)
                .foregroundStyle(step.status == "done" ? .secondary : .primary)
                .strikethrough(step.status == "done", color: .secondary)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var stepIcon: some View {
        switch step.status {
        case "done":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case "running":
            Image(systemName: "arrow.trianglehead.circle.dotted")
                .foregroundStyle(.blue)
                .symbolEffect(.pulse, options: .repeating)
        case "failed":
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        default:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        }
    }
}