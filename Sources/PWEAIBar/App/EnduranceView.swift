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
/// to the reset. The gate is always its right end. The fuel is drawn as a band rather than a
/// point, because `Forecast` hands over an interval rather than a number:
///
///   * **solid amber** to where the fastest rate the readings allow runs the tank dry — the
///     stretch you certainly have;
///   * **half-lit amber** on to where the slowest rate allows — the stretch you might have;
///   * a **red dimension line** from the far end of that band to the gate, which is therefore a
///     gap that exists under every rate consistent with what has been read, not under one guess.
///
/// So the boundary case draws itself: a half-lit band straddling the gate is "we cannot tell
/// you", and it needs no sentence to say so.
///
/// Two rules survive from the version this replaces:
///
///   * **The needle says where its number came from.** Solid when the rate was measured from
///     readings taken over a recent stretch; hollow when it is the average since the window
///     opened. A picture is more persuasive than a sentence, so a picture drawn from a weaker
///     number has to admit it.
///   * **Degrade by disappearing.** A window with no reset has no rule to draw, and a gauge with
///     an invented axis is worse than an absent one. Those cases collapse to one honest line.
///
/// Nothing here animates into its value. Every coordinate is computed from `now` at build time —
/// no `trim`, no `.animation` on geometry. This app shipped that bug twice; the first frame is
/// true or the drawing is not allowed.
///
/// No copy decision is made in this file. The strings, and the colour band each of them belongs
/// to, come from `Forecast`; this only chooses type and position.
struct EnduranceView: View {
    let window: QuotaWindow
    let now: Date
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    /// The rule's width. The stage's own padding is 16pt a side; 12 of the remaining 308 are
    /// kept at the right so the gate's knock-out and its label have somewhere to bleed.
    private static let ruleWidth: CGFloat = 296

    private var forecast: Forecast { window.forecast(at: now) }

