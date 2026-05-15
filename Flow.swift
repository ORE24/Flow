import AppKit
import Darwin
import Foundation
import Network
import Security

private let appIdentifier = "local.flow"
private let appName = "Flow"
private let selectedTaskIDKey = "selectedTaskID"

private enum FlowTheme {
    static let paperBackground = NSColor(calibratedRed: 0.88, green: 0.84, blue: 0.72, alpha: 0.96)
    static let dropdownBackground = NSColor(calibratedRed: 0.86, green: 0.82, blue: 0.69, alpha: 0.97)
    static let deepWaveBlue = NSColor(calibratedRed: 0.04, green: 0.22, blue: 0.38, alpha: 1.00)
    static let crestBlue = NSColor(calibratedRed: 0.08, green: 0.42, blue: 0.60, alpha: 1.00)
    static let borderBlue = NSColor(calibratedRed: 0.10, green: 0.36, blue: 0.52, alpha: 0.75)
    static let hoverBlue = NSColor(calibratedRed: 0.06, green: 0.32, blue: 0.46, alpha: 0.16)
    static let selectedBlue = NSColor(calibratedRed: 0.06, green: 0.34, blue: 0.50, alpha: 0.22)
}

struct TaskEntry: Equatable {
    let id: String
    let title: String
    let position: String
}

struct AppConfig: Codable {
    var taskList: String
    var fallbackText: String
    var maxVisibleTasks: Int

    enum CodingKeys: String, CodingKey {
        case taskList = "task_list"
        case fallbackText = "fallback_text"
        case maxVisibleTasks = "max_visible_tasks"
    }

    static let defaultValue = AppConfig(
        taskList: "TODAY TASK",
        fallbackText: "Google Tasks 연결 필요",
        maxVisibleTasks: 10
    )

    init(taskList: String, fallbackText: String, maxVisibleTasks: Int) {
        self.taskList = taskList
        self.fallbackText = fallbackText
        self.maxVisibleTasks = max(1, maxVisibleTasks)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig.defaultValue
        taskList = try container.decodeIfPresent(String.self, forKey: .taskList) ?? defaults.taskList
        fallbackText = try container.decodeIfPresent(String.self, forKey: .fallbackText) ?? defaults.fallbackText
        maxVisibleTasks = max(1, try container.decodeIfPresent(Int.self, forKey: .maxVisibleTasks) ?? defaults.maxVisibleTasks)
    }
}

final class AppPaths {
    let appSupportDirectory: URL
    let configURL: URL
    let credentialsURL: URL
    let timeTrackingURL: URL

    init() throws {
        let fileManager = FileManager.default
        let supportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        appSupportDirectory = supportRoot.appendingPathComponent(appName, isDirectory: true)
        configURL = appSupportDirectory.appendingPathComponent("config.json")
        credentialsURL = appSupportDirectory.appendingPathComponent("credentials.json")
        timeTrackingURL = appSupportDirectory.appendingPathComponent("time_tracking.json")

        try fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: configURL.path) {
            let data = try JSONEncoder.pretty.encode(AppConfig.defaultValue)
            try data.write(to: configURL, options: .atomic)
        }
    }

    func loadConfig() throws -> AppConfig {
        let data = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        let normalizedData = try JSONEncoder.pretty.encode(config)
        if normalizedData != data {
            try normalizedData.write(to: configURL, options: .atomic)
        }
        return config
    }
}

struct TimeTrackingData: Codable {
    var totalsByDate: [String: [String: Int]]

    static let empty = TimeTrackingData(totalsByDate: [:])
}

final class TimeTracker {
    private let storageURL: URL
    private var data: TimeTrackingData
    private var activeTaskID: String?
    private var activeStartedAt: Date?
    private var activeDateKey: String

    init(storageURL: URL) {
        self.storageURL = storageURL
        activeDateKey = Self.todayKey()
        if
            let storedData = try? Data(contentsOf: storageURL),
            let decoded = try? JSONDecoder().decode(TimeTrackingData.self, from: storedData)
        {
            data = decoded
        } else if
            let storedData = try? Data(contentsOf: storageURL),
            let legacy = try? JSONDecoder().decode([String: Int].self, from: storedData)
        {
            data = TimeTrackingData(totalsByDate: [activeDateKey: legacy])
            save()
        } else {
            data = .empty
        }
    }

    func start(taskID: String?) {
        commitActiveElapsed(restart: false)
        activeDateKey = Self.todayKey()
        guard let taskID, !taskID.hasPrefix("__") else {
            activeTaskID = nil
            activeStartedAt = nil
            save()
            return
        }
        activeTaskID = taskID
        activeStartedAt = Date()
        save()
    }

    func pause() {
        commitActiveElapsed(restart: false)
    }

