import Combine
import SwiftUI

/// Settings → Support & Community → Log Shipper. Our own screen; nothing here is localized.
struct LogShipperConfigView: View {
    let shipper: LogShipper

    @State private var url = ""
    @State private var token = ""
    @State private var enabled = false
    @State private var status = LogShipperStatus()
    /// What is stored right now (Keychain is read once on appear and after every save, not per render).
    @State private var saved = LogShipperConfig()

    private var isDirty: Bool {
        saved.url != url || saved.token != token || saved.enabled != enabled
    }

    var body: some View {
        Form {
            Section(
                header: Text("Server"),
                footer: Text("POST endpoint on t1d-monitor and its Bearer token. Both are kept in the Keychain.")
            ) {
                TextField("https://logs.example.com/api/logs", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                SecureField("Bearer token", text: $token)
            }

            Section(
                footer: Text(
                    "After every loop cycle the new Trio and Dana log lines are sent to the server. " +
                        "Off by default. The loop never waits for this."
                )
            ) {
                Toggle("Send logs", isOn: $enabled)
            }

            Section {
                Button("Save") {
                    let config = LogShipperConfig(enabled: enabled, url: url, token: token)
                    shipper.save(config)
                    saved = config
                }
                .disabled(!isDirty)
                Button("Send now") { shipper.shipNow() }
                    .disabled(isDirty || url.isEmpty || token.isEmpty)
            }

            Section(header: Text("Status")) {
                row("Last attempt", status.lastAttempt.map(time) ?? "—")
                row("Last success", status.lastSuccess.map(time) ?? "—")
                row("Last shipment", status.lastSentBytes > 0 ? "\(bytes(status.lastSentBytes)) compressed" : "—")
                if status.authFailed {
                    row("Paused", "server refused the token")
                } else if let until = status.backoffUntil, until > Date() {
                    row("Backing off until", time(until))
                }
                if let error = status.lastError {
                    row("Last error", error)
                }
            }
        }
        .navigationTitle("Log Shipper")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let config = shipper.config
            saved = config
            url = config.url
            token = config.token
            enabled = config.enabled
            status = shipper.status.value
        }
        .onReceive(shipper.status.receive(on: DispatchQueue.main)) { status = $0 }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    private func bytes(_ count: Int) -> String {
        count >= 1024 ? "\(count / 1024) KB" : "\(count) B"
    }
}