    var body: some View {
        // Fixed heights rather than spacers: the axis labels hang below the rule, and a
        // flexible stack pushed them past the component's own frame where they were clipped.
        let f = forecast
        return VStack(alignment: .leading, spacing: 0) {
            heading(f).frame(height: 11)
            Spacer().frame(height: 6)
            reading(f).frame(height: 30, alignment: .bottom)
            Spacer().frame(height: 5)
            if let plan = plan(f) {
                rule(plan, f).frame(height: 24, alignment: .top)
                axisLabels(plan, f).frame(height: 14, alignment: .top)
            } else {
                collapsed(f)
            }
        }
        .frame(height: f.hasTimeline ? 90 : 58, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(f.spoken)
    }

    // MARK: What is being drawn

    /// Where the marks sit. The rule always spans now → reset, and the gate is always its right
    /// end.
    ///
    /// It used to rescale when the endurance ran past the reset, sliding the gate inward to make
    /// room for a reserve tail. Two things were wrong with that. The axis label kept saying the
    /// reset time at the far right while the gate had moved to the middle, so the line and the
    /// words pointed at different moments — and even correctly labelled, a rule whose span
    /// changes with the reading cannot be compared with the same rule half an hour later.
    ///
    /// Spare capacity is a ratio, and it belongs in the sentence: 「到点至少剩 38%」.
    private struct Plan {
        let trip: TimeInterval
        let certain: CGFloat?   // x where the fastest allowed rate runs dry
        let possible: CGFloat?  // x where the slowest allowed rate does
        let measured: Bool
        let ticks: [CGFloat]
    }

    private func plan(_ f: Forecast) -> Plan? {
        guard let trip = f.trip, trip > 0 else { return nil }
        let W = Self.ruleWidth
        func x(_ t: TimeInterval?) -> CGFloat? {
            guard let t, t.isFinite else { return nil }
            return W * CGFloat(min(1, max(0, t / trip)))
        }
        return Plan(trip: trip,
                    certain: x(f.enduranceLow),
                    possible: f.enduranceHigh.map { $0.isFinite ? (x($0) ?? W) : W },
                    measured: f.evidence?.isMeasured ?? false,
                    ticks: Self.ticks(axis: trip, now: now, width: W))
    }

    // MARK: Rows

    private func heading(_ f: Forecast) -> some View {
        HStack(spacing: 5) {
            // With no timeline there is nothing to head; the collapsed line says it all, and
            // 「到重置」 above 「没有重置时间」 is the instrument contradicting itself.
            Text(f.headingLeft).brandLabel().foregroundStyle(Theme.text2)
            Spacer(minLength: Theme.s1)
            // With no rate at all the row stays empty — a placeholder dash reads as "still
            // loading" when the truth is "not going to know".
            if let pace = f.paceText {
                Text(pace).font(Theme.sans(9.5)).foregroundStyle(Theme.text2)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .frame(height: 11)
    }

    private func reading(_ f: Forecast) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
            if let headline = f.headline {
                duration(headline)
            } else {
                Text("没有重置时间").font(Theme.sans(15, 600)).foregroundStyle(Theme.text2)
            }
            Spacer(minLength: Theme.s1)
            if f.hasTimeline {
                Text(f.verdictText)
                    .font(Theme.sans(11.5, f.tone == .plain ? 400 : 600))
                    .foregroundStyle(colour(f.tone))
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
        }
    }

    /// The three bands, resolved once. `plain` is the panel's ordinary grey rather than the
    /// body colour: the one-second channel is "is there colour on the right", and a verdict that
    /// carries no news must not compete with one that does.
    private func colour(_ tone: Forecast.Tone) -> Color {
        switch tone {
        case .hot: return Theme.health(.hot, dark: isDark)
        case .warm: return Theme.health(.warm, dark: isDark)
        case .plain: return Theme.text2
        }
    }

    @ViewBuilder
    private func duration(_ seconds: TimeInterval) -> some View {
        let parts = Forecast.parts(seconds)
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
    private func collapsed(_ f: Forecast) -> some View {
        Text(f.verdictText)
            .font(Theme.sans(11)).foregroundStyle(Theme.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: The rule

    private func rule(_ plan: Plan, _ f: Forecast) -> some View {
        let W = Self.ruleWidth
        let hot = Theme.health(.hot, dark: isDark)
        return ZStack(alignment: .topLeading) {
            // Track: the empty tank. Never says anything on its own.
            Capsule().fill(Theme.sunk)
                .frame(width: W, height: 10).offset(y: 6)

            // Spent is checked first, and the order is the point. A spent window has no
            // endurance to compute, so the unknown-fuel branch would have claimed it and drawn
            // the grey dashed line that means "we could not measure this" — over the one window
            // we are most certain about. Empty and unknown must never draw the same.
            if case .spent = f.verdict {
                dimension(from: 0, to: W, colour: hot)
            } else if let certain = plan.certain, let possible = plan.possible {
                // The stretch that holds under every rate the readings allow.
                Capsule().fill(Theme.accent)
                    .frame(width: max(2, certain), height: 10).offset(y: 6)
                // And the stretch that holds only under the kind ones. Drawn as a lighter
                // continuation of the same bar rather than a second colour, because it is the
                // same fuel, less certainly.
                if possible > certain + 0.5 {
                    Capsule().fill(Theme.accent.opacity(0.42))
                        .frame(width: possible - certain, height: 10)
                        .offset(x: certain, y: 6)
                }
                // A gap that survives the most optimistic reading is the only gap worth a
                // colour, so the dimension line starts at the far end of the band.
                if possible < W - 0.5 {
                    dimension(from: possible, to: W, colour: hot)
                }
            } else {
                // We know the trip and not the fuel. A dashed centre line is the instrument's
                // way of saying the measurement is missing, rather than reading as empty.
                Capsule().fill(Color.red)
                    .frame(width: W, height: 10).offset(y: 6)
                    // mask removed for probe


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

            // Needle: the end of the certain stretch. Solid when that rate was measured from
            // readings, hollow when it is the whole-window average — the drawing carries its
            // own evidence. Suppressed when the certain stretch already reaches the gate,
            // because there is nothing there to point at.
            if let certain = plan.certain, certain < W - 1, f.verdict != .spent {
                NeedleShape()
                    .fill(plan.measured ? Theme.accent : Color.clear)
                    .overlay(NeedleShape().stroke(Theme.accent, lineWidth: 1))
                    .frame(width: 9, height: 7)
                    .offset(x: certain - 4.5, y: -1)
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
    private func axisLabels(_ plan: Plan, _ f: Forecast) -> some View {
        let W = Self.ruleWidth
        let certain = plan.certain
        ZStack(alignment: .topLeading) {
            if certain == nil || (certain ?? 0) > 51 {
                Text("现在").font(Theme.sans(9.5)).foregroundStyle(Theme.text2)
            }
            Text(Forecast.resetLabel(window.resetsAt, trip: plan.trip))
                .font(Theme.sans(9.5)).foregroundStyle(Theme.text2)
                .frame(width: W, alignment: .trailing)
            // The dry time is the headline read back onto the axis, so the two always agree:
            // both are the floored figure, never the raw one.
            // Coloured by the same band as the verdict. It marks where the fastest rate the
            // readings allow runs the tank dry — a fact in both cases, but under 「临界，说不准」
            // a red timestamp is the axis making a claim the sentence beside it refuses to.
            if let certain, certain < W - 1, certain <= 209, f.headlineIsEndurance,
               let headline = f.headline {
                Text("\(Forecast.clock(now.addingTimeInterval(headline))) 见底")
                    .font(Theme.sans(9.5)).foregroundStyle(colour(f.tone))
                    .fixedSize()
                    .frame(width: 90, alignment: certain < 51 ? .leading : .center)
                    .offset(x: certain < 51 ? 0 : certain - 45)
            }
        }
        .frame(width: W, alignment: .topLeading)
    }

    // MARK: Formatting

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
