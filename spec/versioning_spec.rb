describe Fastlane::Helper::RnShipVersioning do
  describe ".resolve_next_version" do
    [
      {
        name: "no store version: increments the build only",
        current_version: "1.0.3", current_build: 5, latest_version: nil, latest_build: 0, live_version: "1.0.2",
        expected: { version: "1.0.3", build: 6 }
      },
      {
        name: "version mismatch: aligns to the store and increments its build",
        current_version: "1.0.3", current_build: 5, latest_version: "1.0.4", latest_build: 3, live_version: "1.0.2",
        expected: { version: "1.0.4", build: 4 }
      },
      {
        name: "versions match: increments the build only",
        current_version: "1.0.3", current_build: 5, latest_version: "1.0.3", latest_build: 5, live_version: "1.0.2",
        expected: { version: "1.0.3", build: 6 }
      },
      {
        # Build 13 uploaded, then the bump push failed and left the branch on 12. Trusting
        # the branch recomputes 13, which the store rejects as a duplicate.
        name: "versions match but the store is ahead: continues from the store",
        current_version: "1.1.0", current_build: 12, latest_version: "1.1.0", latest_build: 13, live_version: nil,
        expected: { version: "1.1.0", build: 14 }
      },
      {
        name: "versions match but the branch is ahead: continues from the branch",
        current_version: "1.0.3", current_build: 7, latest_version: "1.0.3", latest_build: 5, live_version: "1.0.2",
        expected: { version: "1.0.3", build: 8 }
      },
      {
        name: "versions match and the train is closed: bumps the patch and resets the build",
        current_version: "1.0.3", current_build: 5, latest_version: "1.0.3", latest_build: 5, live_version: "1.0.3",
        expected: { version: "1.0.4", build: 1 }
      },
      {
        name: "no store version and the train is closed: bumps the patch and resets the build",
        current_version: "1.0.3", current_build: 5, latest_version: nil, latest_build: 0, live_version: "1.0.3",
        expected: { version: "1.0.4", build: 1 }
      },
      {
        name: "aligned version equals live: bumps the patch and resets the build",
        current_version: "1.0.2", current_build: 3, latest_version: "1.0.3", latest_build: 5, live_version: "1.0.3",
        expected: { version: "1.0.4", build: 1 }
      },
      {
        name: "monotonic, versions match: increments the build",
        current_version: "1.2.6", current_build: 4, latest_version: "1.2.6", latest_build: 4, live_version: "1.2.5",
        monotonic_build: true, expected: { version: "1.2.6", build: 5 }
      },
      {
        name: "monotonic, closed train: bumps the patch and keeps counting",
        current_version: "1.2.6", current_build: 7, latest_version: "1.2.6", latest_build: 7, live_version: "1.2.6",
        monotonic_build: true, expected: { version: "1.2.7", build: 8 }
      },
      {
        name: "monotonic, version mismatch: aligns to the store and counts from the highest",
        current_version: "1.2.6", current_build: 9, latest_version: "1.1.0", latest_build: 3, live_version: nil,
        monotonic_build: true, expected: { version: "1.1.0", build: 10 }
      },
      {
        name: "monotonic, store ahead of the branch: continues from the store",
        current_version: "1.2.6", current_build: 2, latest_version: "1.2.6", latest_build: 6, live_version: nil,
        monotonic_build: true, expected: { version: "1.2.6", build: 7 }
      },
      {
        name: "monotonic, nothing on the store yet: continues from the branch",
        current_version: "1.2.6", current_build: 1, latest_version: nil, latest_build: 0, live_version: nil,
        monotonic_build: true, expected: { version: "1.2.6", build: 2 }
      }
    ].each do |tc|
      it(tc[:name]) do
        result = described_class.resolve_next_version(
          current_version: tc[:current_version], current_build: tc[:current_build],
          latest_version: tc[:latest_version], latest_build: tc[:latest_build],
          live_version: tc[:live_version], monotonic_build: tc.fetch(:monotonic_build, false)
        )
        expect(result).to eq(tc[:expected])
      end
    end

    it "treats an empty store version like no store version" do
      result = described_class.resolve_next_version(
        current_version: "2.0.0", current_build: 3, latest_version: "", latest_build: 0, live_version: nil
      )
      expect(result).to eq(version: "2.0.0", build: 4)
    end
  end

  describe ".bump_semver" do
    [
      ["1.0.3", "patch", "1.0.4"],
      ["1.0.3", "minor", "1.1.0"],
      ["1.0.3", "major", "2.0.0"],
      ["1.0", "patch", "1.0.1"],
      ["1", "patch", "1.0.1"],
      ["0.9.9", "patch", "0.9.10"],
      ["1.9.0", "minor", "1.10.0"]
    ].each do |version, type, expected|
      it("#{version} + #{type} = #{expected}") do
        expect(described_class.bump_semver(version: version, type: type)).to eq(expected)
      end
    end

    it "rejects an unknown bump type" do
      expect { described_class.bump_semver(version: "1.0.0", type: "build") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /Unknown bump type: build/)
    end
  end
end

describe Fastlane::Actions::RnShipNextVersionAction do
  it "returns the resolved version and stores it in the lane context" do
    result = run_lane('rn_ship_next_version(current_version: "1.2.6", current_build: 7, latest_version: "1.2.6", latest_build: 7, live_version: "1.2.6", monotonic_build: true)')

    expect(result).to eq(version: "1.2.7", build: 8)
    expect(Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::RN_SHIP_NEXT_VERSION]).to eq("1.2.7")
    expect(Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::RN_SHIP_NEXT_BUILD]).to eq(8)
  end

  it "defaults to no store state" do
    expect(run_lane('rn_ship_next_version(current_version: "0.1.0", current_build: 1)')).to eq(version: "0.1.0", build: 2)
  end
end
