import SwiftUI

/// The panel's hero: a fuel-endurance gauge for one quota window.
///
/// It replaces a 124pt rendering of the brand mark used as a five-channel gauge. That mark was
/// beautiful and could not be asked anything — five feathers standing for five channels, none of
/// them reachable, restating numbers already listed below. Making the feathers clickable was
/// tried and rejected as fiddly to operate; the honest conclusion was that the space should do a
/// job the rest of the panel does not.
///
/// This does one: **will the tank get me to the station.** A horizontal time rule runs from now
/// to the right. Two marks sit on it — a *gate* at the reset, and a *needle* where the current
/// rate runs the window dry. The amber bar either stops before the gate or does not, and that is
/// the whole reading. Everything else on it is there to say how much to trust that.
///
/// Two ideas are borrowed from the plot design that lost:
///
///   * **The needle says where its number came from.** Solid when the rate was measured from
///     readings taken over a recent stretch; hollow when it is the average since the window
///     opened. A picture is more persuasive than a sentence, so a picture drawn from a weaker
///     number has to admit it — the earlier text-only version could hedge in words, and this
///     cannot.
///   * **Degrade by disappearing.** A window with no reset has no rule to draw, and a gauge with
///     an invented axis is worse than an absent one. Those cases collapse to one honest line.
///
/// Nothing here animates into its value. Every coordinate is computed from `now` at build time —
/// no `trim`, no `.animation` on geometry. This app shipped that bug twice; the first frame is
/// true or the drawing is not allowed.
struct EnduranceView: View {
    let window: QuotaWindow
    let now: Date
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    /// The rule's width. The stage's own padding is 16pt a side; 12 of the remaining 308 are
    /// kept at the right so the gate's knock-out and its label have somewhere to bleed.
    private static let ruleWidth: CGFloat = 296

