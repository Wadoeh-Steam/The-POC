import Foundation
import FoundationModels

@main
struct BenchmarkCLI {
    static func main() async {
        print("=== Emotion Diary POC — A/B on-device vs server (OpenRouter) ===")
        print("Tasks: \(BenchmarkTask.allCases.map(\.rawValue).joined(separator: ", "))")
        print(BenchmarkService.availabilitySummary())
        do {
            let data = try DummyData.load()
            print("[data] loaded \(data.emotionLogs.count) emotion logs (family \(data.family.name))")

            // ---------- TRANSLATION FEASIBILITY (§2a workaround attempt) ----------
            print("\n========== On-device translation feasibility (id↔en) ==========")
            do {
                let t0 = DispatchTime.now().uptimeNanoseconds
                let translated = try await OnDeviceTranslator.translate(
                    "Halo, ini tes terjemahan.", from: OnDeviceTranslator.indonesian, to: OnDeviceTranslator.english
                )
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                print("[translate id→en] ok (\(String(format: "%.0f", ms))ms): \"\(translated)\"")
            } catch {
                print("[translate id→en] FAILED: \(error)")
            }

            // ---------- ON-DEVICE ----------
            print("\n========== ON-DEVICE (FoundationModels) ==========")
            let probe = await BenchmarkService.runOnce(
                kind: .onDevice, task: .overview, data: data, phase: "warmup", session: nil
            )
            print("[warmup] \(probe.ok ? "ok (model loaded)" : "failed: \(probe.error ?? "?")")")
            let results = await BenchmarkService.runFull(data: data)
            for r in results {
                print(BenchmarkService.format(r))
                if r.ok {
                    print("-------- on-device output [\(r.task.rawValue)/\(r.phase)] --------")
                    print(r.output)
                    print("-------- end --------")
                }
            }

            // ---------- ON-DEVICE + TRANSLATION WORKAROUND (§2a) ----------
            // Confirmed viable 2026-08-16 (PERFORMANCE_COMPARISON.md §8f) —
            // this is what actually makes on_device mode produce Indonesian
            // output, unlike the raw attempt above which always fails.
            print("\n========== ON-DEVICE + translation workaround (§2a) ==========")
            let translatedSession = LanguageModelSession(model: SystemLanguageModel.default)
            for task in BenchmarkTask.allCases {
                let r = await OnDeviceTranslationPipeline.run(task: task, data: data, session: translatedSession)
                if r.ok {
                    print("[onDevice+translate] \(task.rawValue) → total=\(String(format: "%.0f", r.totalMs))ms " +
                        "(generate=\(String(format: "%.0f", r.generateMs))ms translate=\(String(format: "%.0f", r.translateMs))ms)")
                    print("-------- on-device+translate output [\(task.rawValue)] --------")
                    print(r.output)
                    print("-------- end --------")
                } else {
                    print("[onDevice+translate] \(task.rawValue) → FAILED (\(r.error ?? "?"))")
                }
            }

            // ---------- SERVER (OpenRouter — ADR-0010) ----------
            print("\n========== SERVER (OpenRouter) ==========")
            let config = try ServerOpenRouter.defaultConfig()
            let serverModels = ProcessInfo.processInfo.environment["OPENROUTER_MODELS"]?
                .split(separator: ",").map(String.init) ?? [config.model]

            for model in serverModels {
                var config = config
                config.model = model
                print("\n--- model: \(model) ---")
                for task in BenchmarkTask.allCases {
                    let prompt = PromptBuilder.prompt(for: task, data: data)
                    do {
                        let r = try await ServerOpenRouter.generate(task: task, prompt: prompt, config: config)
                        print(ServerOpenRouter.format(r))
                        print("-------- server output [\(task.rawValue)] --------")
                        print(r.output)
                        print("-------- end --------")
                    } catch {
                        print("[openrouter:\(model)] \(task.rawValue) → FAILED (\(error))")
                    }
                }
            }
            print("\n[benchmark] done")
        } catch {
            print("ERROR: \(error)")
        }
    }
}