    func resume() {
        rolloverIfNeeded()
        guard let activeTaskID, !activeTaskID.hasPrefix("__") else {
            return
        }
        activeStartedAt = Date()
        activeDateKey = Self.todayKey()
        save()
    }

    func togglePaused() {
        isPaused ? resume() : pause()
    }

    var isPaused: Bool {
        activeTaskID != nil && activeStartedAt == nil
    }

    func elapsedSeconds(for taskID: String?) -> Int {
        rolloverIfNeeded()
        guard let taskID, !taskID.hasPrefix("__") else {
            return 0
        }
        let today = Self.todayKey()
        var seconds = data.totalsByDate[today, default: [:]][taskID, default: 0]
        if taskID == activeTaskID, let activeStartedAt {
            seconds += max(0, Int(Date().timeIntervalSince(activeStartedAt)))
        }
        return seconds
    }

    func todayTotalSeconds() -> Int {
        rolloverIfNeeded()
        let today = Self.todayKey()
        var seconds = data.totalsByDate[today, default: [:]].values.reduce(0, +)
        if let activeStartedAt {
            seconds += max(0, Int(Date().timeIntervalSince(activeStartedAt)))
        }
        return seconds
    }

    func adjustActiveTask(byMinutes minutes: Int) {
        rolloverIfNeeded()
        guard let activeTaskID, !activeTaskID.hasPrefix("__") else {
            return
        }
        commitActiveElapsed(restart: true)
        let today = Self.todayKey()
        let adjustedSeconds = data.totalsByDate[today, default: [:]][activeTaskID, default: 0] + minutes * 60
        data.totalsByDate[today, default: [:]][activeTaskID] = max(0, adjustedSeconds)
        save()
    }

    func resetActiveTask() {
        rolloverIfNeeded()
        guard let activeTaskID, !activeTaskID.hasPrefix("__") else {
            return
        }
        data.totalsByDate[Self.todayKey(), default: [:]][activeTaskID] = 0
        activeStartedAt = Date()
        save()
    }

    func commitActiveElapsed(restart: Bool) {
        rolloverIfNeeded()
        guard let activeTaskID, !activeTaskID.hasPrefix("__"), let activeStartedAt else {
            return
        }
        let elapsed = max(0, Int(Date().timeIntervalSince(activeStartedAt)))
        if elapsed > 0 {
            data.totalsByDate[activeDateKey, default: [:]][activeTaskID, default: 0] += elapsed
        }
        self.activeStartedAt = restart ? Date() : nil
        activeDateKey = Self.todayKey()
        save()
    }

    func save() {
        guard let encoded = try? JSONEncoder.pretty.encode(data) else {
            return
        }
        try? encoded.write(to: storageURL, options: .atomic)
    }

    static func format(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        return String(format: "%02d:%02d", hours, minutes)
    }

    private func rolloverIfNeeded() {
        let today = Self.todayKey()
        guard activeDateKey != today else {
            return
        }
        commitActiveElapsedBeforeRollover()
        activeDateKey = today
        activeStartedAt = activeTaskID == nil ? nil : Date()
        save()
    }

    private func commitActiveElapsedBeforeRollover() {
        guard let activeTaskID, !activeTaskID.hasPrefix("__"), let activeStartedAt else {
            return
        }
        let elapsed = max(0, Int(Date().timeIntervalSince(activeStartedAt)))
        if elapsed > 0 {
            data.totalsByDate[activeDateKey, default: [:]][activeTaskID, default: 0] += elapsed
        }
    }

    private static func todayKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

enum AppError: Error {
    case alreadyRunning
    case missingCredentials(URL)
    case invalidCredentials
    case oauth(String)
    case network(String)
    case googleAPI(String)
    case taskListNotFound(String, [String])
    case decoding(String)

    var userMessage: String {
        switch self {
        case .alreadyRunning:
            return "이미 실행 중"
        case .missingCredentials:
            return "credentials.json 없음"
        case .invalidCredentials:
            return "credentials.json 형식 오류"
        case .oauth:
            return "Google 인증 실패"
        case .network:
            return "네트워크 오류"
        case .googleAPI:
            return "Tasks API 오류"
        case .taskListNotFound:
            return "목록 이름 확인 필요"
        case .decoding:
            return "응답 해석 실패"
        }
    }

    var detail: String {
        switch self {
        case .alreadyRunning:
            return "Flow is already running."
        case .missingCredentials(let url):
            return "Missing OAuth credentials at \(url.path)"
        case .invalidCredentials:
            return "credentials.json must be a Google OAuth Desktop client JSON file."
        case .oauth(let message), .network(let message), .googleAPI(let message), .decoding(let message):
            return message
        case .taskListNotFound(let list, let available):
            return "Task list '\(list)' was not found. Available lists: \(available.joined(separator: ", "))"
        }
    }
}

final class SingleInstanceLock {
    private let fileDescriptor: Int32