    var body: some View {
        // Fixed heights rather than spacers: the axis labels hang below the rule, and a
        // flexible stack pushed them past the component's own frame where they were clipped.
        VStack(alignment: .leading, spacing: 0) {
            heading.frame(height: 11)
            Spacer().frame(height: 6)
            reading.frame(height: 30, alignment: .bottom)
            Spacer().frame(height: 5)
            if let plan {
                rule(plan).frame(height: 24, alignment: .top)
                axisLabels(plan).frame(height: 14, alignment: .top)
            } else {
                collapsed
            }
        }
        .frame(height: plan == nil ? 58 : 90, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    // MARK: What is being drawn

    /// Everything the drawing needs, resolved once. Nil when this window has no timeline —
    /// no reset, or a reset already behind us, which is a different fact and gets said instead.
    /// The rule always spans now → this reset, and the gate is always its right end.
    ///
    /// It used to rescale when the endurance ran past the reset, sliding the gate inward to make
    /// room for a reserve tail. Two things were wrong with that. The axis label kept saying the
    /// reset time at the far right while the gate had moved to the middle, so the line and the
    /// words pointed at different moments — and even correctly labelled, a rule whose span
    /// changes with the reading cannot be compared with the same rule half an hour later.
    ///
    /// Spare capacity is a ratio, and it belongs in the sentence: 「到点还剩 38%」.
    private struct Plan {
        let trip: TimeInterval          // now → reset, and the full width of the rule
        let needle: CGFloat?            // x where the pace runs dry; nil when it lasts the trip
        let endurance: TimeInterval?    // now → dry
        let measured: Bool
        let ticks: [CGFloat]
    }

    private var plan: Plan? {
        guard let reset = window.resetsAt, reset > now else { return nil }
        let trip = reset.timeIntervalSince(now)
        let burn = window.burn(at: now)
        let dry = window.projectedExhaustion(at: now)

        // Endurance beyond the trip is derived rather than measured: the pace has to be run
        // forward past the reset to find where it *would* have run out.
        var endurance: TimeInterval?
        if let dry { endurance = dry.timeIntervalSince(now) }
        else if let burn, burn.perHour > 0.01, let percent = window.percent, percent < 99.5 {
            endurance = (100 - percent) / burn.perHour * 3600
        }

        let W = Self.ruleWidth
        let needle: CGFloat? = endurance.flatMap { $0 < trip ? W * CGFloat($0 / trip) : nil }
        return Plan(trip: trip, needle: needle, endurance: endurance,
                    measured: burn?.measured ?? false,
                    ticks: Self.ticks(axis: trip, now: now, width: W))
    }

    private var shortfall: TimeInterval? {
        guard let plan, let endurance = plan.endurance, endurance < plan.trip else { return nil }
        return plan.trip - endurance
    }

    // MARK: Rows

    private var heading: some View {
        HStack(spacing: 5) {
            // With no timeline there is nothing to head; the collapsed line says it all, and
            // "到重置" above "没有重置时间" is the instrument contradicting itself.
            Text(plan == nil ? "" : (headlineIsEndurance ? "续航" : "到重置"))
                .brandLabel().foregroundStyle(Theme.text2)
            Spacer(minLength: Theme.s1)
            // Saying which stretch the rate covers is the difference between a claim and a
            // reading. With no rate at all the row stays empty — a placeholder dash reads as
            // "still loading" when the truth is "not going to know".
            if let burn = window.burn(at: now) {
                Text(burn.measured ? "最近 \(Self.span(burn.span))" : "开窗以来")
                    .font(Theme.sans(9.5)).foregroundStyle(Theme.text2)
                Text("耗速 \(Self.rate(burn.perHour))%/时")
                    .font(Theme.figures(10, 500)).foregroundStyle(Theme.text2)
            }
        }
        .frame(height: 11)
    }

    /// The headline is whichever of the two will actually happen.
    ///
    /// Endurance past the reset is hypothetical: the window rolls over and refills long before
    /// the tank would have run dry, so a two-hour window headlining "13 小时 40 分" describes
    /// uninterrupted running time nobody is ever going to get. When the pace lasts the trip, the
    /// thing that happens is the reset, and the spare capacity is a ratio in the verdict.
    private var headlineIsEndurance: Bool {
        guard let plan, !window.confirmedExhausted, let endurance = plan.endurance else { return false }
        return endurance < plan.trip
    }

    private var reading: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
            if let plan, headlineIsEndurance, let endurance = plan.endurance {
                duration(endurance)
            } else if let plan {
                duration(plan.trip)
            } else {
                Text("没有重置时间").font(Theme.sans(15, 600)).foregroundStyle(Theme.text2)
            }
            Spacer(minLength: Theme.s1)
            verdict
        }
    }

