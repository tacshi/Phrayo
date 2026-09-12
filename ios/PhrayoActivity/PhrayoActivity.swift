import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main struct PhrayoActivityBundle: WidgetBundle {
  var body: some Widget { PhrayoRecordingActivity() }
}
struct PhrayoRecordingActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: RecordingAttributes.self) { context in
      HStack(spacing: 16) {
        Image(systemName: "mic.fill").foregroundStyle(Color(red: 0.44, green: 0.80, blue: 0.65))
        VStack(alignment: .leading) {
          Text(context.state.paused ? "Paused" : "Recording").font(.headline)
          if context.state.paused {
            Text(Duration.seconds(context.state.seconds).formatted(.time(pattern: .minuteSecond)))
          } else {
            Text(context.state.started, style: .timer).monospacedDigit()
          }
        }
        Spacer()
        Button(intent: ActivityStopIntent()) { Image(systemName: "stop.fill").padding(8) }.tint(
          .red)
      }.padding().activityBackgroundTint(Color(red: 0.09, green: 0.24, blue: 0.20))
        .activitySystemActionForegroundColor(.white).foregroundStyle(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: "mic.fill").foregroundStyle(.mint)
        }
        DynamicIslandExpandedRegion(.center) { Text(context.state.paused ? "Paused" : "Recording") }
        DynamicIslandExpandedRegion(.trailing) {
          Button(intent: ActivityStopIntent()) { Image(systemName: "stop.fill") }
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(context.state.started, style: .timer).monospacedDigit()
        }
      } compactLeading: {
        Image(systemName: "mic.fill").foregroundStyle(.mint)
      } compactTrailing: {
        Image(systemName: context.state.paused ? "pause.fill" : "waveform")
      } minimal: {
        Image(systemName: "mic.fill").foregroundStyle(.mint)
      }
    }
  }
}