    init(lockURL: URL) throws {
        fileDescriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            throw AppError.network("Unable to create lock file: \(lockURL.path)")
        }
        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(fileDescriptor)
            throw AppError.alreadyRunning
        }
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}

struct OAuthClient: Decodable {
    let clientID: String
    let clientSecret: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
    }
}

struct GoogleCredentials: Decodable {
    let installed: OAuthClient?
    let web: OAuthClient?

    var client: OAuthClient? {
        installed ?? web
    }
}

struct OAuthToken: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }

    var isUsable: Bool {
        Date().timeIntervalSince1970 < expiresAt - 90
    }
}

struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

final class KeychainTokenStore {
    private let service = appIdentifier
    private let account = "google-oauth-token"

    func load() -> OAuthToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(OAuthToken.self, from: data)
    }

    func save(_ token: OAuthToken) throws {
        let data = try JSONEncoder().encode(token)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw AppError.oauth("Unable to update Keychain token: \(updateStatus)")
        }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AppError.oauth("Unable to save Keychain token: \(addStatus)")
        }
    }
}

final class OAuthRedirectServer {
    private let queue = DispatchQueue(label: "Flow.OAuthRedirect")
    private var listener: NWListener?
    private var result: Result<String, Error>?
    private let ready = DispatchSemaphore(value: 0)
    private let completed = DispatchSemaphore(value: 0)

    func start() throws -> String {
        listener = try NWListener(using: .tcp, on: 0)
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready.signal()
            case .failed(let error):
                self.result = .failure(AppError.oauth("OAuth redirect server failed: \(error.localizedDescription)"))
                self.ready.signal()
                self.completed.signal()
            default:
                break
            }
        }
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener?.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success, let port = listener?.port else {
            throw AppError.oauth("OAuth redirect server did not start.")
        }
        return "http://127.0.0.1:\(port.rawValue)/oauth2redirect"
    }

    func waitForCode(timeout: TimeInterval = 180) throws -> String {
        guard completed.wait(timeout: .now() + timeout) == .success else {
            listener?.cancel()
            throw AppError.oauth("Google login timed out.")
        }
        switch result {
        case .success(let code):
            return code
        case .failure(let error):
            throw error
        case .none:
            throw AppError.oauth("No OAuth result was received.")
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if let code = Self.extractCode(from: request) {
                self.result = .success(code)
                self.sendResponse("인증이 완료되었습니다. 이 창을 닫아도 됩니다.", on: connection)
            } else {
                self.result = .failure(AppError.oauth("OAuth redirect did not contain a code."))
                self.sendResponse("인증 코드를 읽지 못했습니다. 앱을 다시 실행해 주세요.", on: connection)
            }
        }
    }

    private func sendResponse(_ body: String, on connection: NWConnection) {
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Connection: close\r
        \r
        <!doctype html><html><body style="font-family: -apple-system; padding: 32px;">\(body)</body></html>
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.listener?.cancel()
            self?.completed.signal()
        })
    }

    private static func extractCode(from request: String) -> String? {
        guard let firstLine = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first else {
            return nil
        }
        let pieces = firstLine.split(separator: " ")
        guard pieces.count >= 2 else { return nil }
        let path = String(pieces[1])
        guard let url = URL(string: "http://127.0.0.1\(path)") else {
            return nil
        }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "code" })?
            .value
    }
}

struct TaskListResponse: Decodable {
    let items: [TaskListItem]?
}

struct TaskListItem: Decodable {
    let id: String
    let title: String
}

struct GoogleTasksResponse: Decodable {
    let items: [GoogleTaskItem]?
}

struct GoogleTaskItem: Decodable {
    let id: String
    let title: String?
    let position: String?
}

struct GoogleErrorEnvelope: Decodable {
    struct GoogleError: Decodable {
        let message: String?
        let status: String?
        let code: Int?
    }

    let error: GoogleError
}

final class GoogleTasksClient {
    private let paths: AppPaths
    private let config: AppConfig
    private let tokenStore = KeychainTokenStore()

    init(paths: AppPaths, config: AppConfig) {
        self.paths = paths
        self.config = config
    }

