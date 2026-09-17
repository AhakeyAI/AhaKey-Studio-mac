import Foundation

@MainActor
final class CloudAccountManager: ObservableObject {
    static let shared = CloudAccountManager()

    @Published var phone = ""
    @Published var password = ""
    @Published var rememberPassword = false
    @Published var couponCode = ""
    @Published private(set) var isLoggedIn = false
    @Published private(set) var isBusy = false
    @Published private(set) var profile: [String: Any]?
    @Published private(set) var paymentOrder: CloudPaymentOrder?
    @Published private(set) var statusMessage = String(localized: "text.783b3c9bcf5a", defaultValue: "尚未登录。")
    @Published var alertMessage: String?

    private let fallbackAPIBase = "https://956798.xyz/prod-api"
    private let tokenKey = "lab.jawa.ahakeyconfig.cloud.accessToken"
    private let rememberKey = "lab.jawa.ahakeyconfig.cloud.remember"
    private let phoneKey = "lab.jawa.ahakeyconfig.cloud.phone"
    private let passwordKey = "lab.jawa.ahakeyconfig.cloud.password"

    private init() {
        let defaults = UserDefaults.standard
        rememberPassword = defaults.bool(forKey: rememberKey)
        phone = defaults.string(forKey: phoneKey) ?? ""
        if rememberPassword {
            password = defaults.string(forKey: passwordKey) ?? ""
        }
        isLoggedIn = !accessToken.isEmpty
        if isLoggedIn {
            statusMessage = String(localized: "text.29a27bf6d68a", defaultValue: "已登录，等待刷新用户信息。")
        }
    }

    func login() {
        authenticate(path: "api/v1/auth/login", successMessage: String(localized: "text.ba9a21fb737c", defaultValue: "登录成功。"), fallbackError: String(localized: "text.1df8b73b7735", defaultValue: "登录失败。"))
    }

    func register() {
        authenticate(path: "api/v1/auth/register", successMessage: String(localized: "text.d0d387a98206", defaultValue: "注册成功。"), fallbackError: String(localized: "text.30d3aab35fea", defaultValue: "注册失败。"))
    }

