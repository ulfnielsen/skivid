import CoreGraphics
import Foundation

/// A run of detections believed to be the same person across consecutive
/// frames. Gaps are possible where the track missed and later reacquired.
public struct Tracklet {
    public let id: Int
    /// Ascending in time.
    public let detections: [PoseDetection]

    public init(id: Int, detections: [PoseDetection]) {
        self.id = id
        self.detections = detections
    }

    public var firstSeen: TimeInterval { detections.first?.time ?? 0 }
    public var lastSeen: TimeInterval { detections.last?.time ?? 0 }
}

/// Joins per-frame detections into tracklets by committing to one detection
/// and following it.
///
/// The shape — no appearance model, no global assignment, no scoring blend;
/// per track take the *nearest* detection passing a distance gate and a
/// two-sided height gate — is inherited from `pick_main_person` in the
/// project owner's `~/dev/ski` pipeline. Two things about it are not.
///
/// **The distance gate is derived from the track's own recent motion**, not
/// from a constant. Measured on `Idun Nielsen/C0094.MP4`, the ported constant
/// gate (0.21 of frame width, widening 0.031 per miss) let a track that lost
/// its subject for four frames take a *different person* standing 0.206 away
/// — inside the gate before any widening applied. The athlete's own
/// per-sample displacement in the seconds before that was about 0.015, so the
/// bystander was more than ten times her own recent motion away. A constant
/// cannot see that difference; a gate scaled from the track's own history
/// can, and it needs no appearance model to do it. A sweep of the constant
/// gates over that clip produced no setting that separated the two people:
/// loosening fused everyone into one track, tightening shattered the clip
/// into fragments still split across both. The conclusion was not "tune
/// harder" — it was that fixed absolute gates cannot hold identity across a
/// long clip with frequent dropouts and two similarly-sized people.
///
/// **The track is cut when the association is not clearly right.** If two or
/// more detections qualify, this linker refuses to pick one and ends the
/// track at its last hit (see `cutOnAmbiguity`). A tracklet that ends early
/// is recoverable — the operator picks a different segment, or the next
/// segment of the same person. A tracklet that silently continues as someone
/// else is not: it looks entirely plausible and corrupts everything
/// downstream. Ending is always the safer error here.
public enum TrackletLinker {
    /// - Parameters:
    ///   - initialJumpFraction: distance gate for a track too young to have
    ///     measured its own speed (fewer than two detections). Not
    ///     `speedFloor`: a brand-new track has no evidence that its subject is
    ///     slow, only no evidence either way, so it gets a frame-to-frame
    ///     budget rather than the floor.
    ///   - speedMultiplier: how many times its own recent per-sample
    ///     displacement a track may jump in one sample.
    ///   - speedFloor: lower bound on the gate for a track that has been
    ///     nearly stationary, so quantisation of a standing person's box does
    ///     not collapse the gate to zero.
    ///   - widenPerMiss: fraction of the base gate added per consecutive miss.
    ///   - maxHeightRatio: two-sided box-height ratio bound, `max(r, 1/r)`.
    ///   - heightWidenPerMiss: fraction of `maxHeightRatio` added per miss.
    ///   - maxMisses: consecutive misses after which a track ends.
    ///   - cutOnAmbiguity: when true, two or more qualifying detections end
    ///     the track rather than being resolved by nearest-wins.
    public static func link(
        _ frames: [FrameDetections],
        initialJumpFraction: Double = 0.06,
        speedMultiplier: Double = 4.0,
        speedFloor: Double = 0.02,
        widenPerMiss: Double = 0.5,
        maxHeightRatio: Double = 1.15,
        heightWidenPerMiss: Double = 0.1,
        maxMisses: Int = 10,
        cutOnAmbiguity: Bool = true
    ) -> [Tracklet] {
        /// Number of recent per-sample displacements averaged into a track's
        /// speed. Short enough to follow a skier accelerating out of the
        /// start, long enough that one noisy box does not blow the gate open.
        let speedWindow = 5

        struct Active {
            let id: Int
            var detections: [PoseDetection]
            var misses: Int
            var lastCentre: CGPoint
            var lastHeight: Double
            /// Centre-to-centre displacements between hits on *adjacent*
            /// samples, most recent last, at most `speedWindow` of them. A
            /// reacquisition across a gap is deliberately not recorded: it
            /// covers several samples' worth of travel and would inflate the
            /// very estimate the next gate is built from.
            var recentSteps: [Double]

            var speed: Double? {
                guard !recentSteps.isEmpty else { return nil }
                return recentSteps.reduce(0, +) / Double(recentSteps.count)
            }
        }

        var active: [Active] = []
        var finished: [Tracklet] = []
        var nextID = 0

        for frame in frames.sorted(by: { $0.time < $1.time }) {
            var unclaimed = Array(frame.poses.indices)

            // Order tracks by fewest misses first. The distance gate widens
            // with each consecutive miss, so a stale track carries a wider
            // gate than one that saw its subject last frame; letting it claim
            // first would let it hoover up a detection that plainly belongs
            // to the healthier track. A track that has just seen its subject
            // is the more trustworthy claim, regardless of how long its
            // history is. Ties break on longer `detections.count` (an
            // established track outranks a brand-new one), then on id,
            // keeping the result deterministic regardless of array order.
            let order = active.indices.sorted {
                let left = active[$0], right = active[$1]
                if left.misses != right.misses {
                    return left.misses < right.misses
                }
                if left.detections.count != right.detections.count {
                    return left.detections.count > right.detections.count
                }
                return left.id < right.id
            }

            // Tracks cut by the ambiguity rule this frame. Collected rather
            // than removed in place so `order`'s indices stay valid for the
            // rest of the pass.
            var cut: Set<Int> = []

            for trackIndex in order {
                let track = active[trackIndex]
                let base = track.speed.map { max(speedFloor, speedMultiplier * $0) }
                    ?? initialJumpFraction
                let gate = base * (1 + widenPerMiss * Double(track.misses))
                let heightGate = maxHeightRatio * (1 + heightWidenPerMiss * Double(track.misses))

                var qualifyingCount = 0
                var bestSlot: Int?
                var bestDistance = Double.infinity
                for slot in unclaimed.indices {
                    let pose = frame.poses[unclaimed[slot]]
                    let dx = Double(pose.centre.x - track.lastCentre.x)
                    let dy = Double(pose.centre.y - track.lastCentre.y)
                    let distance = (dx * dx + dy * dy).squareRoot()
                    guard distance < gate else { continue }

                    let ratio = pose.height / max(track.lastHeight, 1e-9)
                    let twoSided = max(ratio, 1.0 / max(ratio, 1e-9))
                    guard twoSided < heightGate else { continue }

                    qualifyingCount += 1
                    if distance < bestDistance {
                        bestDistance = distance
                        bestSlot = slot
                    }
                }

                // Two plausible continuations mean the evidence does not
                // identify one person. Guessing between them is exactly what
                // produced tracks that changed subject partway through, so
                // end here instead and leave both detections unclaimed — they
                // start fresh tracks like any other unclaimed detection, or
                // are taken by a track that can tell them apart.
                if cutOnAmbiguity, qualifyingCount >= 2 {
                    cut.insert(trackIndex)
                    continue
                }

                if let slot = bestSlot {
                    let pose = frame.poses[unclaimed[slot]]
                    if active[trackIndex].misses == 0, !active[trackIndex].detections.isEmpty {
                        active[trackIndex].recentSteps.append(bestDistance)
                        if active[trackIndex].recentSteps.count > speedWindow {
                            active[trackIndex].recentSteps.removeFirst()
                        }
                    }
                    active[trackIndex].detections.append(pose)
                    active[trackIndex].misses = 0
                    active[trackIndex].lastCentre = pose.centre
                    active[trackIndex].lastHeight = pose.height
                    unclaimed.remove(at: slot)
                } else {
                    active[trackIndex].misses += 1
                }
            }

            // `misses > 0` guards the degenerate `maxMisses: 0`, which reads
            // as "end on the first miss" and must not end a track that has
            // just been seen.
            for index in active.indices.reversed()
            where cut.contains(index)
                || (active[index].misses > 0 && active[index].misses >= maxMisses) {
                finished.append(Tracklet(id: active[index].id, detections: active[index].detections))
                active.remove(at: index)
            }

            for poseIndex in unclaimed {
                let pose = frame.poses[poseIndex]
                active.append(Active(
                    id: nextID,
                    detections: [pose],
                    misses: 0,
                    lastCentre: pose.centre,
                    lastHeight: pose.height,
                    recentSteps: []
                ))
                nextID += 1
            }
        }

        finished.append(contentsOf: active.map { Tracklet(id: $0.id, detections: $0.detections) })
        return finished.sorted { $0.id < $1.id }
    }
}