    @ViewBuilder
    private func duration(_ seconds: TimeInterval) -> some View {
        let parts = Self.parts(seconds)
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Text(part.text)
                    .font(part.isNumber ? Theme.figures(24, 600) : Theme.sans(12, 500))
                    .foregroundStyle(Theme.text)
            }
        }
        .lineLimit(1).minimumScaleFactor(0.7)
    }

    @ViewBuilder
    private var verdict: some View {
        let hot = Theme.health(.hot, dark: isDark)
        if window.confirmedExhausted {
            Text("已用尽").font(Theme.sans(11.5, 600)).foregroundStyle(hot)
        } else if let gap = shortfall {
            Text("缺口 \(Self.span(gap))").font(Theme.sans(11.5, 600)).foregroundStyle(hot)
        } else if let landing = window.projectedPercentAtReset(at: now) {
            Text("到点还剩 \(Int(max(0, 100 - landing).rounded()))%")
                .font(Theme.sans(11.5)).foregroundStyle(Theme.text2)
        } else if plan != nil {
            // One flag word for the off position, four reasons for it. An instrument's OFF flag
            // should look the same however it got there.
            Text(offReason).font(Theme.sans(11.5)).foregroundStyle(Theme.text2)
                .lineLimit(1).minimumScaleFactor(0.85)
        }
    }

    private var offReason: String {
        if window.percent == nil { return "没有百分比，不推算" }
        if window.isStale { return "读数太旧，不推算" }
        if window.windowLength == nil { return "没有窗口长度，不推算" }
        return "用量太少，不推算"
    }

    @ViewBuilder
    private var collapsed: some View {
        Text(window.resetsAt == nil ? "这个额度没有重置时间，算不出续航"
                                    : "已过重置时间，等新读数确认")
            .font(Theme.sans(11)).foregroundStyle(Theme.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: The rule

    private func rule(_ plan: Plan) -> some View {
        let W = Self.ruleWidth
        let hot = Theme.health(.hot, dark: isDark)
        let fuelEnd = plan.needle ?? W
        return ZStack(alignment: .topLeading) {
            // Track: the empty tank. Never says anything on its own.
            Capsule().fill(Theme.sunk)
                .frame(width: W, height: 10).offset(y: 6)

            // Spent is checked first, and the order is the point. A spent window has no
            // endurance to compute, so the unknown-fuel branch would have claimed it and drawn
            // the grey dashed line that means "we could not measure this" — over the one window
            // we are most certain about. Empty and unknown must never draw the same.
            if window.confirmedExhausted {
                dimension(from: 0, to: W, colour: hot)
            } else if window.percent == nil || window.isStale || plan.endurance == nil {
                // We know the trip and not the fuel. A dashed centre line is the instrument's
                // way of saying the measurement is missing, rather than reading as empty.
                Rectangle().fill(Theme.text2.opacity(0.5))
                    .frame(width: W, height: 1).offset(y: 10.5)
                    .mask(HStack(spacing: 3) {
                        ForEach(0..<49, id: \.self) { _ in Rectangle().frame(width: 3) }
                    }.frame(width: W, alignment: .leading))
            } else {
                Capsule().fill(Theme.accent)
                    .frame(width: max(2, fuelEnd), height: 10).offset(y: 6)
                if let needle = plan.needle {
                    dimension(from: needle, to: W, colour: hot)
                }
            }

            // Start line.
            Rectangle().fill(Theme.text2).frame(width: 1, height: 12).offset(y: 5)

            // Ticks, anchored to whole clock times rather than to "now" — a rule whose marks
            // slide with the current second is a rule you cannot read twice.
            ForEach(Array(plan.ticks.enumerated()), id: \.offset) { _, x in
                Rectangle().fill(Theme.text2.opacity(0.7))
                    .frame(width: 1, height: 5).offset(x: x, y: 19)
            }

            // Gate: the reset. Knocked out of whatever it crosses first, which is the old
            // instrument trick for a cursor over a filled bar — without it a white line on
            // amber turns to mud in dark mode.
            Rectangle().fill(Theme.surface).frame(width: 6, height: 22).offset(x: W - 3)
            Rectangle().fill(Theme.text).frame(width: 2, height: 22).offset(x: W - 2)

            // Needle: where the pace runs dry. Solid when that pace was measured from readings,
            // hollow when it is the whole-window average — the drawing carries its own evidence.
            if let needle = plan.needle, !window.confirmedExhausted {
                NeedleShape()
                    .fill(plan.measured ? Theme.accent : Color.clear)
                    .overlay(NeedleShape().stroke(Theme.accent, lineWidth: 1))
                    .frame(width: 9, height: 7)
                    .offset(x: needle - 4.5, y: -1)
            }
        }
        .frame(width: W, height: 24, alignment: .topLeading)
    }

    /// An engineering dimension line, not a filled region: it measures the gap rather than
    /// colouring a stretch, so it cannot be read as "this part is red".
    private func dimension(from: CGFloat, to: CGFloat, colour: Color) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(colour).frame(width: max(1, to - from), height: 1).offset(x: from, y: 10.5)
            Rectangle().fill(colour).frame(width: 1, height: 5).offset(x: from, y: 8.5)
            Rectangle().fill(colour).frame(width: 1, height: 5).offset(x: max(from, to - 1), y: 8.5)
        }
    }

    @ViewBuilder
    private func axisLabels(_ plan: Plan) -> some View {
        let W = Self.ruleWidth
        let hot = Theme.health(.hot, dark: isDark)
        ZStack(alignment: .topLeading) {
            if plan.needle == nil || (plan.needle ?? 0) > 51 {
                Text("现在").font(Theme.sans(9.5)).foregroundStyle(Theme.text2)
            }
            Text(Self.resetLabel(window.resetsAt, trip: plan.trip))
                .font(Theme.sans(9.5)).foregroundStyle(Theme.text2)
                .frame(width: W, alignment: .trailing)
            if let needle = plan.needle, let dry = window.projectedExhaustion(at: now), needle <= 209 {
                Text("\(Self.clock(dry)) 见底")
                    .font(Theme.sans(9.5)).foregroundStyle(hot)
                    .fixedSize()
                    .frame(width: 90, alignment: needle < 51 ? .leading : .center)
                    .offset(x: needle < 51 ? 0 : needle - 45)
            }
        }
        .frame(width: W, alignment: .topLeading)
    }

    // MARK: Formatting

    private var spoken: String {
        guard let plan else {
            return window.resetsAt == nil ? "这个额度没有重置时间，算不出续航"
                                          : "已过重置时间，等新读数确认"
        }
        if window.confirmedExhausted { return "已用尽，还有 \(Self.span(plan.trip)) 重置" }
        guard let burn = window.burn(at: now), let endurance = plan.endurance else {
            return "到重置还有 \(Self.span(plan.trip))。\(offReason)"
        }
        let rate = "按每小时 \(Self.rate(burn.perHour))% 的节奏"
        if let gap = shortfall {
            return "\(rate)还能撑 \(Self.span(endurance))，到重置还差 \(Self.span(gap))"
        }
        let left = window.projectedPercentAtReset(at: now).map { Int(max(0, 100 - $0).rounded()) } ?? 0
        return "\(rate)能撑到重置，到点还剩 \(left)%"
    }

    static func rate(_ perHour: Double) -> String {
        perHour < 1 ? String(format: "%.1f", perHour) : String(Int(perHour.rounded()))
    }

    /// One duration format for the whole app. Split into number and unit so the figures can take
    /// the tabular face and the units can stay in the interface face.
    static func parts(_ seconds: TimeInterval) -> [(text: String, isNumber: Bool)] {
        let s = max(0, Int(seconds))
        if s < 3600 { return [("\(max(1, s / 60))", true), ("分", false)] }
        if s < 86400 {
            let h = s / 3600, m = (s % 3600) / 60
            return m == 0 ? [("\(h)", true), ("小时", false)]
                          : [("\(h)", true), ("小时", false), ("\(m)", true), ("分", false)]
        }
        if s < 172_800 {
            let d = s / 86400, h = (s % 86400) / 3600
            return h == 0 ? [("\(d)", true), ("天", false)]
                          : [("\(d)", true), ("天", false), ("\(h)", true), ("小时", false)]
        }
        return [("\(s / 86400)", true), ("天以上", false)]
    }

    /// The same duration as a plain string. Spaced the way the panel writes them everywhere
    /// else — "1 小时 17 分", never "1小时17分".
    static func span(_ seconds: TimeInterval) -> String {
        parts(seconds).map(\.text).joined(separator: " ")
            .replacingOccurrences(of: " 天以上", with: " 天以上")
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func resetLabel(_ reset: Date?, trip: TimeInterval) -> String {
        guard let reset else { return "" }
        if trip < 86400 { return "\(clock(reset)) 重置" }
        return "\(max(1, Int((trip / 86400).rounded()))) 天后重置"
    }

    /// Tick positions, anchored to whole clock times inside the span the rule covers.
    static func ticks(axis: TimeInterval, now: Date, width: CGFloat) -> [CGFloat] {
        let steps: [TimeInterval] = [600, 1800, 3600, 4 * 3600, 86400, 2 * 86400]
        let step = steps.first { axis / $0 <= 8 } ?? steps[steps.count - 1]
        guard step > 0, axis > 0 else { return [] }
        let start = now.timeIntervalSince1970
        var t = (start / step).rounded(.up) * step
        var out: [CGFloat] = []
        while t - start < axis, out.count < 12 {
            let x = width * CGFloat((t - start) / axis)
            if x > 6, x < width - 6 { out.append(x) }
            t += step
        }
        return out
    }
}

/// A downward-pointing triangle whose tip touches the top of the track.
private struct NeedleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