    func logout() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
        AhaTypeTextOptimizer.shared.clearSessionKeepToggle()
        profile = nil
        isLoggedIn = false
        statusMessage = String(localized: "text.5a6ab4b41b81", defaultValue: "已退出登录。")
    }

    func prepareForRelogin() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
        profile = nil
        isLoggedIn = false
        statusMessage = String(localized: "text.898dcb1f1941", defaultValue: "请输入账号密码重新登录。")
    }

    func refreshProfile(showAlertOnFailure: Bool = true) {
        guard !accessToken.isEmpty else {
            logout()
            return
        }
        isBusy = true
        statusMessage = String(localized: "text.adb1cd54904f", defaultValue: "正在刷新用户信息…")
        Task {
            defer { Task { @MainActor in self.isBusy = false } }
            do {
                let object = try await request(path: "api/v1/auth/users/me", method: "GET", body: nil, authorized: true)
                let data = try payloadData(from: object, fallbackError: String(localized: "text.2339340aba36", defaultValue: "获取用户信息失败"))
                await MainActor.run {
                    self.applyProfile(data)
                    self.statusMessage = String(localized: "text.1f58c8eb25bc", defaultValue: "用户信息已刷新。")
                }
            } catch {
                await MainActor.run {
                    if showAlertOnFailure {
                        self.alertMessage = error.localizedDescription
                        self.statusMessage = String(localized: "text.682511428150", defaultValue: "刷新失败。")
                    } else {
                        self.statusMessage = String(localized: "text.0cf522beec6b", defaultValue: "已登录，用户信息稍后可刷新。")
                    }
                    if showAlertOnFailure, (error as? CloudAccountError)?.statusCode == 401 {
                        self.logout()
                    }
                }
            }
        }
    }

    func redeemCoupon() {
        let code = couponCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            alertMessage = String(localized: "text.4a295dcdba3f", defaultValue: "请输入兑换码。")
            return
        }
        isBusy = true
        statusMessage = String(localized: "text.9c2ec3b0f9de", defaultValue: "正在兑换免费券…")
        Task {
            defer { Task { @MainActor in self.isBusy = false } }
            do {
                let object = try await request(path: "api/v1/coupon/redeem", method: "POST", body: ["code": code], authorized: true)
                let data = try payloadData(from: object, fallbackError: String(localized: "text.78f68d914e07", defaultValue: "兑换失败"))
                await MainActor.run {
                    self.couponCode = ""
                    self.applyProfile(data)
                    self.statusMessage = String(localized: "text.71f7ea5e37d0", defaultValue: "兑换成功。")
                    self.alertMessage = String(localized: "text.18dba4283ba8", defaultValue: "免费券已生效。")
                }
            } catch {
                await MainActor.run {
                    self.alertMessage = error.localizedDescription
                    self.statusMessage = String(localized: "text.f217d5539f6d", defaultValue: "兑换失败。")
                }
            }
        }
    }

    func createWechatOrder(plan: CloudRechargePlan) {
        guard isLoggedIn else {
            alertMessage = String(localized: "text.c285e04d5f20", defaultValue: "请先登录后再充值。")
            return
        }
        isBusy = true
        statusMessage = String(localized: "text.20a485b0e3ad", defaultValue: "正在创建微信支付订单…")
        Task {
            defer { Task { @MainActor in self.isBusy = false } }
            do {
                let object = try await request(
                    path: "api/v1/payment/wechat/native",
                    method: "POST",
                    body: ["plan": plan.rawValue, "description": plan.orderDescription],
                    authorized: true
                )
                let data = try payloadData(from: object, fallbackError: String(localized: "text.7902df663f83", defaultValue: "创建支付订单失败"))
                let codeURL = firstString(in: data, keys: ["code_url", "codeUrl"])
                let h5URL = firstString(in: data, keys: ["h5_url", "h5Url", "mweb_url", "mwebUrl"])
                let outTradeNo = firstString(in: data, keys: ["out_trade_no", "outTradeNo"])
                guard !outTradeNo.isEmpty else { throw CloudAccountError(String(localized: "text.34c2422db3ba", defaultValue: "云端未返回订单号，无法查询支付状态。")) }
                guard !codeURL.isEmpty || !h5URL.isEmpty else { throw CloudAccountError(String(localized: "text.a5b6a849871b", defaultValue: "云端未返回可支付链接。")) }
                let amountFen = firstInt(in: data, keys: ["amount_fen", "amountFen"])
                await MainActor.run {
                    self.paymentOrder = CloudPaymentOrder(
                        plan: plan,
                        amountFen: amountFen,
                        outTradeNo: outTradeNo,
                        codeURL: codeURL,
                        h5URL: h5URL,
                        status: "pending"
                    )
                    self.statusMessage = String(localized: "text.4131e082060c", defaultValue: "订单已创建，请使用微信扫码支付。")
                    self.pollPaymentStatus(outTradeNo: outTradeNo)
                }
            } catch {
                await MainActor.run {
                    self.alertMessage = error.localizedDescription
                    self.statusMessage = String(localized: "text.a356b9b9c384", defaultValue: "创建支付订单失败。")
                }
            }
        }
    }

    func clearPaymentOrder() {
        paymentOrder = nil
        statusMessage = String(localized: "text.e680b29491e0", defaultValue: "已关闭支付订单。")
    }

    func refreshCurrentPaymentOrder() {
        guard let order = paymentOrder else {
            refreshProfile()
            return
        }
        isBusy = true
        statusMessage = String(localized: "text.28b787d6f8f9", defaultValue: "正在查询订单状态…")
        Task {
            defer { Task { @MainActor in self.isBusy = false } }
            do {
                let status = try await fetchPaymentStatus(outTradeNo: order.outTradeNo)
                await MainActor.run {
                    _ = self.applyPaymentStatus(status, outTradeNo: order.outTradeNo, notifyPending: true)
                }
            } catch {
                await MainActor.run {
                    self.alertMessage = error.localizedDescription
                    self.statusMessage = String(localized: "text.e58bd97210e2", defaultValue: "订单状态查询失败。")
                }
            }
        }
    }

    var profileSummary: String {
        guard let profile else { return isLoggedIn ? String(localized: "text.5a94bf18de3c", defaultValue: "已登录，点击刷新获取用户信息。") : String(localized: "text.cdcaf685cf61", defaultValue: "登录后可启用 AhaType 云端整理。") }
        let phone = stringValue(profile["phone"])
        let validUntil = stringValue(profile["token_valid_until"])
        return [
            phone.isEmpty ? "" : String(localized: "text.5f6f7d637159", defaultValue: "手机号：\(String(describing: phone))"),
            validUntil.isEmpty ? String(localized: "text.dcc6272fd881", defaultValue: "有效期：无") : String(localized: "text.2e606ce8ff9f", defaultValue: "有效期：\(String(describing: validUntil))"),
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func quotaText(_ period: String) -> String {
        guard let profile else { return String(localized: "text.b336a174cd1f", defaultValue: "暂无") }
        let used = intValue(profile["used_\(period)"])
        let limit = intValue(profile["limit_\(period)"])
        if limit <= 0 {
            return used > 0 ? String(localized: "text.f457f0fdb025", defaultValue: "已用 \(String(describing: used)) · 无上限") : String(localized: "text.b336a174cd1f", defaultValue: "暂无")
        }
        return "\(used) / \(limit)"
    }

    func priceText(for plan: CloudRechargePlan) -> String {
        let fallback = plan.fallbackAmountFen
        guard let prices = (profile?["policy"] as? [String: Any])?["recharge_prices_fen"] as? [String: Any] else {
            return formatFen(fallback)
        }
        let amount = intValue(prices[plan.rawValue])
        return formatFen(amount > 0 ? amount : fallback)
    }

    private func pollPaymentStatus(outTradeNo: String) {
        Task {
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self.paymentOrder?.outTradeNo != outTradeNo { return }
                do {
                    let status = try await fetchPaymentStatus(outTradeNo: outTradeNo)
                    let finished = await MainActor.run {
                        self.applyPaymentStatus(status, outTradeNo: outTradeNo, notifyPending: false)
                    }
                    if finished {
                        return
                    }
                } catch {
                    // 轮询中允许单次失败，避免网络抖动中断支付流程。
                    continue
                }
            }
            await MainActor.run {
                if self.paymentOrder?.outTradeNo == outTradeNo {
                    self.statusMessage = String(localized: "text.6f58575748c1", defaultValue: "等待支付超时，可稍后刷新用户信息确认到账。")
                }
            }
        }
    }

    private func fetchPaymentStatus(outTradeNo: String) async throws -> String {
        let encoded = outTradeNo.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? outTradeNo
        let path = "api/v1/payment/wechat/order-status?outTradeNo=\(encoded)"
        let object = try await request(path: path, method: "GET", body: nil, authorized: true)
        let data = try payloadData(from: object, fallbackError: String(localized: "text.b3b08061ebd6", defaultValue: "查询订单状态失败"))
        return normalizedPaymentStatus(from: data)
    }

    @discardableResult
    private func applyPaymentStatus(_ status: String, outTradeNo: String, notifyPending: Bool) -> Bool {
        let normalized = status.isEmpty ? "pending" : status
        if var order = paymentOrder, order.outTradeNo == outTradeNo {
            order.status = normalized
            paymentOrder = order
        }
        if isPaidPaymentStatus(normalized) {
            statusMessage = String(localized: "text.65cd840103a1", defaultValue: "充值成功，正在刷新额度。")
            paymentOrder = nil
            refreshProfile()
            return true
        }
        if isFailedPaymentStatus(normalized) {
            statusMessage = String(localized: "text.a2dd266089c2", defaultValue: "订单支付失败。")
            alertMessage = String(localized: "text.681c26bed3bd", defaultValue: "订单已标记为失败，请重新发起充值。")
            return true
        }
        statusMessage = String(localized: "text.a24ebe7252df", defaultValue: "订单尚未到账，请稍后再刷新。")
        if notifyPending {
            alertMessage = String(localized: "text.55d5b346614d", defaultValue: "当前订单仍未到账，请确认微信支付已完成后再刷新。")
        }
        return false
    }

    private func authenticate(path: String, successMessage: String, fallbackError: String) {
        let p = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !password.isEmpty else {
            alertMessage = String(localized: "text.8243d8c8b81f", defaultValue: "请输入手机号和密码。")
            return
        }
        isBusy = true
        statusMessage = String(localized: "text.c15e7ee954d5", defaultValue: "正在请求云端账号…")
        Task {
            defer { Task { @MainActor in self.isBusy = false } }
            do {
                let object = try await request(path: path, method: "POST", body: ["phone": p, "password": password], authorized: false)
                let data = try payloadData(from: object, fallbackError: fallbackError)
                let token = firstString(in: data, keys: ["access_token", "token"])
                guard !token.isEmpty else { throw CloudAccountError(String(localized: "text.966601162379", defaultValue: "云端未返回 access_token。")) }
                await MainActor.run {
                    self.saveLogin(token: token, authData: data)
                    self.statusMessage = successMessage
                }
                await MainActor.run {
                    self.refreshProfile(showAlertOnFailure: false)
                }
            } catch {
                await MainActor.run {
                    self.alertMessage = error.localizedDescription
                    self.statusMessage = String(localized: "text.1470f2e962ed", defaultValue: "账号请求失败。")
                }
            }
        }
    }

    private func saveLogin(token: String, authData: [String: Any] = [:]) {
        let defaults = UserDefaults.standard
        defaults.set(token, forKey: tokenKey)
        defaults.set(rememberPassword, forKey: rememberKey)
        defaults.set(phone.trimmingCharacters(in: .whitespacesAndNewlines), forKey: phoneKey)
        if rememberPassword {
            defaults.set(password, forKey: passwordKey)
        } else {
            defaults.removeObject(forKey: passwordKey)
        }
        AhaTypeTextOptimizer.shared.patchCloudToken(token)
        seedLocalProfile(token: token, authData: authData)
        isLoggedIn = true
    }

    private func applyProfile(_ profile: [String: Any]) {
        let normalized = normalizedProfile(profile)
        self.profile = normalized
        isLoggedIn = true
        AhaTypeTextOptimizer.shared.patchCloudToken(accessToken)
        AhaTypeTextOptimizer.shared.setUserProfile(normalized)
    }

    private func seedLocalProfile(token: String, authData: [String: Any]) {
        var profile = normalizedProfile(authData)
        let phoneValue = firstString(in: authData, keys: ["phone", "mobile", "username"])
        profile["phone"] = phoneValue.isEmpty ? phone.trimmingCharacters(in: .whitespacesAndNewlines) : phoneValue
        let userID = firstString(in: authData, keys: ["id", "user_id", "userId"])
        if !userID.isEmpty {
            profile["user_id"] = userID
            profile["id"] = userID
        }
        if let validUntil = jwtExpirationString(token) {
            profile["token_valid_until"] = validUntil
        }
        profile["limit_daily"] = firstInt(in: authData, keys: ["limit_daily", "limitDaily"])
        profile["limit_weekly"] = firstInt(in: authData, keys: ["limit_weekly", "limitWeekly"])
        profile["limit_monthly"] = firstInt(in: authData, keys: ["limit_monthly", "limitMonthly"])
        profile["used_daily"] = firstInt(in: authData, keys: ["used_daily", "usedDaily"])
        profile["used_weekly"] = firstInt(in: authData, keys: ["used_weekly", "usedWeekly"])
        profile["used_monthly"] = firstInt(in: authData, keys: ["used_monthly", "usedMonthly"])
        self.profile = profile
        AhaTypeTextOptimizer.shared.setUserProfile(profile)
    }

    private func normalizedProfile(_ raw: [String: Any]) -> [String: Any] {
        var profile = raw
        let aliases: [(String, String)] = [
            ("id", "userId"),
            ("user_id", "userId"),
            ("token_valid_until", "tokenValidUntil"),
            ("limit_daily", "limitDaily"),
            ("limit_weekly", "limitWeekly"),
            ("limit_monthly", "limitMonthly"),
            ("used_daily", "usedDaily"),
            ("used_weekly", "usedWeekly"),
            ("used_monthly", "usedMonthly"),
        ]
        for (snake, camel) in aliases where profile[snake] == nil {
            if let value = raw[camel] {
                profile[snake] = value
            }
        }
        if stringValue(profile["token_valid_until"]).isEmpty, let validUntil = jwtExpirationString(accessToken) {
            profile["token_valid_until"] = validUntil
        }
        if var policy = profile["policy"] as? [String: Any] {
            let policyAliases: [(String, String)] = [
                ("recharge_prices_fen", "rechargePricesFen"),
                ("default_limit_daily", "defaultLimitDaily"),
                ("default_limit_weekly", "defaultLimitWeekly"),
                ("default_limit_monthly", "defaultLimitMonthly"),
                ("enable_daily", "enableDaily"),
                ("enable_weekly", "enableWeekly"),
                ("enable_monthly", "enableMonthly"),
            ]
            for (snake, camel) in policyAliases where policy[snake] == nil {
                if let value = policy[camel] {
                    policy[snake] = value
                }
            }
            profile["policy"] = policy
        }
        return profile
    }

    private func request(path: String, method: String, body: [String: Any]?, authorized: Bool) async throws -> [String: Any] {
        guard let url = URL(string: "\(apiBase)/\(path)") else {
            throw CloudAccountError(String(localized: "text.e4ba45d72eff", defaultValue: "云端地址无效。"))
        }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorized {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CloudAccountError(networkMessage(for: error))
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudAccountError(String(localized: "text.c6c6c8e2bf65", defaultValue: "服务器返回非 JSON。"), statusCode: statusCode)
        }
        if statusCode != 200 {
            throw CloudAccountError(responseMessage(object).isEmpty ? String(localized: "text.dbb8cff0e965", defaultValue: "请求失败（HTTP \(String(describing: statusCode))）。") : responseMessage(object), statusCode: statusCode)
        }
        return object
    }

    private func payloadData(from object: [String: Any], fallbackError: String) throws -> [String: Any] {
        let code = intValue(object["code"])
        guard code == 0 || code == 200 else {
            let msg = responseMessage(object)
            throw CloudAccountError(msg.isEmpty ? fallbackError : msg)
        }
        return object["data"] as? [String: Any] ?? [:]
    }

    private var accessToken: String {
        UserDefaults.standard.string(forKey: tokenKey) ?? ""
    }

    private var apiBase: String {
        for key in ["VIBE_TYPELESS_API_BASE", "VIBE_API_BASE"] {
            let v = normalizeAPIBase(ProcessInfo.processInfo.environment[key] ?? "")
            if !v.isEmpty { return v }
        }
        return normalizeAPIBase(fallbackAPIBase)
    }

    private func normalizeAPIBase(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if !value.isEmpty, !value.contains("://") {
            value = "https://\(value)"
        }
        return value
    }

    private func stringValue(_ value: Any?) -> String {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return ""
        }
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String {
        for key in keys {
            let value = stringValue(object[key]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return ""
    }

    private func firstInt(in object: [String: Any], keys: [String]) -> Int {
        for key in keys {
            let value = intValue(object[key])
            if value != 0 { return value }
        }
        return 0
    }

    private func normalizedPaymentStatus(from data: [String: Any]) -> String {
        firstString(in: data, keys: ["status", "tradeState", "trade_state", "payStatus", "pay_status", "orderStatus", "order_status"])
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    private func isPaidPaymentStatus(_ status: String) -> Bool {
        let normalized = status.lowercased().replacingOccurrences(of: "-", with: "_")
        return [
            "paid",
            "success",
            "succeeded",
            "complete",
            "completed",
            "pay_success",
            "trade_success",
            "wechat_success",
            "finished",
            "done",
            "1",
        ].contains(normalized)
    }

    private func isFailedPaymentStatus(_ status: String) -> Bool {
        let normalized = status.lowercased().replacingOccurrences(of: "-", with: "_")
        return [
            "failed",
            "failure",
            "fail",
            "closed",
            "cancelled",
            "canceled",
            "expired",
            "timeout",
            "trade_closed",
            "pay_error",
            "2",
        ].contains(normalized)
    }

    private func responseMessage(_ object: [String: Any]) -> String {
        firstString(in: object, keys: ["errorMsg", "msg", "message", "error"])
    }

    private func jwtExpirationString(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let exp = Double(intValue(object["exp"]))
        guard exp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: exp)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func intValue(_ value: Any?) -> Int {
        switch value {
        case let int as Int: return int
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string) ?? 0
        default: return 0
        }
    }

    private func formatFen(_ fen: Int) -> String {
        (Double(max(0, fen)) / 100.0).formatted(.currency(code: "CNY"))
    }

    private func networkMessage(for error: Error) -> String {
        guard let urlError = error as? URLError else {
            return String(localized: "text.6f36f8b2e566", defaultValue: "云端连接失败：\(String(describing: error.localizedDescription))")
        }
        switch urlError.code {
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
            return String(localized: "text.f333efeccbf9", defaultValue: "云端连接失败：TLS/SSL 校验未通过，请检查系统时间、网络代理/证书，或确认云端 HTTPS 证书配置正常。")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet, .networkConnectionLost, .timedOut:
            return String(localized: "text.1936bb895efe", defaultValue: "云端连接失败：当前网络无法访问 AhaType 服务，请检查网络后重试。")
        default:
            return String(localized: "text.6f36f8b2e566", defaultValue: "云端连接失败：\(String(describing: urlError.localizedDescription))")
        }
    }
}

struct CloudAccountError: LocalizedError {
    let message: String
    let statusCode: Int?

    init(_ message: String, statusCode: Int? = nil) {
        self.message = message
        self.statusCode = statusCode
    }

    var errorDescription: String? { message }
}

enum CloudRechargePlan: String, CaseIterable, Identifiable {
    case monthly
    case quarterly
    case yearly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monthly: return String(localized: "text.5a1f30797836", defaultValue: "按月订阅")
        case .quarterly: return String(localized: "text.508ec5ca1cb5", defaultValue: "按季订阅")
        case .yearly: return String(localized: "text.5c6379a19308", defaultValue: "按年订阅")
        }
    }

    var subtitle: String {
        switch self {
        case .monthly: return String(localized: "text.84ad2952a308", defaultValue: "30 天")
        case .quarterly: return String(localized: "text.cb82f419192b", defaultValue: "90 天")
        case .yearly: return String(localized: "text.ef95232cba01", defaultValue: "365 天")
        }
    }

    var orderDescription: String {
        switch self {
        case .monthly: return String(localized: "text.00c04a0000e2", defaultValue: "包月充值")
        case .quarterly: return String(localized: "text.b4ee0a0aeabf", defaultValue: "包季充值")
        case .yearly: return String(localized: "text.346e45df14e8", defaultValue: "包年充值")
        }
    }

    var fallbackAmountFen: Int {
        switch self {
        case .monthly: return 100
        case .quarterly: return 270
        case .yearly: return 999
        }
    }
}

struct CloudPaymentOrder: Equatable {
    let plan: CloudRechargePlan
    let amountFen: Int
    let outTradeNo: String
    let codeURL: String
    let h5URL: String
    var status: String

    var paymentURL: String {
        codeURL.isEmpty ? h5URL : codeURL
    }

    var amountText: String {
        (Double(max(0, amountFen)) / 100.0).formatted(.currency(code: "CNY"))
    }
}