    func fetchTasks() throws -> [TaskEntry] {
        let token = try accessToken()
        var listsRequest = URLRequest(url: URL(string: "https://tasks.googleapis.com/tasks/v1/users/@me/lists?maxResults=100")!)
        listsRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let listsData = try perform(listsRequest)
        let lists = try decode(TaskListResponse.self, from: listsData).items ?? []
        guard let selectedList = lists.first(where: { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == config.taskList }) else {
            throw AppError.taskListNotFound(config.taskList, lists.map(\.title))
        }

        let tasksBaseURL = URL(string: "https://tasks.googleapis.com/tasks/v1/lists")!
            .appendingPathComponent(selectedList.id)
            .appendingPathComponent("tasks")
        guard var components = URLComponents(url: tasksBaseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.network("Could not build tasks URL.")
        }
        components.queryItems = [
            URLQueryItem(name: "showCompleted", value: "false"),
            URLQueryItem(name: "showDeleted", value: "false"),
            URLQueryItem(name: "showHidden", value: "false"),
            URLQueryItem(name: "maxResults", value: "100"),
        ]
        guard let tasksURL = components.url else {
            throw AppError.network("Could not build tasks URL.")
        }
        var tasksRequest = URLRequest(url: tasksURL)
        tasksRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let tasksData = try perform(tasksRequest)
        let items = try decode(GoogleTasksResponse.self, from: tasksData).items ?? []
        return items
            .compactMap { item -> TaskEntry? in
                guard let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                    return nil
                }
                return TaskEntry(id: item.id, title: title, position: item.position ?? "")
            }
            .sorted { $0.position < $1.position }
    }

    private func accessToken() throws -> String {
        if let token = tokenStore.load(), token.isUsable {
            return token.accessToken
        }
        if let token = tokenStore.load(), let refreshToken = token.refreshToken {
            return try refreshAccessToken(refreshToken: refreshToken).accessToken
        }
        return try authorize().accessToken
    }

    private func authorize() throws -> OAuthToken {
        let client = try loadCredentials()
        let redirectServer = OAuthRedirectServer()
        let redirectURI = try redirectServer.start()

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/tasks.readonly"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let authURL = components.url else {
            throw AppError.oauth("Could not build Google OAuth URL.")
        }
        NSWorkspace.shared.open(authURL)

        let code = try redirectServer.waitForCode()
        let token = try exchangeCode(code, redirectURI: redirectURI, client: client)
        try tokenStore.save(token)
        return token
    }

    private func refreshAccessToken(refreshToken: String) throws -> OAuthToken {
        let client = try loadCredentials()
        let body = formEncoded([
            "client_id": client.clientID,
            "client_secret": client.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data = try perform(request)
        let response = try decode(TokenResponse.self, from: data)
        let token = OAuthToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? refreshToken,
            expiresAt: Date().timeIntervalSince1970 + TimeInterval(response.expiresIn)
        )
        try tokenStore.save(token)
        return token
    }

    private func exchangeCode(_ code: String, redirectURI: String, client: OAuthClient) throws -> OAuthToken {
        let body = formEncoded([
            "client_id": client.clientID,
            "client_secret": client.clientSecret,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ])
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data = try perform(request)
        let response = try decode(TokenResponse.self, from: data)
        return OAuthToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: Date().timeIntervalSince1970 + TimeInterval(response.expiresIn)
        )
    }

    private func loadCredentials() throws -> OAuthClient {
        guard FileManager.default.fileExists(atPath: paths.credentialsURL.path) else {
            throw AppError.missingCredentials(paths.credentialsURL)
        }
        do {
            let data = try Data(contentsOf: paths.credentialsURL)
            guard let client = try JSONDecoder().decode(GoogleCredentials.self, from: data).client else {
                throw AppError.invalidCredentials
            }
            return client
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.invalidCredentials
        }
    }

    private func perform(_ request: URLRequest) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(Data, HTTPURLResponse), Error>?
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(AppError.network(error.localizedDescription))
            } else if let httpResponse = response as? HTTPURLResponse, let data {
                result = .success((data, httpResponse))
            } else {
                result = .failure(AppError.network("No HTTP response."))
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()

        let (data, response) = try result?.get() ?? {
            throw AppError.network("No request result.")
        }()
        guard 200..<300 ~= response.statusCode else {
            let message = (try? JSONDecoder().decode(GoogleErrorEnvelope.self, from: data).error.message)
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(response.statusCode)"
            throw AppError.googleAPI(message)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AppError.decoding(error.localizedDescription)
        }
    }

    private func formEncoded(_ values: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        let body = values
            .map { key, value in
                let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(escapedKey)=\(escapedValue)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}

final class OverlayView: NSView {
    private let label = NSTextField(labelWithString: "Loading...")
    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = FlowTheme.paperBackground.cgColor
        layer?.borderColor = FlowTheme.borderBlue.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 7
        layer?.masksToBounds = true

        label.font = NSFont.boldSystemFont(ofSize: 16)
        label.textColor = FlowTheme.deepWaveBlue
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setText(_ text: String) {
        label.stringValue = text
        let font = label.font ?? NSFont.boldSystemFont(ofSize: 16)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: 560, height: 28),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        frame.size = NSSize(width: min(max(ceil(rect.width) + 28, 96), 560), height: 28)
    }

    override func mouseDown(with event: NSEvent) {
        onLeftClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

protocol DropdownViewDelegate: AnyObject {
    func dropdownView(_ dropdownView: DropdownView, didSelectTaskAt index: Int)
    func dropdownView(_ dropdownView: DropdownView, didAdjustActiveTaskByMinutes minutes: Int)
    func dropdownViewDidTogglePause(_ dropdownView: DropdownView)
    func dropdownViewDidResetActiveTaskTime(_ dropdownView: DropdownView)
    func dropdownViewDidRequestClose(_ dropdownView: DropdownView)
}

final class TaskRowButton: NSButton {
    let taskIndex: Int
    private let selected: Bool
    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false

    init(title: String, index: Int, selected: Bool, target: AnyObject?, action: Selector?) {
        taskIndex = index
        self.selected = selected
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        alignment = .left
        wantsLayer = true
        layer?.cornerRadius = 5
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        applyTitle(title, selected: selected)
        updateBackground()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateBackground()
    }

    private func applyTitle(_ title: String, selected: Bool) {
        let displayTitle = selected ? "✓ \(title)" : title
        attributedTitle = NSAttributedString(
            string: displayTitle,
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 15),
                .foregroundColor: selected ? FlowTheme.crestBlue : FlowTheme.deepWaveBlue,
            ]
        )
    }

    private func updateBackground() {
        layer?.backgroundColor = isHovering
            ? FlowTheme.hoverBlue.cgColor
            : selected ? FlowTheme.selectedBlue.cgColor : NSColor.clear.cgColor
    }
}

final class TimeAdjustButton: NSButton {
    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = FlowTheme.selectedBlue.cgColor
        setButtonType(.momentaryChange)
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: FlowTheme.deepWaveBlue,
            ]
        )
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class DropdownView: NSView {
    private let timeControlsView = NSStackView()
    private let timeLabel = NSTextField(labelWithString: "Time 00:00")
    private let pauseButton = TimeAdjustButton(title: "Pause", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private(set) var preferredSize = NSSize(width: 220, height: 44)
    private var maxVisibleTasks = 10
    weak var delegate: DropdownViewDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = FlowTheme.dropdownBackground.cgColor
        layer?.borderColor = FlowTheme.borderBlue.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        timeLabel.font = NSFont.boldSystemFont(ofSize: 13)
        timeLabel.textColor = FlowTheme.deepWaveBlue
        timeLabel.alignment = .left
        timeLabel.lineBreakMode = .byTruncatingTail
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        timeControlsView.orientation = .horizontal
        timeControlsView.alignment = .centerY
        timeControlsView.distribution = .fill
        timeControlsView.spacing = 6
        timeControlsView.translatesAutoresizingMaskIntoConstraints = false

        let minusButton = TimeAdjustButton(title: "-10m", target: self, action: #selector(minusTenMinutes))
        let plusTenButton = TimeAdjustButton(title: "+10m", target: self, action: #selector(plusTenMinutes))
        let plusThirtyButton = TimeAdjustButton(title: "+30m", target: self, action: #selector(plusThirtyMinutes))
        let resetButton = TimeAdjustButton(title: "Reset", target: self, action: #selector(resetTime))
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        [pauseButton, minusButton, plusTenButton, plusThirtyButton, resetButton].forEach { button in
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }

        timeControlsView.addArrangedSubview(timeLabel)
        timeControlsView.addArrangedSubview(pauseButton)
        timeControlsView.addArrangedSubview(minusButton)
        timeControlsView.addArrangedSubview(plusTenButton)
        timeControlsView.addArrangedSubview(plusThirtyButton)
        timeControlsView.addArrangedSubview(resetButton)
        addSubview(timeControlsView)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.distribution = .fill
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stackView
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            timeControlsView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            timeControlsView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            timeControlsView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            timeControlsView.heightAnchor.constraint(equalToConstant: 24),
            timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 74),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: timeControlsView.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTasks(_ tasks: [TaskEntry], selectedID: String?, selectedElapsedSeconds: Int, todayTotalSeconds: Int, isPaused: Bool, maxVisibleTasks: Int) {
        self.maxVisibleTasks = max(1, maxVisibleTasks)
        timeLabel.stringValue = "Today \(TimeTracker.format(seconds: todayTotalSeconds)) / 24:00 · Task \(TimeTracker.format(seconds: selectedElapsedSeconds))"
        pauseButton.attributedTitle = NSAttributedString(
            string: isPaused ? "Resume" : "Pause",
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: FlowTheme.deepWaveBlue,
            ]
        )
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let rowHeight: CGFloat = 28
        let rowSpacing: CGFloat = 2
        let horizontalPadding: CGFloat = 20
        let verticalPadding: CGFloat = 54

        for (index, task) in tasks.enumerated() {
            let isSelected = task.id == selectedID
            let button = TaskRowButton(title: task.title, index: index, selected: isSelected, target: self, action: #selector(selectTask(_:)))
            stackView.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
        }

        let text = tasks
            .map { task in task.id == selectedID ? "✓ \(task.title)" : task.title }
            .joined(separator: "\n") as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 15)]
        let rect = text.boundingRect(
            with: NSSize(width: 320, height: 600),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let rowCount = CGFloat(max(tasks.count, 1))
        let visibleRowCount = CGFloat(min(max(tasks.count, 1), self.maxVisibleTasks))
        let visibleSpacing = rowSpacing * CGFloat(max(min(tasks.count, self.maxVisibleTasks) - 1, 0))
        let documentSpacing = rowSpacing * CGFloat(max(tasks.count - 1, 0))
        let documentHeight = verticalPadding + rowHeight * rowCount + documentSpacing
        preferredSize = NSSize(
            width: min(max(ceil(rect.width) + horizontalPadding, 380), 520),
            height: verticalPadding + rowHeight * visibleRowCount + visibleSpacing
        )
        let documentSize = NSSize(width: preferredSize.width - horizontalPadding, height: documentHeight - verticalPadding)
        stackView.frame = NSRect(origin: .zero, size: documentSize)
        scrollView.documentView?.setFrameSize(documentSize)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        setFrameSize(preferredSize)
        layoutSubtreeIfNeeded()
    }

    @objc private func selectTask(_ sender: TaskRowButton) {
        delegate?.dropdownView(self, didSelectTaskAt: sender.taskIndex)
    }

    @objc private func minusTenMinutes() {
        delegate?.dropdownView(self, didAdjustActiveTaskByMinutes: -10)
    }

    @objc private func togglePause() {
        delegate?.dropdownViewDidTogglePause(self)
    }

    @objc private func plusTenMinutes() {
        delegate?.dropdownView(self, didAdjustActiveTaskByMinutes: 10)
    }

    @objc private func plusThirtyMinutes() {
        delegate?.dropdownView(self, didAdjustActiveTaskByMinutes: 30)
    }

    @objc private func resetTime() {
        delegate?.dropdownViewDidResetActiveTaskTime(self)
    }

    override func rightMouseDown(with event: NSEvent) {
        delegate?.dropdownViewDidRequestClose(self)
    }
}

final class ScreenOverlay {
    let screen: NSScreen
    let panel: NSPanel
    let dropdownPanel: NSPanel
    let overlayView: OverlayView
    let dropdownView: DropdownView
    var dropdownVisible = false
    var onToggle: (() -> Void)?
    var onQuit: (() -> Void)?

    init(screen: NSScreen, delegate: DropdownViewDelegate) {
        self.screen = screen
        overlayView = OverlayView(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
        dropdownView = DropdownView(frame: NSRect(x: 0, y: 0, width: 220, height: 120))
        dropdownView.delegate = delegate

        panel = NSPanel(
            contentRect: overlayView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = overlayView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false

        dropdownPanel = NSPanel(
            contentRect: dropdownView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        dropdownPanel.contentView = dropdownView
        dropdownPanel.backgroundColor = .clear
        dropdownPanel.isOpaque = false
        dropdownPanel.hasShadow = true
        dropdownPanel.level = .screenSaver
        dropdownPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        dropdownPanel.ignoresMouseEvents = false
        dropdownPanel.isMovableByWindowBackground = false

        overlayView.onLeftClick = { [weak self] in self?.onToggle?() }
        overlayView.onRightClick = { [weak self] in self?.onQuit?() }
        repositionPanel()
        panel.orderFrontRegardless()
    }

    func updateTitle(_ title: String) {
        overlayView.setText(title)
        repositionPanel()
        repositionDropdown()
        panel.orderFrontRegardless()
        if dropdownVisible {
            dropdownPanel.orderFrontRegardless()
        }
    }

    func updateTasks(_ tasks: [TaskEntry], selectedID: String?, selectedElapsedSeconds: Int, todayTotalSeconds: Int, isPaused: Bool, maxVisibleTasks: Int) {
        dropdownView.setTasks(
            tasks,
            selectedID: selectedID,
            selectedElapsedSeconds: selectedElapsedSeconds,
            todayTotalSeconds: todayTotalSeconds,
            isPaused: isPaused,
            maxVisibleTasks: maxVisibleTasks
        )
        repositionDropdown()
    }

    func showDropdown() {
        dropdownVisible = true
        repositionDropdown()
        dropdownPanel.orderFrontRegardless()
    }

    func hideDropdown() {
        dropdownVisible = false
        dropdownPanel.orderOut(nil)
    }

    func close() {
        dropdownPanel.close()
        panel.close()
    }

    private func repositionPanel() {
        let size = overlayView.frame.size
        let placement = topPlacement(for: size)
        panel.setFrame(placement, display: true)
    }

    private func repositionDropdown() {
        let panelFrame = panel.frame
        let size = dropdownView.preferredSize
        dropdownView.setFrameSize(size)
        let screenFrame = screen.frame
        let margin: CGFloat = 6
        let x = clamp(panelFrame.midX - size.width / 2, min: screenFrame.minX + margin, max: screenFrame.maxX - size.width - margin)
        let y = panelFrame.minY - size.height - margin
        dropdownPanel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func topPlacement(for size: NSSize) -> NSRect {
        let screenFrame = screen.frame

        if #available(macOS 12.0, *) {
            let auxiliaryAreas = [screen.auxiliaryTopRightArea, screen.auxiliaryTopLeftArea]
                .compactMap { $0 }
                .filter { !$0.isEmpty && $0.width > 40 }
            if !auxiliaryAreas.isEmpty {
                let notchClearance = max(screen.safeAreaInsets.top, 30)
                let x = screenFrame.midX - size.width / 2
                let y = screenFrame.maxY - notchClearance - size.height
                return NSRect(x: x, y: y, width: size.width, height: size.height)
            }
        }

        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        guard maxValue >= minValue else { return minValue }
        return Swift.max(minValue, Swift.min(value, maxValue))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, DropdownViewDelegate {
    private var overlays: [ScreenOverlay] = []
    private var localKeyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var trackingTimer: Timer?
    private var singleInstanceLock: SingleInstanceLock?
    private var paths: AppPaths?
    private var config = AppConfig.defaultValue
    private var tasksClient: GoogleTasksClient?
    private var timeTracker: TimeTracker?
    private var tasks: [TaskEntry] = []
    private var selectedTaskID: String?
    private var dropdownVisible = false
    private var ignoreGlobalMouseEventsUntil: Date?
    private var lastTrackingAutosave = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        createOverlays()
        selectedTaskID = UserDefaults.standard.string(forKey: selectedTaskIDKey)

        do {
            let paths = try AppPaths()
            self.paths = paths
            singleInstanceLock = try SingleInstanceLock(lockURL: paths.appSupportDirectory.appendingPathComponent("Flow.lock"))
            config = try paths.loadConfig()
            tasksClient = GoogleTasksClient(paths: paths, config: config)
            timeTracker = TimeTracker(storageURL: paths.timeTrackingURL)
        } catch AppError.alreadyRunning {
            NSApp.terminate(nil)
            return
        } catch let error as AppError {
            updateStatus(error.userMessage)
            print(error.detail)
            return
        } catch {
            updateStatus("초기화 실패")
            print(error.localizedDescription)
            return
        }

        updateStatus("불러오는 중")
        refreshTask()
        startTrackingTimer()

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 {
                NSApp.terminate(nil)
                return nil
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hideDropdownFromGlobalMouse()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        timeTracker?.commitActiveElapsed(restart: false)
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        trackingTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func createOverlays() {
        overlays = NSScreen.screens.map { screen in
            let overlay = ScreenOverlay(screen: screen, delegate: self)
            overlay.onToggle = { [weak self, weak overlay] in
                guard let overlay else { return }
                self?.toggleDropdown(for: overlay)
            }
            overlay.onQuit = { NSApp.terminate(nil) }
            return overlay
        }
    }

    @objc private func screenParametersChanged() {
        let title = selectedTitle()
        overlays.forEach { $0.close() }
        createOverlays()
        overlays.forEach { overlay in
            overlay.updateTitle(title)
            overlay.updateTasks(
                tasks,
                selectedID: selectedTaskID,
                selectedElapsedSeconds: selectedElapsedSeconds(),
                todayTotalSeconds: todayTotalSeconds(),
                isPaused: isTrackingPaused(),
                maxVisibleTasks: config.maxVisibleTasks
            )
        }
    }

    private func updateStatus(_ text: String) {
        updateTasks([TaskEntry(id: "__status__", title: text, position: "")])
    }

    private func saveSelectedTaskID(_ id: String?) {
        guard let id, !id.hasPrefix("__") else {
            UserDefaults.standard.removeObject(forKey: selectedTaskIDKey)
            return
        }
        UserDefaults.standard.set(id, forKey: selectedTaskIDKey)
    }

    private func updateTasks(_ tasks: [TaskEntry]) {
        DispatchQueue.main.async {
            self.tasks = tasks.isEmpty ? [TaskEntry(id: "__empty__", title: "지금 표시할 task가 없어요", position: "")] : tasks
            if let selectedTaskID = self.selectedTaskID, self.tasks.contains(where: { $0.id == selectedTaskID }) {
                let selected = self.tasks.first { $0.id == selectedTaskID }!
                self.timeTracker?.start(taskID: selected.id)
                self.overlays.forEach { $0.updateTitle(self.displayTitle(for: selected)) }
            } else {
                self.selectedTaskID = self.tasks[0].id
                self.saveSelectedTaskID(self.selectedTaskID)
                self.timeTracker?.start(taskID: self.selectedTaskID)
                self.overlays.forEach { $0.updateTitle(self.displayTitle(for: self.tasks[0])) }
            }
            self.updateDropdowns()
        }
    }

    func dropdownView(_ dropdownView: DropdownView, didSelectTaskAt index: Int) {
        guard tasks.indices.contains(index) else { return }
        selectedTaskID = tasks[index].id
        saveSelectedTaskID(selectedTaskID)
        timeTracker?.start(taskID: selectedTaskID)
        overlays.forEach { overlay in
            overlay.updateTitle(displayTitle(for: tasks[index]))
        }
        updateDropdowns()
        hideDropdown()
    }

    func dropdownView(_ dropdownView: DropdownView, didAdjustActiveTaskByMinutes minutes: Int) {
        timeTracker?.adjustActiveTask(byMinutes: minutes)
        refreshDisplayedTime()
    }

    func dropdownViewDidTogglePause(_ dropdownView: DropdownView) {
        timeTracker?.togglePaused()
        refreshDisplayedTime()
    }

    func dropdownViewDidResetActiveTaskTime(_ dropdownView: DropdownView) {
        timeTracker?.resetActiveTask()
        refreshDisplayedTime()
    }

    func dropdownViewDidRequestClose(_ dropdownView: DropdownView) {
        NSApp.terminate(nil)
    }

    private func toggleDropdown(for overlay: ScreenOverlay) {
        DispatchQueue.main.async {
            let shouldShow = !overlay.dropdownVisible
            self.hideAllDropdowns()
            if shouldShow {
                self.ignoreGlobalMouseEventsUntil = Date().addingTimeInterval(0.25)
                overlay.showDropdown()
                self.refreshTask()
            }
        }
    }

    private func hideDropdown() {
        DispatchQueue.main.async {
            self.hideAllDropdowns()
        }
    }

    private func hideDropdownFromGlobalMouse() {
        DispatchQueue.main.async {
            if let ignoreUntil = self.ignoreGlobalMouseEventsUntil, Date() < ignoreUntil {
                return
            }
            self.hideAllDropdowns()
        }
    }

    private func hideAllDropdowns() {
        overlays.forEach { $0.hideDropdown() }
    }

    private func selectedTitle() -> String {
        if let selectedTaskID, let selected = tasks.first(where: { $0.id == selectedTaskID }) {
            return displayTitle(for: selected)
        }
        return tasks.first?.title ?? config.fallbackText
    }

    private func selectedElapsedSeconds() -> Int {
        timeTracker?.elapsedSeconds(for: selectedTaskID) ?? 0
    }

    private func todayTotalSeconds() -> Int {
        timeTracker?.todayTotalSeconds() ?? 0
    }

    private func isTrackingPaused() -> Bool {
        timeTracker?.isPaused ?? false
    }

    private func displayTitle(for task: TaskEntry) -> String {
        guard !task.id.hasPrefix("__") else {
            return task.title
        }
        let suffix = isTrackingPaused() && task.id == selectedTaskID ? " Paused" : ""
        return "\(task.title) \(TimeTracker.format(seconds: timeTracker?.elapsedSeconds(for: task.id) ?? 0))\(suffix)"
    }

    private func updateDropdowns() {
        overlays.forEach {
            $0.updateTasks(
                tasks,
                selectedID: selectedTaskID,
                selectedElapsedSeconds: selectedElapsedSeconds(),
                todayTotalSeconds: todayTotalSeconds(),
                isPaused: isTrackingPaused(),
                maxVisibleTasks: config.maxVisibleTasks
            )
        }
    }

    private func refreshDisplayedTime() {
        guard let selectedTaskID, let selected = tasks.first(where: { $0.id == selectedTaskID }) else {
            return
        }
        overlays.forEach { $0.updateTitle(displayTitle(for: selected)) }
        updateDropdowns()
    }

    private func startTrackingTimer() {
        trackingTimer?.invalidate()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshDisplayedTime()
            if Date().timeIntervalSince(self.lastTrackingAutosave) >= 60 {
                self.timeTracker?.commitActiveElapsed(restart: true)
                self.lastTrackingAutosave = Date()
            }
        }
    }

    private func refreshTask() {
        guard let tasksClient else {
            updateStatus(config.fallbackText)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            do {
                let tasks = try tasksClient.fetchTasks()
                self.updateTasks(tasks)
            } catch let error as AppError {
                print(error.detail)
                self.updateStatus(error.userMessage)
            } catch {
                print(error.localizedDescription)
                self.updateStatus("알 수 없는 오류")
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
